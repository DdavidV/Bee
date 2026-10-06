defmodule Desktop.Bridge do
  @moduledoc """
  Bee's only way in, in desktop mode (`Bee.Mode`): messages from the desktop
  shell on stdin, answers on stdout, no listening socket. Each message is a
  4-byte big-endian length followed by JSON.

  The shell sends the window's HTTP requests (its `bee://` protocol) and
  the frames of LiveView's socket (`BridgeTransport` in assets/js):

      {"t": "req",   "id": 1, "win": "w1", "method": "GET", "url": "bee://localhost/",
       "headers": [["accept", "text/html"]], "body": "<base64>"}
      {"t": "open",  "sid": "s1", "win": "w1", "url": "ws://localhost/live/websocket?vsn=2.0.0&…"}
      {"t": "msg",   "sid": "s1", "data": "…", "bin": false}      (bin: data is base64)
      {"t": "close", "sid": "s1"}

  and gets:

      {"t": "res",    "id": 1, "status": 200, "headers": [[k, v]], "body": "<base64>"}
      {"t": "opened", "sid": "s1"}
      {"t": "msg",    "sid": "s1", "data": "…", "bin": false}
      {"t": "closed", "sid": "s1", "reason": "…"}

  Requests run through the endpoint in memory (`Desktop.Conn`), the
  socket in a process of its own (`Desktop.Socket`). Cookies are
  kept here, per window (`win`), so the shell needn't handle them and the
  socket's session works as over HTTP. When stdin closes (the shell quit),
  Bee stops.

  `io: {:test, pid}` replaces stdin/stdout for tests: frames come as
  `{:frame, json}` messages and go to `pid` as `{:bridge_out, map}`.
  """
  use GenServer
  require Logger

  alias Desktop.{Conn, Socket, StdoutGuard}

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    endpoint = Keyword.get(opts, :endpoint, BeeWeb.Endpoint)

    io =
      case Keyword.get(opts, :io, :stdio) do
        :stdio ->
          StdoutGuard.install()
          # fd 0/1, the VM doing the framing. Needs -noinput (rel/env.sh.eex).
          {:port, Port.open({:fd, 0, 1}, [:binary, {:packet, 4}, :eof])}

        {:test, pid} ->
          {:test, pid}
      end

    Logger.info("Bee: desktop bridge on stdin/stdout")
    {:ok, %{io: io, endpoint: endpoint, jars: %{}, sockets: %{}}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{io: {:port, port}} = s),
    do: {:noreply, receive_frame(data, s)}

  def handle_info({:frame, data}, %{io: {:test, _}} = s), do: {:noreply, receive_frame(data, s)}

  # The shell is gone.
  def handle_info({port, :eof}, %{io: {:port, port}} = s) do
    Logger.info("Bee: stdin closed, stopping")
    System.stop(0)
    {:noreply, s}
  end

  def handle_info({:response, id, win, {status, headers, body}}, s) do
    s = store_cookies(s, win, headers)
    headers = for {k, v} <- headers, k != "set-cookie", do: [k, v]
    write(s, %{t: "res", id: id, status: status, headers: headers, body: Base.encode64(body)})
    {:noreply, s}
  end

  def handle_info({:socket_out, sid, :binary, payload}, s) do
    write(s, %{t: "msg", sid: sid, data: Base.encode64(payload), bin: true})
    {:noreply, s}
  end

  def handle_info({:socket_out, sid, _text, payload}, s) do
    write(s, %{t: "msg", sid: sid, data: payload, bin: false})
    {:noreply, s}
  end

  def handle_info({:socket_closed, sid, reason}, s), do: {:noreply, closed(s, sid, reason)}

  def handle_info({:DOWN, _ref, :process, pid, reason}, s) do
    case Enum.find(s.sockets, fn {_sid, p} -> p == pid end) do
      {sid, _} -> {:noreply, closed(s, sid, reason)}
      nil -> {:noreply, s}
    end
  end

  def handle_info(_other, s), do: {:noreply, s}

  ## Frames from the shell

  defp receive_frame(data, s) do
    case Jason.decode(data) do
      {:ok, frame} ->
        handle_frame(frame, s)

      {:error, _} ->
        Logger.warning("Bee: bridge got a frame that isn't JSON")
        s
    end
  end

  defp handle_frame(%{"t" => "req", "id" => id, "win" => win, "method" => m, "url" => url} = f, s) do
    bridge = self()
    headers = with_cookies(f["headers"] || [], s, win)
    body = Base.decode64!(f["body"] || "")

    Task.start(fn ->
      response =
        try do
          Conn.request(s.endpoint, m, url, headers, body)
        rescue
          e -> {500, [{"content-type", "text/plain"}], Exception.message(e)}
        end

      send(bridge, {:response, id, win, response})
    end)

    s
  end

  defp handle_frame(%{"t" => "open", "sid" => sid, "win" => win, "url" => url}, s) do
    case Socket.start(self(), sid, s.endpoint, url, with_cookies([], s, win)) do
      {:ok, pid} ->
        Process.monitor(pid)
        write(s, %{t: "opened", sid: sid})
        put_in(s.sockets[sid], pid)

      {:error, reason} ->
        Logger.warning("Bee: bridge socket #{sid} refused: #{inspect(reason)}")
        write(s, %{t: "closed", sid: sid, reason: inspect(reason)})
        s
    end
  end

  defp handle_frame(%{"t" => "msg", "sid" => sid, "data" => data} = f, s) do
    if pid = s.sockets[sid] do
      if f["bin"],
        do: send(pid, {:bridge_in, Base.decode64!(data), :binary}),
        else: send(pid, {:bridge_in, data, :text})
    end

    s
  end

  defp handle_frame(%{"t" => "close", "sid" => sid}, s) do
    if pid = s.sockets[sid], do: send(pid, :bridge_close)
    %{s | sockets: Map.delete(s.sockets, sid)}
  end

  defp handle_frame(frame, s) do
    Logger.warning("Bee: bridge ignored #{inspect(frame["t"])} frame")
    s
  end

  defp closed(s, sid, reason) do
    if Map.has_key?(s.sockets, sid),
      do: write(s, %{t: "closed", sid: sid, reason: inspect(reason)})

    %{s | sockets: Map.delete(s.sockets, sid)}
  end

  defp write(%{io: {:port, port}}, frame), do: Port.command(port, Jason.encode!(frame))
  defp write(%{io: {:test, pid}}, frame), do: send(pid, {:bridge_out, frame})

  ## Cookies, per window

  defp with_cookies(headers, s, win) do
    headers = Enum.reject(headers, fn [k, _] -> String.downcase(k) == "cookie" end)

    case Map.get(s.jars, win, %{}) do
      jar when map_size(jar) == 0 -> headers
      jar -> [["cookie", Enum.map_join(jar, "; ", fn {k, v} -> "#{k}=#{v}" end)] | headers]
    end
  end

  defp store_cookies(s, win, headers) do
    Enum.reduce(headers, s, fn
      {"set-cookie", value}, s ->
        [pair | attrs] = String.split(value, ";")
        [name, val] = String.split(pair, "=", parts: 2)

        expired? =
          Enum.any?(attrs, &(&1 |> String.trim() |> String.downcase() == "max-age=0"))

        jar = Map.get(s.jars, win, %{})
        jar = if expired? or val == "", do: Map.delete(jar, name), else: Map.put(jar, name, val)
        put_in(s.jars[win], jar)

      _other, s ->
        s
    end)
  end
end

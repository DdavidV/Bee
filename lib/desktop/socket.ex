defmodule Desktop.Socket do
  @moduledoc """
  One Phoenix socket (LiveView's `/live`) carried by the bridge instead of a
  WebSocket. This process does for the socket's handler what a WebSocket
  server does: `connect/1` with the request's params and connect info
  (session cookie, CSRF check), `init/1`, then `handle_in/2` for every frame
  from the window and `handle_info/2` for everything else. What they push
  goes to the bridge as `{:socket_out, sid, opcode, payload}`.
  """

  alias Desktop.Conn

  # Phoenix.Transports.WebSocket.default_config()[:serializer] (a private module).
  @serializer [
    {Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"},
    {Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}
  ]

  @doc """
  Connects socket `sid` for `url` (`…/live/websocket?vsn=…`): `{:ok, pid}`
  once the handler accepted it, or `{:error, reason}`.
  """
  def start(bridge, sid, endpoint, url, headers) do
    parent = self()
    pid = spawn(fn -> run(parent, bridge, sid, endpoint, url, headers) end)
    ref = Process.monitor(pid)

    receive do
      {^pid, :connected} ->
        Process.demonitor(ref, [:flush])
        {:ok, pid}

      {^pid, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      10_000 ->
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end

  defp run(parent, bridge, sid, endpoint, url, headers) do
    with {:ok, handler, opts} <- find_socket(endpoint, url),
         conn = "GET" |> Conn.conn(url, headers) |> Plug.Conn.fetch_query_params(),
         connect_info = Phoenix.Socket.Transport.connect_info(conn, endpoint, connect_info(opts)),
         {:ok, arg} <-
           connect(handler, %{
             endpoint: endpoint,
             transport: :websocket,
             options: Keyword.put(opts, :serializer, @serializer),
             params: conn.query_params,
             connect_info: connect_info
           }),
         {:ok, state} <- handler.init(arg) do
      send(parent, {self(), :connected})
      loop(bridge, sid, handler, state)
    else
      error -> send(parent, {self(), {:error, error}})
    end
  end

  defp connect(handler, config) do
    case handler.connect(config) do
      {:ok, arg} -> {:ok, arg}
      other -> {:error, {:refused, other}}
    end
  end

  # `/live/websocket` → the endpoint's `socket "/live", handler, websocket: opts`.
  defp find_socket(endpoint, url) do
    path = URI.parse(url).path |> String.replace_suffix("/websocket", "")

    case Enum.find(endpoint.__sockets__(), fn {socket_path, _, _} -> socket_path == path end) do
      {_, handler, opts} -> {:ok, handler, Keyword.get(opts, :websocket, [])}
      nil -> {:error, {:no_socket, path}}
    end
  end

  # As Phoenix.Socket.Transport.load_config/1 (private) prepares connect_info:
  # session options → {key, store, {csrf_token_key, store_init}}.
  defp connect_info(opts) do
    for item <- Keyword.get(opts, :connect_info, []) do
      case item do
        {:session, config} when is_list(config) ->
          store = Plug.Session.Store.get(Keyword.fetch!(config, :store))
          init = store.init(Keyword.drop(config, [:store, :key]))
          csrf = Keyword.get(config, :csrf_token_key, "_csrf_token")
          {:session, {Keyword.fetch!(config, :key), store, {csrf, init}}}

        other ->
          other
      end
    end
  end

  defp loop(bridge, sid, handler, state) do
    receive do
      {:bridge_in, payload, opcode} ->
        {payload, opcode: opcode} |> handler.handle_in(state) |> result(bridge, sid, handler)

      :bridge_close ->
        handler.terminate(:closed, state)

      message ->
        message |> handler.handle_info(state) |> result(bridge, sid, handler)
    end
  end

  defp result({:ok, state}, bridge, sid, handler), do: loop(bridge, sid, handler, state)

  defp result({:reply, _status, frames, state}, bridge, sid, handler) do
    push(frames, bridge, sid)
    loop(bridge, sid, handler, state)
  end

  defp result({:push, frames, state}, bridge, sid, handler) do
    push(frames, bridge, sid)
    loop(bridge, sid, handler, state)
  end

  defp result({:stop, reason, state}, bridge, sid, handler) do
    handler.terminate(reason, state)
    send(bridge, {:socket_closed, sid, reason})
  end

  defp push(frames, bridge, sid) do
    for {opcode, payload} <- List.wrap(frames),
        do: send(bridge, {:socket_out, sid, opcode, IO.iodata_to_binary(payload)})
  end
end

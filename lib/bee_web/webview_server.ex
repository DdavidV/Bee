defmodule BeeWeb.WebviewServer do
  @moduledoc """
  Where the pages of webview panels (`BeeWeb.WebviewController`) are
  served from, apart from Bee's own page: an HTTP server of its own, on a
  port of the local machine picked when Bee starts – or, in the desktop
  app, which opens no port at all, a second address of the shell's
  (`beeview://localhost`, see below).

  A webview's page is an extension's, and must stay apart from Bee's own
  page. Served by Bee's endpoint it would share the page's origin, so its
  frame has to be sandboxed down to no origin at all – and so do the
  frames inside it, which breaks pages that embed a local server of their
  extension (its requests and WebSockets come from nowhere, and are
  refused). Served from here it has an origin that is its own – another
  port – as in VS Code: the browser keeps it from Bee's page, and what it
  embeds works.

  Only webview pages and their files are served, by their panel's token,
  and only to a local `Host` (as `BeeWeb.Plugs.CheckHost` does: no DNS
  rebinding). `origin/1` is where a window finds it, or nil when it can't
  – the window isn't on this machine, or the server didn't start – in
  which case the endpoint serves the pages, without an origin.

  The desktop app has no server: nothing listens. Its shell answers a
  second scheme, `beeview://localhost/…` (`http://beeview.localhost/…` on
  Windows), with what Bee says over the bridge, like the window's own
  `bee://localhost` (`Desktop.Bridge`, which sends those requests to
  `BeeWeb.WebviewServer.Plug`). Another scheme is another origin.
  """
  use Supervisor
  require Logger

  @key {__MODULE__, :port}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :persistent_term.erase(@key)

    # The desktop app opens no port: its shell has an address for this.
    children =
      if Bee.Mode.desktop?() do
        []
      else
        [
          {Bandit,
           plug: BeeWeb.WebviewServer.Plug,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [supervisor_options: [name: __MODULE__.Listener]]}
        ]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @desktop_scheme "beeview"

  @doc "Whether `url` is a request to the desktop shell's address for webview pages."
  def desktop_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: @desktop_scheme} -> true
      %URI{host: @desktop_scheme <> ".localhost"} -> true
      _ -> false
    end
  end

  def desktop_url?(_url), do: false

  @doc "The port it listens on, or nil."
  def port do
    case :persistent_term.get(@key, nil) do
      nil ->
        with pid when is_pid(pid) <- Process.whereis(__MODULE__.Listener),
             {:ok, {_ip, port}} <- ThousandIsland.listener_info(pid) do
          :persistent_term.put(@key, port)
          port
        else
          _ -> nil
        end

      port ->
        port
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  Where a window whose own page is at host `host` loads webview pages from
  (`"http://127.0.0.1:41234"`), or nil: for a window on this machine
  (also the desktop app's).
  """
  def origin(host) when host in ["localhost", "127.0.0.1", "[::1]", "::1", "bee.localhost"] do
    cond do
      # (Windows' webview has custom schemes as http://<scheme>.localhost.)
      Bee.Mode.desktop?() and match?({:win32, _}, :os.type()) ->
        "http://#{@desktop_scheme}.localhost"

      Bee.Mode.desktop?() ->
        "#{@desktop_scheme}://localhost"

      true ->
        with port when is_integer(port) <- port(), do: "http://127.0.0.1:#{port}"
    end
  end

  def origin(_host), do: nil

  defmodule Plug do
    @moduledoc false
    # What the webview server serves: /webview/:token/…, to a local Host.
    @behaviour Elixir.Plug
    import Elixir.Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{host: host, path_info: ["webview", token | path]} = conn, _opts)
        when host in ["localhost", "127.0.0.1", "beeview.localhost"] and
               conn.method in ["GET", "HEAD"] do
      conn
      |> put_private(:bee_webview_origin, true)
      |> BeeWeb.WebviewController.show(%{"token" => token, "path" => path})
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end
end

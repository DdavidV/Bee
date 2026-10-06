defmodule Bee.Mode do
  @moduledoc """
  How Bee is reached, chosen when it starts (`BEE_MODE`, config/runtime.exs):

    * `:server` (default) – a browser, over HTTP on 127.0.0.1 only, with a
      token (`Bee.Access`). Bee prints its address when ready.
    * `:desktop` – a desktop shell (Tauri), over Bee's stdin/stdout
      (`Desktop.Bridge`): no web server is started, not even by
      `mix phx.server`, logs go to stderr, and Bee stops when stdin closes.
  """
  require Logger

  def current, do: Application.get_env(:bee, :mode, :server)

  def desktop?, do: current() == :desktop

  @doc "Before the endpoint starts: in desktop mode nothing may start its web server."
  def prepare do
    if desktop?(), do: Application.put_env(:phoenix, :serve_endpoints, false)
    Bee.Access.init()
    :ok
  end

  @doc "Once the endpoint runs: prints where a browser finds Bee (server mode)."
  def announce do
    with :server <- current(),
         {:ok, {_ip, port}} <- BeeWeb.Endpoint.server_info(:http) do
      IO.puts("\n🐝 Bee is ready: #{Bee.Access.url("127.0.0.1", port)}\n")
    end

    :ok
  end
end

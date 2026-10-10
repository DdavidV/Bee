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
    clean_env()
    Bee.Access.init()
    :ok
  end

  # What a release's start script sets for its own VM: where its Erlang
  # is, how to boot it. Bee's VM runs by now and has no more use for them,
  # but every program Bee starts would inherit them – terminals, plugins,
  # the extension host and the language servers it starts – and an `erl`
  # or `elixir` among them would then try to boot as Bee's release and die
  # ("cannot get bootfile"). The same for the release's own `erl`, which
  # its start script puts first on the PATH: the user's is the one to find.
  @release_vars ~w(BINDIR ROOTDIR EMU PROGNAME)

  @doc """
  Takes the variables of Bee's own release out of the environment the
  programs Bee starts inherit (see above). Nothing to do when Bee isn't
  run from a release.
  """
  def clean_env do
    if root = System.get_env("RELEASE_ROOT") do
      root = Path.expand(root)

      path =
        (System.get_env("PATH") || "")
        |> String.split(":")
        |> Enum.reject(
          &(Path.expand(&1) == root or String.starts_with?(Path.expand(&1), root <> "/"))
        )
        |> Enum.join(":")

      System.put_env("PATH", path)

      for {name, _value} <- System.get_env(),
          name in @release_vars or String.starts_with?(name, "RELEASE_"),
          do: System.delete_env(name)

      # rel/env.sh.eex adds -noinput for Bee's VM in desktop mode.
      case System.get_env("ELIXIR_ERL_OPTIONS") do
        nil ->
          :ok

        options ->
          case options |> String.replace("-noinput", "") |> String.trim() do
            "" -> System.delete_env("ELIXIR_ERL_OPTIONS")
            rest -> System.put_env("ELIXIR_ERL_OPTIONS", rest)
          end
      end
    end

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

defmodule Bee.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Bee.Mode.prepare()

    children = [
      BeeWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:bee, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bee.PubSub},
      {Registry, keys: :unique, name: Bee.Registry},
      Bee.Contributions,
      Bee.Settings,
      Bee.Commands.Keybindings,
      Bee.Workspace.Watcher,
      Bee.Workspace.RecentFiles,
      {DynamicSupervisor, name: Bee.WorkspaceSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Bee.BufferSup, strategy: :one_for_one},
      {DynamicSupervisor, name: Bee.TerminalSup, strategy: :one_for_one},
      Bee.UI,
      {Task.Supervisor, name: Bee.Search.TaskSup},
      Bee.Plugins.Supervisor,
      BeeWeb.Endpoint,
      # Server mode: the address to open, once the endpoint listens.
      {Task, &Bee.Mode.announce/0}
    ]

    # Desktop mode: the shell talks to Bee over stdin/stdout.
    children = if Bee.Mode.desktop?(), do: children ++ [Desktop.Bridge], else: children

    opts = [strategy: :one_for_one, name: Bee.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BeeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

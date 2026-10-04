defmodule Bee.Plugins.Supervisor do
  @moduledoc """
  The plugin subsystem:

    * `Bee.Plugins.TaskSup` – tasks running plugin callbacks (with timeouts)
    * `Bee.Plugins.HostSup` – one `Bee.Plugins.Host` per active plugin
    * `Bee.Plugins.Manager` – discovery, activation, crash handling

  `:one_for_all`: the manager's state (which host runs which plugin) is
  only valid together with the hosts, so they restart together.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Bee.Plugins.TaskSup},
      {DynamicSupervisor, name: Bee.Plugins.HostSup, strategy: :one_for_one},
      Bee.Plugins.Manager
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

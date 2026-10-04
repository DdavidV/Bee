defmodule Bee.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BeeWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:bee, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bee.PubSub},
      Bee.Workspace,
      BeeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Bee.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BeeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

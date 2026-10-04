defmodule Bee.Workspace do
  @moduledoc """
  The opened folder. Watches it for changes and broadcasts
  `{:fs_changed, abs_path}` on the `"fs"` topic.
  """
  use GenServer
  require Logger

  @topic "fs"

  @exclude [".git", "_build", "deps", "node_modules", ".elixir_ls", ".expert"]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def root, do: Path.expand(Application.fetch_env!(:bee, :workspace_root))

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, @topic)

  def resolve(rel), do: Bee.FS.resolve(root(), rel)

  def list_dir(rel), do: Bee.FS.list_dir(root(), rel, @exclude)

  @impl true
  def init(_opts) do
    with true <- File.dir?(root()),
         {:ok, watcher} <- FileSystem.start_link(dirs: [root()]) do
      FileSystem.subscribe(watcher)
      {:ok, %{watcher: watcher}}
    else
      other ->
        Logger.warning("Bee: file watching disabled (#{inspect(other)})")
        {:ok, %{watcher: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:fs_changed, path})
    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state), do: {:noreply, state}
end

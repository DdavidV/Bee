defmodule Bee.Workspace do
  @moduledoc """
  The opened folder. Watches it for changes and broadcasts
  `{:fs_changed, abs_path}` on the `"fs"` topic.
  """
  use GenServer
  require Logger

  @topic "fs"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def root, do: Path.expand(Application.fetch_env!(:bee, :workspace_root))

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, @topic)

  def resolve(rel), do: Bee.Workspace.FS.resolve(root(), rel)

  def list_dir(rel), do: Bee.Workspace.FS.list_dir(root(), rel, Bee.Settings.excluded_globs())

  @doc "Every file of the workspace (relative paths), without `files.exclude`d ones."
  def files, do: Bee.Workspace.FS.walk(root(), "", Bee.Settings.excluded_globs())

  @impl true
  def init(_opts) do
    # The config dir is watched too, so edits to settings/keybindings files
    # made outside Bee are picked up.
    dirs = Enum.filter([root(), Bee.Settings.user_dir()], &File.dir?/1)

    # Off in tests, which simulate {:fs_changed, path} themselves.
    with true <- Application.get_env(:bee, :watch_files, true) || :disabled_by_config,
         [_ | _] <- dirs,
         {:ok, watcher} <- FileSystem.start_link(dirs: dirs) do
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

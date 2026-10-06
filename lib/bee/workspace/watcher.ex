defmodule Bee.Workspace.Watcher do
  @moduledoc """
  Watches the user's config folder (settings, keybindings, plugins) and the
  folder of every open workspace (`watch/1`, counted: a folder is watched
  while anyone asks for it), and broadcasts `{:fs_changed, abs_path}` on
  the `"fs"` topic (`Bee.Workspace.subscribe/0`).

  Off when `config :bee, watch_files: false` (tests simulate the messages).
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def watch(dir), do: GenServer.call(__MODULE__, {:watch, dir})
  def unwatch(dir), do: GenServer.cast(__MODULE__, {:unwatch, dir})

  @impl true
  def init(_opts) do
    on? = Application.get_env(:bee, :watch_files, true)
    unless on?, do: Logger.warning("Bee: file watching disabled (:disabled_by_config)")
    s = %{on?: on?, dirs: %{}}
    {:ok, start_watching(s, Bee.Settings.user_dir())}
  end

  @impl true
  def handle_call({:watch, dir}, _from, s), do: {:reply, :ok, start_watching(s, dir)}

  @impl true
  def handle_cast({:unwatch, dir}, s) do
    case s.dirs[dir] do
      {pid, 1} ->
        if pid, do: GenServer.stop(pid, :normal)
        {:noreply, %{s | dirs: Map.delete(s.dirs, dir)}}

      {pid, n} ->
        {:noreply, put_in(s.dirs[dir], {pid, n - 1})}

      nil ->
        {:noreply, s}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, s) do
    Phoenix.PubSub.broadcast(Bee.PubSub, "fs", {:fs_changed, path})
    {:noreply, s}
  end

  def handle_info(_other, s), do: {:noreply, s}

  defp start_watching(s, dir) do
    case s.dirs[dir] do
      {pid, n} -> put_in(s.dirs[dir], {pid, n + 1})
      nil -> put_in(s.dirs[dir], {watcher(s, dir), 1})
    end
  end

  defp watcher(%{on?: false}, _dir), do: nil

  defp watcher(_s, dir) do
    File.mkdir_p(dir)

    case FileSystem.start_link(dirs: [dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        pid

      other ->
        Logger.warning("Bee: can't watch #{dir}: #{inspect(other)}")
        nil
    end
  end
end

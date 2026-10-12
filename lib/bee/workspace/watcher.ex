defmodule Bee.Workspace.Watcher do
  @moduledoc """
  Watches the user's config folder (settings, keybindings, plugins) and the
  folder of every open workspace (`watch/1`, counted: a folder is watched
  while anyone asks for it), and broadcasts `{:fs_changed, abs_path}` on
  the `"fs"` topic (`Bee.Workspace.subscribe/0`).

  A change is told at once. What changes right after it – a burst: a build
  writing its output, a log growing – is told a moment later, each path
  once: everything that follows the files (every window, every open file,
  every plugin) then hears of a file once per moment, not once per write.

  Off when `config :bee, watch_files: false` (tests simulate the messages).
  """
  use GenServer
  require Logger

  # How long changed paths are gathered after one was told: long enough
  # for the writes of one save to be one, too short to be noticed.
  @batch_ms 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def watch(dir), do: GenServer.call(__MODULE__, {:watch, dir})
  def unwatch(dir), do: GenServer.cast(__MODULE__, {:unwatch, dir})

  @impl true
  def init(_opts) do
    on? = Application.get_env(:bee, :watch_files, true)
    unless on?, do: Logger.warning("Bee: file watching disabled (:disabled_by_config)")
    # `changed`: the paths gathered since one was told, nil when none was lately.
    s = %{on?: on?, dirs: %{}, changed: nil}
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
  def handle_info({:file_event, _watcher, {path, _events}}, %{changed: nil} = s) do
    tell(path)
    Process.send_after(self(), :tell, @batch_ms)
    {:noreply, %{s | changed: MapSet.new()}}
  end

  def handle_info({:file_event, _watcher, {path, _events}}, s),
    do: {:noreply, %{s | changed: MapSet.put(s.changed, path)}}

  def handle_info(:tell, s) do
    if MapSet.size(s.changed) == 0 do
      {:noreply, %{s | changed: nil}}
    else
      Enum.each(s.changed, &tell/1)
      Process.send_after(self(), :tell, @batch_ms)
      {:noreply, %{s | changed: MapSet.new()}}
    end
  end

  def handle_info(_other, s), do: {:noreply, s}

  defp tell(path), do: Phoenix.PubSub.broadcast(Bee.PubSub, "fs", {:fs_changed, path})

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

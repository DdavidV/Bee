defmodule Bee.Workspace.RecentFiles do
  @moduledoc """
  The files recently opened in each workspace, most recent first, for Quick
  Open (`workbench.quickOpen.recentFiles` of them are shown). Shared by the
  workspace's windows and kept across restarts in `<config_dir>/recent.json`
  (`%{root => [abs_path]}`).
  """
  use GenServer
  require Logger

  # Kept per workspace, and workspaces kept (the most recently used).
  @max_files 100
  @max_roots 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Workspace `root`'s recent files, most recent first."
  def list(root), do: GenServer.call(__MODULE__, {:list, root})

  @doc "`path` was opened (or switched to) in workspace `root`."
  def add(root, path), do: GenServer.cast(__MODULE__, {:add, root, path})

  @doc "Forgets every workspace's (tests)."
  def clear, do: GenServer.call(__MODULE__, :clear)

  defp file, do: Path.join(Bee.Settings.user_dir(), "recent.json")

  @impl true
  def init(_opts) do
    recent =
      with {:ok, text} <- File.read(file()),
           {:ok, %{} = map} <- Jason.decode(text) do
        map
      else
        {:error, :enoent} ->
          %{}

        other ->
          Logger.warning("Bee: ignoring #{file()}: #{inspect(other)}")
          %{}
      end

    # Most recently used workspace first.
    {:ok, %{recent: recent, order: Map.keys(recent)}}
  end

  @impl true
  def handle_call({:list, root}, _from, s), do: {:reply, Map.get(s.recent, root, []), s}

  def handle_call(:clear, _from, _s) do
    File.rm(file())
    {:reply, :ok, %{recent: %{}, order: []}}
  end

  @impl true
  def handle_cast({:add, root, path}, s) do
    files = [path | List.delete(Map.get(s.recent, root, []), path)] |> Enum.take(@max_files)
    {kept, dropped} = Enum.split([root | List.delete(s.order, root)], @max_roots)
    s = %{recent: s.recent |> Map.put(root, files) |> Map.drop(dropped), order: kept}
    save(s.recent)
    {:noreply, s}
  end

  defp save(recent) do
    File.mkdir_p(Path.dirname(file()))

    case Bee.Workspace.FS.atomic_write(file(), Jason.encode!(recent)) do
      :ok -> :ok
      other -> Logger.warning("Bee: can't write #{file()}: #{inspect(other)}")
    end
  end
end

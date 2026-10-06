defmodule Bee.Workspace do
  @moduledoc """
  An open folder. Several can be open at once, one per window or more:
  each is a process, started by the first window that opens it (`open/2`)
  and stopped a while after the last one closed it (`close/2`, or the
  window going away). While open, its files are watched
  (`Bee.Workspace.Watcher`), its `.bee/settings.json` is a layer of
  `Bee.Settings`, and plugins run for it (`Bee.Plugins`).

  `root/0` is the folder Bee was started for (`BEE_ROOT`, or the current
  directory): the one a window opens unless it names another.
  """
  use GenServer, restart: :temporary
  require Logger

  # How long a workspace stays open after its last window (a reload
  # reopens it at once).
  @idle_ms 10_000

  @doc "The folder Bee was started for."
  def root, do: Path.expand(Application.fetch_env!(:bee, :workspace_root))

  @doc "`{:fs_changed, abs_path}` for files of every open workspace and the config folder."
  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, "fs")

  @doc """
  Opens folder `path` for `client` (a window), which keeps it open until it
  closes it or exits. Returns `{:ok, root}` (the absolute path) or
  `{:error, message}` when it isn't a folder.
  """
  def open(path, client \\ self()) do
    root = Path.expand(path)

    if File.dir?(root) do
      with {:ok, pid} <- find_or_start(root) do
        GenServer.call(pid, {:attach, client})
        {:ok, root}
      end
    else
      {:error, "#{root} is not a folder"}
    end
  end

  def close(root, client \\ self()) do
    case whereis(root) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:detach, client})
    end
  end

  @doc "The roots of the open workspaces."
  def list do
    Registry.select(Bee.Registry, [{{{:workspace, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc "The open workspace `path` is in (the innermost), or nil."
  def for_path(path) do
    path = Path.expand(path)

    list()
    |> Enum.filter(&(path == &1 or String.starts_with?(path, &1 <> "/")))
    |> Enum.max_by(&byte_size/1, fn -> nil end)
  end

  @doc "The process of open workspace `root`, or nil."
  def whereis(root) do
    case Registry.lookup(Bee.Registry, {:workspace, root}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp find_or_start(root) do
    case whereis(root) do
      nil ->
        case DynamicSupervisor.start_child(Bee.WorkspaceSup, {__MODULE__, root}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, "can't open #{root}: #{inspect(reason)}"}
        end

      pid ->
        {:ok, pid}
    end
  end

  ## Files of a workspace

  @doc "`rel` (from the browser) inside `root`, never outside it."
  def resolve(root, rel), do: Bee.Workspace.FS.resolve(root, rel)

  @doc "A folder of `root`, without `files.exclude`d entries."
  def list_dir(root, rel),
    do: Bee.Workspace.FS.list_dir(root, rel, Bee.Settings.excluded_globs(root))

  @doc "Every file of `root` (relative paths), without `files.exclude`d ones."
  def files(root), do: Bee.Workspace.FS.walk(root, "", Bee.Settings.excluded_globs(root))

  ## Process

  def start_link(root),
    do:
      GenServer.start_link(__MODULE__, root,
        name: {:via, Registry, {Bee.Registry, {:workspace, root}}}
      )

  @impl true
  def init(root) do
    Bee.Workspace.Watcher.watch(root)
    Bee.Settings.track(root)
    # Its plugins start (and stop when we do).
    Bee.Plugins.Manager.workspace_opened(root, self())
    {:ok, %{root: root, clients: %{}, idle: nil}}
  end

  @impl true
  def handle_call({:attach, client}, _from, s) do
    s = cancel_idle(s)

    s =
      if Map.has_key?(s.clients, client),
        do: s,
        else: put_in(s.clients[client], Process.monitor(client))

    {:reply, :ok, s}
  end

  @impl true
  def handle_cast({:detach, client}, s), do: {:noreply, detach(s, client)}

  @impl true
  def handle_info({:DOWN, _ref, :process, client, _reason}, s), do: {:noreply, detach(s, client)}

  def handle_info(:idle, %{clients: clients} = s) when map_size(clients) == 0,
    do: {:stop, :normal, s}

  def handle_info(:idle, s), do: {:noreply, %{s | idle: nil}}

  @impl true
  def terminate(_reason, s) do
    Bee.Workspace.Watcher.unwatch(s.root)
    Bee.Settings.untrack(s.root)
  end

  defp detach(s, client) do
    {ref, clients} = Map.pop(s.clients, client)
    ref && Process.demonitor(ref, [:flush])
    s = %{s | clients: clients}
    if ref, do: Logger.debug("Bee: a window left #{s.root}, #{map_size(clients)} left")

    if clients == %{} and s.idle == nil,
      do: %{s | idle: Process.send_after(self(), :idle, idle_ms())},
      else: s
  end

  defp cancel_idle(%{idle: nil} = s), do: s

  defp cancel_idle(s) do
    Process.cancel_timer(s.idle)
    %{s | idle: nil}
  end

  defp idle_ms, do: Application.get_env(:bee, :workspace_idle_ms, @idle_ms)
end

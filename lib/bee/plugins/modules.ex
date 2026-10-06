defmodule Bee.Plugins.Modules do
  @moduledoc """
  The loaded code of plugins' server parts. A plugin runs once per open
  workspace (`Bee.Plugins.Host`), but its modules exist once in the VM: the
  first host compiles and loads them (`Bee.Plugins.Loader`), the others
  share them. They are unloaded when the plugin's last host is gone, or the
  plugin is removed (`drop/1`).

  Each load of a plugin by the manager has its own `load_id`: code of an
  earlier one (the plugin changed on disk) is never reused.
  """
  use GenServer

  alias Bee.Plugins.Loader

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The plugin's modules for the calling host, loaded if needed:
  `{:ok, entry_module, modules}` or `{:error, [problem]}`.
  """
  def ensure(plugin), do: GenServer.call(__MODULE__, {:ensure, plugin}, 120_000)

  @doc "Unloads plugin `name`'s modules (its hosts are gone)."
  def drop(name), do: GenServer.call(__MODULE__, {:drop, name})

  @doc """
  Host `pid` is gone: its plugin's modules are unloaded if it was the last.
  We notice by ourselves too; this is for callers that need it done now.
  """
  def release(pid), do: GenServer.call(__MODULE__, {:release, pid})

  @impl true
  def init(_opts) do
    # After a restart of the plugin supervisor: code of the previous hosts.
    Loader.unload(Loader.loaded())
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ensure, plugin}, {host, _}, s) do
    s =
      case s[plugin.name] do
        %{id: id} when id != plugin.load_id -> unload(s, plugin.name)
        _ -> s
      end

    case s[plugin.name] do
      nil ->
        case Loader.load(plugin.dir, plugin.manifest["server"]) do
          {:ok, module, modules} ->
            entry = %{id: plugin.load_id, module: module, modules: modules, hosts: %{}}
            {:reply, {:ok, module, modules}, Map.put(s, plugin.name, add_host(entry, host))}

          {:error, problems} ->
            {:reply, {:error, problems}, s}
        end

      entry ->
        {:reply, {:ok, entry.module, entry.modules},
         Map.put(s, plugin.name, add_host(entry, host))}
    end
  end

  def handle_call({:drop, name}, _from, s), do: {:reply, :ok, unload(s, name)}

  def handle_call({:release, pid}, _from, s) do
    s =
      for {name, entry} <- s, {ref, ^pid} <- entry.hosts, reduce: s do
        s ->
          Process.demonitor(ref, [:flush])
          remove_host(s, name, ref)
      end

    {:reply, :ok, s}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    case Enum.find(s, fn {_name, entry} -> Map.has_key?(entry.hosts, ref) end) do
      nil -> {:noreply, s}
      {name, _entry} -> {:noreply, remove_host(s, name, ref)}
    end
  end

  defp remove_host(s, name, ref) do
    entry = %{s[name] | hosts: Map.delete(s[name].hosts, ref)}
    if entry.hosts == %{}, do: unload(s, name), else: Map.put(s, name, entry)
  end

  defp add_host(entry, host),
    do: put_in(entry.hosts[Process.monitor(host)], host)

  defp unload(s, name) do
    case Map.pop(s, name) do
      {nil, s} ->
        s

      {entry, s} ->
        Enum.each(Map.keys(entry.hosts), &Process.demonitor(&1, [:flush]))
        Loader.unload(entry.modules)
        s
    end
  end
end

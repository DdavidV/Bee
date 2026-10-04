defmodule Bee.Editor.Buffer do
  @moduledoc """
  One process per open file. Holds the latest text from the editor and the
  last text known to be on disk: the buffer is dirty when they differ.

  Clients (LiveViews) attach with `open/2` and detach with `close/2`. The
  buffer monitors them and stops once the last one is gone, discarding
  unsaved changes.

  Broadcasts on the `"buffers"` topic (for plugins and LSP later on):

    * `{:buffer_opened, path, text}`
    * `{:buffer_changed, path, version, text}`
    * `{:buffer_saved, path, text}`
    * `{:buffer_reloaded, path, text}` – file changed on disk while clean
    * `{:buffer_closed, path}`
  """
  use GenServer, restart: :temporary

  @topic "buffers"

  defstruct [:path, :text, :disk_text, version: 0, clients: %{}]

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, @topic)

  @doc """
  Finds or starts the buffer for an absolute path and attaches `client` to it.
  """
  def open(path, client \\ self(), retries \\ 1) do
    result =
      case DynamicSupervisor.start_child(Bee.BufferSup, {__MODULE__, path}) do
        {:ok, pid} -> attach(pid, client)
        {:error, {:already_started, pid}} -> attach(pid, client)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:error, :closed} when retries > 0 -> open(path, client, retries - 1)
      result -> result
    end
  end

  @doc "Detaches `client`; the buffer stops when no clients remain."
  def close(path, client \\ self()) do
    case Registry.lookup(Bee.Registry, {:buffer, path}) do
      [{pid, _}] -> GenServer.cast(pid, {:detach, client})
      [] -> :ok
    end
  end

  def start_link(path), do: GenServer.start_link(__MODULE__, path, name: via(path))

  def get(path), do: GenServer.call(via(path), :get)
  def update(path, text), do: GenServer.call(via(path), {:update, text})
  def save(path, text), do: GenServer.call(via(path), {:save, text})

  def dirty?(%__MODULE__{text: text, disk_text: disk}), do: text != disk

  defp attach(pid, client) do
    GenServer.call(pid, {:attach, client})
  catch
    # Raced with the buffer stopping after its last client left.
    :exit, _ -> {:error, :closed}
  end

  defp via(path), do: {:via, Registry, {Bee.Registry, {:buffer, path}}}

  @impl true
  def init(path) do
    case File.read(path) do
      {:ok, text} ->
        if String.valid?(text) do
          Phoenix.PubSub.subscribe(Bee.PubSub, "fs")
          broadcast({:buffer_opened, path, text})
          {:ok, %__MODULE__{path: path, text: text, disk_text: text}}
        else
          {:stop, :binary_file}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:attach, client}, _from, state) do
    clients = Map.put_new_lazy(state.clients, client, fn -> Process.monitor(client) end)
    state = %{state | clients: clients}
    {:reply, {:ok, state}, state}
  end

  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_call({:update, text}, _from, state) do
    state = put_text(state, text)
    {:reply, state, state}
  end

  def handle_call({:save, text}, _from, state) do
    state = put_text(state, text)

    case Bee.Workspace.FS.atomic_write(state.path, text) do
      :ok ->
        state = %{state | disk_text: text}
        broadcast({:buffer_saved, state.path, text})
        {:reply, {:ok, state}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:detach, client}, state), do: detach(state, client)

  @impl true
  def handle_info({:DOWN, _ref, :process, client, _}, state), do: detach(state, client)

  def handle_info({:fs_changed, path}, %{path: path} = state) do
    with false <- dirty?(state),
         {:ok, disk} when disk != state.text <- File.read(path),
         true <- String.valid?(disk) do
      state = %{state | text: disk, disk_text: disk, version: state.version + 1}
      broadcast({:buffer_reloaded, path, disk})
      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:fs_changed, _other}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    broadcast({:buffer_closed, state.path})
  end

  defp put_text(%{text: text} = state, text), do: state

  defp put_text(state, text) do
    state = %{state | text: text, version: state.version + 1}
    broadcast({:buffer_changed, state.path, state.version, text})
    state
  end

  defp detach(state, client) do
    {ref, clients} = Map.pop(state.clients, client)
    ref && Process.demonitor(ref, [:flush])
    state = %{state | clients: clients}

    if clients == %{}, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, msg)
end

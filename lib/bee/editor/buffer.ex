defmodule Bee.Editor.Buffer do
  @moduledoc """
  One process per open file. Holds the latest text from the editor and the
  last text known to be on disk: the buffer is dirty when they differ.

  Clients (LiveViews) attach with `open/2` and detach with `close/2`. The
  buffer monitors them and stops once the last one is gone, discarding
  unsaved changes.

  Text changes come from the editor – what was typed, by position
  (`change/3`), or the whole text (`update/2`) – or from the server
  (`edit/2`, e.g. plugins): those are pushed to every editor showing the
  file.

  Every change of the text makes a new `version`. An editor says which
  version its change is of: one of another version isn't applied
  (`{:error, :stale}`), and the editor sends its whole text instead. That
  way typing costs what was typed, not the file's size, and the two can't
  drift apart unnoticed.

  Broadcasts on the `"buffers"` topic (for plugins and LSP):

    * `{:buffer_opened, path, text}` – its version is 0
    * `{:buffer_delta, path, version, edits}` – after `change/3`, before
      `:buffer_changed`: the edits that made `version` of the one before it
    * `{:buffer_changed, path, version, text}`
    * `{:buffer_edited, path, version, edits, text}` – after `edit/2`, before
      `:buffer_changed`
    * `{:buffer_saved, path, text}`
    * `{:buffer_reloaded, path, version, text}` – file changed on disk while clean
    * `{:buffer_closed, path}`
  """
  use GenServer, restart: :temporary

  alias Bee.Editor.Positions

  @topic "buffers"

  # `line`: a line of the text and where it starts, known from the last
  # change (`Bee.Editor.Positions.to_bytes/3`).
  defstruct [:path, :text, :disk_text, version: 0, clients: %{}, line: {0, 0}]

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

  @doc """
  Applies what an editor changed in version `base` of the text: `edits` –
  `[%{"from" => position, "to" => position, "text" => inserted}]`, places
  as `Bee.Editor.Positions` has them, all in that version's text, not
  overlapping. Returns `{:ok, buffer}` (its version is `base + 1`), or
  `{:error, :stale}` when the buffer has another version or the edits
  aren't of its text: the editor's whole text is needed then (`update/2`).
  """
  def change(path, base, edits), do: GenServer.call(via(path), {:change, base, edits})

  @doc """
  Saves the text, replaced by `text` first when given. With `base:` it is
  saved only when it is that version (`{:error, :stale}` otherwise).
  """
  def save(path, text \\ nil, opts \\ []),
    do: GenServer.call(via(path), {:save, text, opts[:base]})

  @doc """
  The version an editor can send changes of (`change/3`), or nil when it
  has to send its whole text: positions don't mean the same in a text
  whose lines the editor breaks differently.
  """
  def sync_version(%__MODULE__{text: text, version: version}),
    do: if(Positions.line_breaks_agree?(text), do: version)

  @doc """
  Applies `edits` – `[{from, to, text}]`, UTF-8 byte offsets into the
  current text, not overlapping – all at once. Returns `{:ok, buffer}` or
  `{:error, reason}`; `{:error, :not_open}` when no editor has the file open.
  """
  def edit(path, edits) do
    GenServer.call(via(path), {:edit, edits})
  catch
    :exit, {:noproc, _} -> {:error, :not_open}
  end

  @doc "Applies `edits` (see `edit/2`) to `text`."
  def apply_edits(text, edits) do
    in_range? = fn
      {from, to, insert} ->
        is_integer(from) and is_integer(to) and is_binary(insert) and
          0 <= from and from <= to and to <= byte_size(text)

      _ ->
        false
    end

    with true <- (is_list(edits) and Enum.all?(edits, in_range?)) || {:error, :invalid_edits},
         sorted = Enum.sort_by(edits, fn {from, to, _} -> {from, to} end),
         true <- not overlapping?(sorted) || {:error, :invalid_edits},
         result = splice(text, sorted, 0, []),
         true <- String.valid?(result) || {:error, :invalid_utf8} do
      {:ok, result}
    end
  end

  # `text` with `edits` (sorted, not overlapping) applied: built in one go.
  defp splice(text, [{from, to, insert} | edits], at, acc),
    do: splice(text, edits, to, [acc, binary_part(text, at, from - at), insert])

  defp splice(text, [], at, acc),
    do: IO.iodata_to_binary([acc | binary_part(text, at, byte_size(text) - at)])

  # An editor's edits (see `change/3`) as `apply_edits/2` takes them, and
  # the line the first is on (`known`: the last ones', to find them from).
  defp byte_edits(text, edits, known) do
    with true <- is_list(edits),
         true <-
           Enum.all?(
             edits,
             &match?(%{"from" => %{}, "to" => %{}, "text" => t} when is_binary(t), &1)
           ),
         places = Enum.flat_map(edits, &[&1["from"], &1["to"]]),
         {:ok, offsets, line} <- Positions.to_bytes(text, places, known) do
      {:ok,
       offsets
       |> Enum.chunk_every(2)
       |> Enum.zip_with(edits, fn [from, to], edit -> {from, to, edit["text"]} end), line}
    else
      _ -> :error
    end
  end

  defp overlapping?(sorted) do
    sorted
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [{_, to, _}, {from, _, _}] -> from < to end)
  end

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

  def handle_call({:edit, edits}, _from, state) do
    case apply_edits(state.text, edits) do
      {:ok, text} when text == state.text ->
        {:reply, {:ok, state}, state}

      {:ok, text} ->
        broadcast({:buffer_edited, state.path, state.version + 1, edits, text})
        state = put_text(state, text)
        {:reply, {:ok, state}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # (The inserted text is the editor's, and its places are between
  # characters: the result needn't be checked like a plugin's edits.)
  def handle_call({:change, base, edits}, _from, %{version: base} = state) do
    with {:ok, byte_edits, line} <- byte_edits(state.text, edits, state.line),
         sorted = Enum.sort(byte_edits),
         false <- overlapping?(sorted) or Enum.any?(sorted, fn {from, to, _} -> from > to end) do
      # (The text is the same up to the first edit's line, which starts
      # where it did: the next one is found from there.)
      text = splice(state.text, sorted, 0, [])
      state = %{state | text: text, version: base + 1, line: line}
      broadcast({:buffer_delta, state.path, state.version, edits})
      broadcast({:buffer_changed, state.path, state.version, state.text})
      {:reply, {:ok, state}, state}
    else
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:change, _base, _edits}, _from, state), do: {:reply, {:error, :stale}, state}

  def handle_call({:save, _text, base}, _from, %{version: version} = state)
      when base != nil and base != version,
      do: {:reply, {:error, :stale}, state}

  def handle_call({:save, text, _base}, _from, state) do
    state = put_text(state, text || state.text)
    text = state.text

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
      state = %{state | text: disk, disk_text: disk, version: state.version + 1, line: {0, 0}}
      broadcast({:buffer_reloaded, path, state.version, disk})
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
    state = %{state | text: text, version: state.version + 1, line: {0, 0}}
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

defmodule BeeWeb.EditorLive do
  @moduledoc """
  The editor window.

  Text lives in CodeMirror on the client (`CodeEditor` hook) and in a
  `Bee.Buffer` process per file on the server; this LiveView routes between
  them. Tabs are keyed by absolute path.

  Terminals are `Bee.Terminal` processes owned by this LiveView, rendered by
  the `Terminal` hook (xterm.js). Output is only forwarded once the hook has
  reported ready and replayed the scrollback; `term_seq` holds the last
  sequence number forwarded per terminal.
  """
  use BeeWeb, :live_view

  alias Bee.{Buffer, Terminal, Workspace}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Workspace.subscribe()
      Buffer.subscribe()
    end

    {:ok,
     assign(socket,
       page_title: Path.basename(Workspace.root()),
       root: Workspace.root(),
       tabs: [],
       active: nil,
       status: nil,
       sidebar_open: true,
       terminals: [],
       active_term: nil,
       term_seq: %{},
       panel_open: false
     )}
  end

  @impl true
  def handle_event("activate_tab", %{"path" => path}, socket) do
    {:noreply, if(open?(socket, path), do: activate(socket, path), else: socket)}
  end

  def handle_event("close_tab", %{"path" => path}, socket),
    do: {:noreply, close_tab(socket, path)}

  def handle_event("doc_changed", %{"path" => path, "text" => text}, socket) do
    if open?(socket, path) do
      {:noreply, set_dirty(socket, path, Buffer.dirty?(Buffer.update(path, text)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"path" => path, "text" => text}, socket) do
    with true <- open?(socket, path),
         {:ok, _buffer} <- Buffer.save(path, text) do
      {:noreply, socket |> set_dirty(path, false) |> assign(status: "Saved #{rel(socket, path)}")}
    else
      false ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not save #{rel(socket, path)}: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_sidebar", _params, socket),
    do: {:noreply, update(socket, :sidebar_open, &(!&1))}

  ## Terminal

  def handle_event("new_terminal", _params, socket), do: {:noreply, new_terminal(socket)}

  def handle_event("toggle_panel", _params, socket), do: {:noreply, toggle_panel(socket)}

  def handle_event("activate_terminal", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, if(terminal?(socket, id), do: assign(socket, active_term: id), else: socket)}
  end

  def handle_event("close_terminal", %{"id" => id}, socket) do
    id = String.to_integer(id)

    if terminal?(socket, id) do
      Terminal.stop(id)
      {:noreply, remove_terminal(socket, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("term_ready", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    if terminal?(socket, id) do
      Terminal.resize(id, cols, rows)
      {scrollback, seq} = Terminal.scrollback(id)

      {:reply, %{data: Base.encode64(scrollback)},
       update(socket, :term_seq, &Map.put(&1, id, seq))}
    else
      {:reply, %{data: ""}, socket}
    end
  catch
    # The shell exited in the meantime; :term_exit removes the tab.
    :exit, _ -> {:reply, %{data: ""}, socket}
  end

  def handle_event("term_input", %{"id" => id, "data" => data}, socket) do
    if terminal?(socket, id), do: Terminal.input(id, data)
    {:noreply, socket}
  end

  def handle_event("term_resize", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    if terminal?(socket, id), do: Terminal.resize(id, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:open_file, rel}, socket) do
    case Workspace.resolve(rel) do
      {:ok, abs} -> {:noreply, open(socket, abs)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Path outside workspace")}
    end
  end

  def handle_info({:fs_changed, path}, socket) do
    send_update(BeeWeb.FileTreeComponent, id: "explorer", fs_changed: path)
    {:noreply, socket}
  end

  def handle_info({:buffer_reloaded, path, text}, socket) do
    if open?(socket, path) do
      {:noreply,
       socket
       |> set_dirty(path, false)
       |> push_event("cm:reload", %{path: path, text: text})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:term_data, id, seq, data}, socket) do
    case socket.assigns.term_seq do
      %{^id => last} when seq > last ->
        {:noreply,
         socket
         |> push_event("term:data", %{id: id, data: Base.encode64(data)})
         |> update(:term_seq, &Map.put(&1, id, seq))}

      # Not attached yet (replayed from scrollback on term_ready) or already sent.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:term_exit, id, _reason}, socket), do: {:noreply, remove_terminal(socket, id)}

  # The remaining buffer events are for plugins and LSP.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp open(socket, abs) do
    if open?(socket, abs) do
      activate(socket, abs)
    else
      case Buffer.open(abs) do
        {:ok, buffer} ->
          socket
          |> update(:tabs, &(&1 ++ [%{path: abs, dirty: Buffer.dirty?(buffer)}]))
          |> assign(active: abs)
          |> push_event("cm:open", %{path: abs, text: buffer.text, lang: Bee.Lang.detect(abs)})

        {:error, reason} ->
          put_flash(socket, :error, "Cannot open #{rel(socket, abs)}: #{inspect(reason)}")
      end
    end
  end

  defp activate(socket, path) do
    socket |> assign(active: path) |> push_event("cm:activate", %{path: path})
  end

  defp close_tab(socket, path) do
    tabs = socket.assigns.tabs

    case Enum.find_index(tabs, &(&1.path == path)) do
      nil ->
        socket

      index ->
        Buffer.close(path)
        remaining = List.delete_at(tabs, index)
        socket = socket |> assign(tabs: remaining) |> push_event("cm:close", %{path: path})

        cond do
          socket.assigns.active != path -> socket
          remaining == [] -> assign(socket, active: nil)
          true -> activate(socket, Enum.at(remaining, min(index, length(remaining) - 1)).path)
        end
    end
  end

  defp set_dirty(socket, path, dirty) do
    update(socket, :tabs, fn tabs ->
      Enum.map(tabs, fn
        %{path: ^path} = tab -> %{tab | dirty: dirty}
        tab -> tab
      end)
    end)
  end

  defp open?(socket, path), do: Enum.any?(socket.assigns.tabs, &(&1.path == path))

  defp new_terminal(socket) do
    id = System.unique_integer([:positive])
    shell = Terminal.default_shell()
    Phoenix.PubSub.subscribe(Bee.PubSub, Terminal.topic(id))

    case Terminal.start(id: id, owner: self(), shell: shell) do
      {:ok, _pid} ->
        terminal = %{id: id, name: Path.basename(shell)}

        socket
        |> update(:terminals, &(&1 ++ [terminal]))
        |> assign(active_term: id, panel_open: true)

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Bee.PubSub, Terminal.topic(id))
        put_flash(socket, :error, "Could not start terminal: #{inspect(reason)}")
    end
  end

  defp remove_terminal(socket, id) do
    Phoenix.PubSub.unsubscribe(Bee.PubSub, Terminal.topic(id))
    terminals = Enum.reject(socket.assigns.terminals, &(&1.id == id))

    active =
      cond do
        socket.assigns.active_term != id -> socket.assigns.active_term
        terminals == [] -> nil
        true -> List.last(terminals).id
      end

    socket
    |> assign(terminals: terminals, active_term: active)
    |> update(:term_seq, &Map.delete(&1, id))
  end

  # Closing the panel unmounts the xterm hooks but keeps the shells running;
  # reopening re-attaches them via term_ready. Opening an empty panel starts a shell.
  defp toggle_panel(%{assigns: %{panel_open: true}} = socket),
    do: assign(socket, panel_open: false, term_seq: %{})

  defp toggle_panel(%{assigns: %{terminals: []}} = socket), do: new_terminal(socket)
  defp toggle_panel(socket), do: assign(socket, panel_open: true)

  defp terminal?(socket, id), do: Enum.any?(socket.assigns.terminals, &(&1.id == id))

  defp rel(socket, path), do: Bee.FS.relative(socket.assigns.root, path)
end

defmodule BeeWeb.EditorLive do
  @moduledoc """
  The editor window.

  Text lives in CodeMirror on the client (`CodeEditor` hook) and in a
  `Bee.Buffer` process per file on the server; this LiveView routes between
  them. Tabs are keyed by absolute path.
  """
  use BeeWeb, :live_view

  alias Bee.{Buffer, Workspace}

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
       status: nil
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

  defp rel(socket, path), do: Bee.FS.relative(socket.assigns.root, path)
end

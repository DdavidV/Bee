defmodule BeeWeb.EditorLive do
  @moduledoc """
  The editor window.
  """
  use BeeWeb, :live_view

  alias Bee.Workspace

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Workspace.subscribe()

    {:ok,
     assign(socket,
       page_title: Path.basename(Workspace.root()),
       root: Workspace.root(),
       selected: nil
     )}
  end

  @impl true
  def handle_info({:open_file, rel}, socket) do
    case Workspace.resolve(rel) do
      {:ok, _abs} -> {:noreply, assign(socket, selected: rel)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Path outside workspace")}
    end
  end

  def handle_info({:fs_changed, path}, socket) do
    send_update(BeeWeb.FileTreeComponent, id: "explorer", fs_changed: path)
    {:noreply, socket}
  end
end

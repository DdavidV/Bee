defmodule BeeWeb.EditorLive.Webviews do
  @moduledoc """
  Webview panels of extensions (`Bee.Webviews`): their tabs, the messages
  between a panel's page (the Webview hook) and its extension, and telling
  the extensions which panels are shown.
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench

  ## Events

  # From a panel's page (the Webview hook): a message for its extension,
  # the state it keeps, a link to open, a key for Bee.
  def handle_event("webview_message", %{"id" => id} = params, socket) when is_binary(id) do
    if Workbench.open?(workbench(socket), "webview:" <> id),
      do: Bee.Extensions.Host.webview(socket.assigns.root, id, {:message, params["message"]})

    {:halt, socket}
  end

  def handle_event("webview_state", %{"id" => id} = params, socket) when is_binary(id) do
    if Workbench.open?(workbench(socket), "webview:" <> id),
      do: Bee.Webviews.put_state(socket.assigns.root, id, params["state"])

    {:halt, socket}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  # A webview panel of an extension (Bee.Webviews): its tab, here too.
  def handle_info({:webview, id, :opened}, socket) do
    case Bee.Webviews.get(socket.assigns.root, id) do
      nil -> {:halt, socket}
      panel -> {:halt, show_webview(socket, panel, true)}
    end
  end

  def handle_info({:webview, id, :changed}, socket) do
    case Bee.Webviews.get(socket.assigns.root, id) do
      nil ->
        {:halt, socket}

      panel ->
        {:halt,
         socket
         |> update(:webviews, &Map.put(&1, id, panel))
         |> change(&Workbench.set_webview_title(&1, id, panel.title))}
    end
  end

  def handle_info({:webview, id, :revealed}, socket),
    do: {:halt, change(socket, &Workbench.activate_editor(&1, "webview:" <> id))}

  def handle_info({:webview, id, {:message, message}}, socket),
    do: {:halt, push_event(socket, "webview:message", %{id: id, message: message})}

  def handle_info({:webview, id, :disposed}, socket) do
    {:halt,
     socket
     |> update(:webviews, &Map.delete(&1, id))
     |> change(&Workbench.close_editor(&1, "webview:" <> id))}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  # The workspace's panels there are already (another window's, or this
  # one's before it was loaded again).
  def load_webviews(socket) do
    host = socket.host_uri && socket.host_uri.host
    origin = if is_binary(host), do: BeeWeb.WebviewServer.origin(host)
    socket = assign(socket, webviews: %{}, webview_origin: origin)

    if connected?(socket),
      do:
        Enum.reduce(Bee.Webviews.list(socket.assigns.root), socket, &show_webview(&2, &1, false)),
      else: socket
  end

  defp show_webview(socket, panel, activate?) do
    socket
    |> update(:webviews, &Map.put(&1, panel.id, panel))
    |> change(&Workbench.open_webview(&1, panel.id, panel.title, activate?))
  end

  # Tells the extensions which of their panels is shown now.
  def sync_webviews(socket, before) do
    wb = workbench(socket)
    # The panels shown: each group's active editor, when it is one.
    shown = fn wb ->
      for group <- Workbench.groups(wb),
          %{kind: :webview, webview: id, path: path} <- group.tabs,
          path == group.active,
          into: MapSet.new(),
          do: id
    end

    {was, is} = {shown.(before), shown.(wb)}

    for id <- MapSet.union(was, is), MapSet.member?(was, id) != MapSet.member?(is, id) do
      active? = MapSet.member?(is, id)
      Bee.Extensions.Host.webview(socket.assigns.root, id, {:state, active?, active?})
    end

    socket
  end
end

defmodule BeeWeb.EditorLive.Webviews do
  @moduledoc """
  Webview panels of extensions (`Bee.Webviews`): their tabs, the messages
  between a panel's page (the Webview hook) and its extension, and telling
  the extensions which panels are shown.

  And their webview views (a view of `type` `"webview"`, `Bee.Views`): a
  panel that is the page of a view, shown in the sidebar or the panel
  (`BeeWeb.Workbench.Sidebar`). Its extension is asked to draw it when the
  view is first shown here.
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench

  ## Events

  # From a panel's page (the Webview hook): a message for its extension,
  # the state it keeps, a link to open, a key for Bee.
  def handle_event("webview_message", %{"id" => id} = params, socket) when is_binary(id) do
    if shown?(socket, id),
      do: Bee.Extensions.Host.webview(socket.assigns.root, id, {:message, params["message"]})

    {:halt, socket}
  end

  def handle_event("webview_state", %{"id" => id} = params, socket) when is_binary(id) do
    if shown?(socket, id),
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

  # (A view's: its container is shown.)
  def handle_info({:webview, "view:" <> view = id, :revealed}, socket)
      when is_map_key(socket.assigns.webviews, id) do
    case Bee.Views.view(view) do
      %{container: container} -> {:halt, change(socket, &Workbench.show_container(&1, container))}
      nil -> {:halt, socket}
    end
  end

  def handle_info({:webview, id, :revealed}, socket),
    do: {:halt, change(socket, &Workbench.activate_editor(&1, "webview:" <> id))}

  def handle_info({:webview, id, {:message, message}}, socket),
    do: {:halt, push_event(socket, "webview:message", %{id: id, message: message})}

  def handle_info({:webview, id, :disposed}, socket) do
    {:halt,
     socket
     |> put_private(:resolved_views, MapSet.delete(resolved(socket), id))
     |> update(:webviews, &Map.delete(&1, id))
     |> change(&Workbench.close_editor(&1, "webview:" <> id))}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  defp resolve_views(socket, shown) do
    new = MapSet.difference(shown, resolved(socket))

    if connected?(socket) and MapSet.size(new) > 0 do
      for "view:" <> view <- new do
        Bee.Plugins.view_shown(view, socket.assigns.root)
        Bee.Extensions.Host.resolve_view(socket.assigns.root, view)
      end

      put_private(socket, :resolved_views, MapSet.union(resolved(socket), new))
    else
      socket
    end
  end

  # The workspace's panels there are already (another window's, or this
  # one's before it was loaded again).
  def load_webviews(socket) do
    host = socket.host_uri && socket.host_uri.host
    origin = if is_binary(host), do: BeeWeb.WebviewServer.origin(host)
    # (And the diffs of extensions in its tabs: id => what differs.)
    socket = assign(socket, webviews: %{}, webview_origin: origin, diffs: %{})

    if connected?(socket),
      do:
        Enum.reduce(Bee.Webviews.list(socket.assigns.root), socket, &show_webview(&2, &1, false)),
      else: socket
  end

  # A view's page isn't a tab: its view shows it.
  defp show_webview(socket, %{view: view} = panel, _activate?) when is_binary(view),
    do: update(socket, :webviews, &Map.put(&1, panel.id, panel))

  defp show_webview(socket, panel, activate?) do
    socket
    |> update(:webviews, &Map.put(&1, panel.id, panel))
    |> change(&Workbench.open_webview(&1, panel.id, panel.title, activate?))
  end

  # A page of this window's: a panel in one of its tabs, or a view's.
  defp shown?(socket, id) do
    Workbench.open?(workbench(socket), "webview:" <> id) or
      match?(%{view: view} when is_binary(view), socket.assigns.webviews[id])
  end

  # The webview views this window asked their extensions to draw.
  defp resolved(socket), do: socket.private[:resolved_views] || MapSet.new()

  # The webview views on screen: those of the container the sidebar shows,
  # and of the panel's section.
  defp views_shown(wb, views) do
    containers =
      if(wb.sidebar_open, do: [wb.sidebar_view], else: []) ++
        if(wb.panel_open, do: [wb.panel_view], else: []) ++
        if(wb.auxiliary_open and wb.auxiliary_view, do: [wb.auxiliary_view], else: [])

    for %{webview: true, id: id, container: container} <- views || [],
        container in containers,
        into: MapSet.new(),
        do: "view:" <> id
  end

  # Tells the extensions which of their panels and views is shown now; a
  # view shown for the first time is asked for (its extension starts).
  def sync_webviews(socket, before) do
    wb = workbench(socket)
    views = socket.assigns[:views]
    # The panels shown: each group's active editor, when it is one.
    shown = fn wb ->
      for group <- Workbench.groups(wb),
          %{kind: :webview, webview: id, path: path} <- group.tabs,
          path == group.active,
          into: views_shown(wb, views),
          do: id
    end

    {was, is} = {shown.(before), shown.(wb)}
    socket = resolve_views(socket, views_shown(wb, views))

    # The diffs of extensions (vscode.diff) whose tab is the one shown.
    diffs = fn wb ->
      for group <- Workbench.groups(wb),
          %{kind: :diff, diff: id, path: path} <- group.tabs,
          path == group.active,
          into: MapSet.new(),
          do: id
    end

    {diffs_before, diffs_now} = {diffs.(before), diffs.(wb)}

    for id <- MapSet.union(diffs_before, diffs_now),
        MapSet.member?(diffs_before, id) != MapSet.member?(diffs_now, id),
        do:
          Bee.Extensions.Host.diff(
            socket.assigns.root,
            id,
            {:state, MapSet.member?(diffs_now, id)}
          )

    for id <- MapSet.union(was, is), MapSet.member?(was, id) != MapSet.member?(is, id) do
      active? = MapSet.member?(is, id)
      Bee.Extensions.Host.webview(socket.assigns.root, id, {:state, active?, active?})
    end

    socket
  end
end

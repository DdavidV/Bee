defmodule BeeWeb.EditorLive.Views do
  @moduledoc """
  Views and their containers (`Bee.Views`): the activity bar, the sidebar's
  views and the panel's sections, with what plugins put in them (`Bee.UI`:
  view contents, status bar items, context keys, file decorations).
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import BeeWeb.EditorLive.Window

  alias Bee.Plugins
  alias Bee.Workbench
  alias BeeWeb.EditorLive.{Commands, Menus}

  ## Events

  # Activity bar: show a container's views (or hide the sidebar, VS Code style).
  def handle_event("show_view", %{"container" => id}, socket) do
    socket = change(socket, &Workbench.show_view(&1, id))
    if socket.assigns.sidebar_open, do: views_shown(socket)
    {:halt, socket}
  end

  def handle_event("toggle_view_item", %{"view" => view, "item" => item}, socket) do
    key = {view, item}

    collapsed =
      if MapSet.member?(socket.assigns.collapsed, key),
        do: MapSet.delete(socket.assigns.collapsed, key),
        else: MapSet.put(socket.assigns.collapsed, key)

    {:halt, assign(socket, collapsed: collapsed)}
  end

  # A view's header folds the view (when its container shows several).
  def handle_event("toggle_view", %{"view" => view}, socket) do
    collapsed =
      if MapSet.member?(socket.assigns.collapsed_views, view),
        do: MapSet.delete(socket.assigns.collapsed_views, view),
        else: MapSet.put(socket.assigns.collapsed_views, view)

    {:halt, assign(socket, collapsed_views: collapsed)}
  end

  # A sash between views was dragged: the body heights of the open views.
  def handle_event("view_resize", %{"sizes" => sizes}, socket) when is_map(sizes) do
    sizes =
      for {view, size} <- sizes,
          is_number(size),
          size >= 0,
          into: %{},
          do: {view, min(size, 10_000)}

    {:halt, update(socket, :view_sizes, &Map.merge(&1, sizes))}
  end

  # Double-clicked: these views share the height evenly again.
  def handle_event("view_resize", %{"reset" => views}, socket) when is_list(views),
    do: {:halt, update(socket, :view_sizes, &Map.drop(&1, views))}

  def handle_event("view_input", %{"view" => view, "value" => value}, socket),
    do: {:halt, update(socket, :view_inputs, &Map.put(&1, view, value))}

  def handle_event("view_submit", %{"view" => view_id} = params, socket) do
    value = params["value"] || Map.get(socket.assigns.view_inputs, view_id, "")

    case socket.assigns.view_contents[view_id] do
      %{input: %{command: command, arguments: args}} ->
        {:halt,
         socket
         |> update(:view_inputs, &Map.put(&1, view_id, value))
         |> Commands.run_command(command, args ++ [value])}

      _ ->
        {:halt, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  def handle_info({:ui_changed, {:view, id}}, socket),
    do:
      {:halt,
       update(socket, :view_contents, &Map.put(&1, id, Bee.UI.view(socket.assigns.root, id)))}

  def handle_info({:ui_changed, :status_items}, socket),
    do: {:halt, assign(socket, status_items: Bee.UI.status_items(socket.assigns.root))}

  def handle_info({:ui_changed, :context}, socket),
    do: {:halt, assign(socket, ui_context: Bee.UI.context(socket.assigns.root))}

  def handle_info({:ui_changed, :decorations}, socket), do: {:halt, load_decorations(socket)}

  def handle_info(_message, socket), do: {:cont, socket}

  def load_views(socket) do
    views = Bee.Views.views()

    assign(socket,
      containers: Bee.Views.all(),
      views: views,
      view_contents: Map.new(views, &{&1.id, Bee.UI.view(socket.assigns.root, &1.id)})
    )
  end

  # The shown container's plugin views need their plugin running.
  defp views_shown(socket) do
    for view <- socket.assigns.views,
        view.container == socket.assigns.sidebar_view,
        do: Plugins.view_shown(view.id, socket.assigns.root)

    :ok
  end

  # Views of the shown container whose `when` holds.
  def visible_views(assigns, container \\ nil) do
    ctx = assigns.context
    container = container || assigns.sidebar_view

    for view <- assigns.views,
        view.container == container,
        Bee.Commands.When.eval(view.when_ast, ctx),
        do: view
  end

  # The shown views with their header buttons and their items' inline buttons
  # (per item context), for BeeWeb.Workbench.Sidebar.
  def sidebar_views(assigns), do: container_views(assigns, assigns.sidebar_view)

  # The panel's sections (BeeWeb.Workbench.Panel): the containers there
  # (Workbench "Views containers"), with their views like the sidebar's.
  def panel_sections(assigns) do
    for container <- Workbench.containers(workbench_from(assigns), :panel, assigns.containers),
        do: %{container: container, views: container_views(assigns, container.id)}
  end

  # The panel's own buttons (panel/title): maximize reads "restore" when it is.
  def panel_actions(assigns) do
    for action <- Menus.toolbar(assigns, "panel/title") do
      if action.command == "workbench.action.toggleMaximizedPanel" and assigns.panel_maximized,
        do: %{action | icon: "chevron-down", label: "Restore Panel Size"},
        else: action
    end
  end

  defp container_views(assigns, container) do
    for view <- visible_views(assigns, container) do
      contexts =
        case assigns.view_contents[view.id] do
          %{items: items} ->
            item_contexts(items)

          # Bee's Plugins views: their rows (BeeWeb.Workbench.PluginsView).
          _ when view.id in ["workbench.extensions.installed", "workbench.extensions.builtin"] ->
            BeeWeb.Workbench.PluginsView.contexts()

          _ when view.id == "workbench.extensions.marketplace" ->
            BeeWeb.Workbench.MarketplaceView.contexts()

          _ ->
            []
        end

      %{
        view: view,
        title_actions: Menus.toolbar(assigns, "view/title", %{"view" => view.id}),
        item_actions:
          Map.new(contexts, fn context ->
            {context,
             Menus.toolbar(
               assigns,
               "view/item/context",
               %{"view" => view.id, "viewItem" => context},
               true
             )}
          end)
      }
    end
  end

  defp item_contexts(items) do
    items
    |> Enum.flat_map(&[&1.context | item_contexts(&1.children)])
    |> Enum.uniq()
  end

  # Activity bar entries with the summed badges of their plugin views.
  def activity_bar(assigns) do
    for container <-
          Workbench.containers(workbench_from(assigns), :activitybar, assigns.containers) do
      badge =
        assigns.views
        |> Enum.filter(&(&1.container == container.id))
        |> Enum.map(&((assigns.view_contents[&1.id] || %{})[:badge] || 0))
        |> Enum.sum()

      Map.put(container, :badge, if(badge > 0, do: badge))
    end
  end

  def load_decorations(socket) do
    root = socket.assigns.root
    decorations = Bee.UI.Decorations.for_workspace(Bee.UI.decorations(root), root)
    assign(socket, file_decorations: decorations)
  end
end

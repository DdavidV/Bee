defmodule BeeWeb.EditorLive.Layout do
  @moduledoc """
  The window's layout: the sizes of the sidebar and the panel (the Sash
  hook), and the order of the activity bar's icons and the panel's
  sections.
  """

  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench

  ## Events

  # An activity bar icon was dragged to another place: the containers' new order.
  def handle_event("reorder_activity", %{"order" => order}, socket) when is_list(order),
    do: {:halt, change(socket, &Workbench.reorder_activity(&1, order))}

  # A sash was dragged (or double-clicked: size nil) – see the Sash hook.
  def handle_event("layout_resize", %{"part" => part, "size" => size}, socket)
      when part in ["sidebar", "panel"],
      do: {:halt, change(socket, &Workbench.resize(&1, String.to_existing_atom(part), size))}

  # A sash was pulled past the minimum and released: hide that part.
  def handle_event("layout_hide", %{"part" => "sidebar"}, socket) do
    if socket.assigns.sidebar_open,
      do: {:halt, change(socket, &Workbench.toggle_sidebar/1)},
      else: {:halt, socket}
  end

  def handle_event("layout_hide", %{"part" => "panel"}, socket) do
    if socket.assigns.panel_open,
      do: {:halt, change(socket, &Workbench.toggle_panel/1)},
      else: {:halt, socket}
  end

  # A panel section's tab was dragged to another place: their container ids.
  def handle_event("reorder_panel", %{"order" => order}, socket) when is_list(order),
    do: {:halt, change(socket, &Workbench.reorder_panel(&1, order))}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  # Sizes the browser remembered (sent with the connection), so the first
  # connected render already has them.
  def restore_layout(wb, socket) do
    layout = if connected?(socket), do: get_connect_params(socket)["layout"], else: nil

    case layout do
      %{} ->
        wb =
          Enum.reduce([{"sidebar", :sidebar}, {"panel", :panel}], wb, fn {key, part}, wb ->
            if is_number(layout[key]), do: Workbench.resize(wb, part, layout[key]), else: wb
          end)

        wb =
          if is_list(layout["activity"]),
            do: Workbench.reorder_activity(wb, layout["activity"]),
            else: wb

        if is_list(layout["panelSections"]),
          do: Workbench.reorder_panel(wb, layout["panelSections"]),
          else: wb

      _ ->
        wb
    end
  end

  # The layout's CSS variables. Before the LiveView connects, the sizes the
  # browser saved (root.html.heex) win over the defaults.
  def layout_style(sidebar_width, panel_height, connected?) do
    if connected? do
      "--sidebar-width: #{sidebar_width}px; --panel-height: #{panel_height}px"
    else
      "--sidebar-width: var(--saved-sidebar-width, #{sidebar_width}px); " <>
        "--panel-height: var(--saved-panel-height, #{panel_height}px)"
    end
  end
end

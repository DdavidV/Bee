defmodule BeeWeb.EditorLive.Derived do
  @moduledoc """
  What the page shows that is computed from other assigns: the `when`
  context, the menus, the toolbars, the views, the problems.

  They are kept as assigns of their own, and computed again only when what
  they are made of changed (`sync/1`, after every event and message – see
  `BeeWeb.EditorLive`). The template then reads `@menubar`, `@context`, …
  like any assign, so LiveView's change tracking sees what changed and
  what didn't: a render that moves the cursor sends nothing about the
  menus. (Computed in the template from all of `assigns`, they would be
  built, and sent, on every render.)

  `@derived` lists them in order – a later one may be made of an earlier
  one – each with the assigns it is made of.
  """

  import Phoenix.Component, only: [assign: 3, changed?: 2]

  alias Bee.Workbench
  alias BeeWeb.EditorLive.{Menus, Palette, Problems, Views, Window}
  alias BeeWeb.Workbench.EditorArea

  # What the menus and toolbars are made of, besides the context.
  @menus [:commands_by_id, :menu_items, :keybinding_labels]
  @problems [
    :settings_errors,
    :keybinding_errors,
    :plugin_errors,
    :diagnostics,
    :language_problems
  ]

  @derived [
    {:context,
     Workbench.fields() ++
       [:config_context, :selection, :notifications_open, :ui_context, :language_features]},
    {:groups, [:tabs, :active, :group, :others]},
    {:window_title, [:tabs, :others, :active, :extension_details, :root]},
    {:menubar, [:context, :menus, :open_menu | @menus]},
    {:editor_actions, [:context | @menus]},
    {:context_menu_items, [:context, :context_menu, :submenus | @menus]},
    {:activity_bar, [:containers, :activity_order, :views, :view_contents]},
    {:sidebar_views, [:context, :views, :sidebar_view, :view_contents | @menus]},
    {:panel_sections,
     [:panel_open, :context, :views, :panel_containers, :panel_order, :view_contents | @menus]},
    {:panel_actions, [:panel_open, :panel_maximized, :context | @menus]},
    {:problems, @problems},
    {:problem_entries, [:panel_open | @problems]},
    {:palette_items,
     [
       :palette,
       :quick_open,
       :commands,
       :settings,
       :root,
       :context,
       :menu_items,
       :keybinding_labels
     ]}
  ]

  @doc "Computes again what is made of assigns that changed."
  def sync(socket) do
    Enum.reduce(@derived, socket, fn {key, inputs}, socket ->
      if not is_map_key(socket.assigns, key) or Enum.any?(inputs, &changed?(socket, &1)),
        do: assign(socket, key, derive(key, socket.assigns)),
        else: socket
    end)
  end

  defp derive(:context, assigns), do: Window.context(assigns)

  # The editor groups by id: `%{id => %{id, tabs, active}}`.
  defp derive(:groups, assigns) do
    wb = Window.workbench_from(assigns)
    Map.new(Workbench.groups(wb), &{&1.id, &1})
  end

  defp derive(:window_title, assigns) do
    tab = assigns.active && Workbench.tab(Window.workbench_from(assigns), assigns.active)
    Window.window_title(tab && EditorArea.tab_label(tab, assigns.extension_details), assigns.root)
  end

  defp derive(:menubar, assigns), do: Menus.menubar(assigns)
  defp derive(:editor_actions, assigns), do: Menus.toolbar(assigns, "editor/title")
  defp derive(:context_menu_items, assigns), do: Menus.context_menu_items(assigns)
  defp derive(:activity_bar, assigns), do: Views.activity_bar(assigns)
  defp derive(:sidebar_views, assigns), do: Views.sidebar_views(assigns)

  # (The panel shows nothing while it is closed.)
  defp derive(:panel_sections, %{panel_open: false}), do: []
  defp derive(:panel_sections, assigns), do: Views.panel_sections(assigns)
  defp derive(:panel_actions, %{panel_open: false}), do: []
  defp derive(:panel_actions, assigns), do: Views.panel_actions(assigns)
  defp derive(:problems, assigns), do: Problems.problems(assigns)
  defp derive(:problem_entries, %{panel_open: false}), do: []
  defp derive(:problem_entries, assigns), do: Problems.problem_entries(assigns)
  defp derive(:palette_items, assigns), do: Palette.palette_items(assigns)
end

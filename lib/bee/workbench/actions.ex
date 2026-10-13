defmodule Bee.Workbench.Actions do
  @moduledoc """
  Implementations of Bee's built-in server commands. Their titles, keys and
  menu entries are in `priv/contributions/bee.json`.
  """
  use Bee.Commands.Command

  alias Bee.Workbench
  alias Bee.Workbench.{Marketplace, Search}

  @command "workbench.action.showCommands"
  def show_commands(wb), do: Workbench.open_palette(wb)

  @command "workbench.action.quickOpen"
  def quick_open(wb), do: Workbench.open_quick_open(wb)

  # Quick Open's other modes (`>` for commands): the query becomes the prefix.
  @command "workbench.action.quickOpenPrefix"
  def quick_open_prefix(wb, [prefix]) when is_binary(prefix),
    do: Workbench.open_quick_open(wb, prefix)

  def quick_open_prefix(wb, _args), do: wb

  @command "workbench.action.gotoSymbol"
  def goto_symbol(wb), do: Workbench.open_quick_open(wb, "@")

  @command "workbench.action.showAllSymbols"
  def show_all_symbols(wb), do: Workbench.open_quick_open(wb, "#")

  ## Editors (tabs)
  #
  # The tab's right-click menu (editor/title/context), its × and a middle
  # click pass the tab's path; from the palette or a key there is none: the
  # active editor. Unsaved changes are only dropped once confirmed.

  @command "workbench.action.closeActiveEditor"
  def close_active_editor(%{active: nil} = wb), do: wb
  def close_active_editor(wb), do: close_editors(wb, [wb.active])

  @command "workbench.action.closeEditor"
  def close_editor(wb, args) do
    wb = in_tab_group(wb, args)
    Workbench.chain(wb, &close_editors(&1, List.wrap(tab_path(&1, args))))
  end

  @command "workbench.action.closeOtherEditors"
  def close_other_editors(wb, args) do
    {wb, effects} = in_tab_group(wb, args)

    case tab_path(wb, args) do
      nil ->
        {wb, effects}

      keep ->
        {wb, effects}
        |> Workbench.chain(&Workbench.activate_editor(&1, keep))
        |> Workbench.chain(&close_editors(&1, Workbench.tab_paths(&1) -- [keep]))
    end
  end

  ## Editor groups

  @command "workbench.action.splitEditor"
  def split_editor(wb, args),
    do: wb |> in_tab_group(args) |> Workbench.chain(&show_then(&1, args, :right))

  @command "workbench.action.splitEditorDown"
  def split_editor_down(wb, args),
    do: wb |> in_tab_group(args) |> Workbench.chain(&show_then(&1, args, :down))

  # The tab named by the arguments is shown, then its group split.
  defp show_then(wb, args, direction) do
    case tab_path(wb, args) do
      nil ->
        wb

      path ->
        wb
        |> Workbench.activate_editor(path)
        |> Workbench.wrap()
        |> Workbench.chain(&Workbench.split(&1, direction))
    end
  end

  @command "workbench.action.focusNextGroup"
  def focus_next_group(wb), do: focus_group_by(wb, 1)

  @command "workbench.action.focusPreviousGroup"
  def focus_previous_group(wb), do: focus_group_by(wb, -1)

  defp focus_group_by(wb, step) do
    ids = Enum.map(Workbench.groups(wb), & &1.id)
    index = Enum.find_index(ids, &(&1 == wb.group))
    Workbench.focus_group(wb, Enum.at(ids, rem(index + step + length(ids), length(ids))))
  end

  @command "workbench.action.closeAllEditors"
  def close_all_editors(wb, args) do
    wb |> in_tab_group(args) |> Workbench.chain(&close_editors(&1, Workbench.tab_paths(&1)))
  end

  # Keep Open: the editor of `path` (a double click on its tab, or on the
  # file in the Explorer), or the active one, is no preview any more. A file
  # that isn't open yet is opened to stay.
  @command "workbench.action.keepEditor"
  def keep_editor(wb, [path | _]) when is_binary(path) do
    if Workbench.open?(wb, path),
      do: Workbench.keep_editor(wb, path),
      else: Workbench.open_editor(wb, path, replace: true)
  end

  def keep_editor(%{active: nil} = wb, _args), do: wb
  def keep_editor(wb, _args), do: Workbench.keep_editor(wb, wb.active)

  # A file shown as an image (or played), or one that isn't shown (binary,
  # very large), as text instead, in the same tab: the editor of `path`, or
  # the active one (the Open Anyway of such a file's editor).
  @command "workbench.action.reopenTextEditor"
  def reopen_text_editor(wb, args) do
    wb = in_tab_group(wb, args)

    Workbench.chain(wb, fn wb ->
      case Enum.find(wb.tabs, &(&1.path == tab_path(wb, args))) do
        %{kind: kind, path: path} when kind in [:media, :custom, :binary] ->
          {wb, [{:open_file, path, {:with, Bee.CustomEditors.text()}}]}

        _ ->
          wb
      end
    end)
  end

  ## Open With…
  #
  # Like VS Code's: a pick of the editors a file can be opened with – the
  # text editor, and the ones for its name (`Bee.CustomEditors`) – and, last,
  # a way to make one of them the default for files like it
  # (workbench.editorAssociations).

  # A tab's (its right-click menu: [path, group]), or the active editor's.
  @command "workbench.action.reopenWithEditor"
  def reopen_with_editor(wb, args) do
    wb = in_tab_group(wb, args)

    Workbench.chain(wb, fn wb ->
      case Enum.find(wb.tabs, &(&1.path == tab_path(wb, args))) do
        %{path: path} = tab -> if Workbench.file?(tab), do: pick_editor(wb, path), else: wb
        nil -> wb
      end
    end)
  end

  # A file's in the Explorer (its right-click menu: [path]).
  @command "explorer.openWith"
  def explorer_open_with(wb, [path | _]) when is_binary(path) do
    if File.regular?(path), do: pick_editor(wb, path), else: wb
  end

  def explorer_open_with(wb, _args), do: wb

  @configure "configure"

  defp pick_editor(wb, path) do
    active = editor_id(Enum.find(wb.tabs, &(&1.path == path)))
    default = default_editor(wb, path)

    items =
      for %{id: id, label: label} <- Bee.CustomEditors.choices(path) do
        notes =
          if(id == active, do: ["Active"], else: []) ++
            if(id == default, do: ["Default"], else: [])

        %{label: label, description: Enum.join(notes, " and "), value: id}
      end

    configure = %{
      label: "Configure default editor for '#{Bee.CustomEditors.pattern(path)}'…",
      description: "",
      value: @configure
    }

    Workbench.open_quick_pick(wb, %{
      items: items ++ [configure],
      index: Enum.find_index(items, &(&1.value == active)) || 0,
      command: "bee.openWith",
      arguments: [path],
      placeholder: "Select editor for '#{Path.basename(path)}'"
    })
  end

  # The editor a tab shows its file in, as Open With… names them.
  defp editor_id(%{kind: :file}), do: Bee.CustomEditors.text()

  defp editor_id(%{kind: kind, view_type: view_type}) when kind in [:media, :custom],
    do: view_type

  defp editor_id(_other), do: nil

  defp default_editor(wb, path) do
    associations = Bee.Settings.get("workbench.editorAssociations", wb.root)
    Bee.CustomEditors.for_file(path, associations) || Bee.CustomEditors.text()
  end

  # The pick's choice: [path, editor].
  @command "bee.openWith"
  def open_with(wb, [path, @configure]) when is_binary(path) do
    default = default_editor(wb, path)
    pattern = Bee.CustomEditors.pattern(path)

    items =
      for %{id: id, label: label} <- Bee.CustomEditors.choices(path) do
        %{label: label, description: if(id == default, do: "Default", else: ""), value: id}
      end

    Workbench.open_quick_pick(wb, %{
      items: items,
      index: Enum.find_index(items, &(&1.value == default)) || 0,
      command: "bee.setDefaultEditor",
      arguments: [pattern],
      placeholder: "Select new default editor for '#{pattern}'"
    })
  end

  def open_with(wb, [path, editor]) when is_binary(path) and is_binary(editor) do
    case Enum.find(wb.tabs, &(&1.path == path)) do
      # (Its text would go with its editor.)
      %{kind: :file, dirty: true} when editor != "default" ->
        if Workbench.elsewhere?(wb, path),
          do: {wb, [{:open_file, path, {:with, editor}}]},
          else:
            {wb,
             [{:notify, :error, "Save #{Path.basename(path)} to open it with another editor"}]}

      _ ->
        {wb, [{:open_file, path, {:with, editor}}]}
    end
  end

  def open_with(wb, _args), do: wb

  # The second pick's choice: [pattern, editor], kept in the user settings.
  @command "bee.setDefaultEditor"
  def set_default_editor(wb, [pattern, editor]) when is_binary(pattern) and is_binary(editor) do
    put = fn current -> Map.put(if(is_map(current), do: current, else: %{}), pattern, editor) end
    {wb, [{:update_setting, "workbench.editorAssociations", put}]}
  end

  def set_default_editor(wb, _args), do: wb

  # The confirmation's answer: [paths] ("" is Cancel).
  @command "workbench.action.closeEditors.confirmed"
  def close_editors_confirmed(wb, [paths]) when is_list(paths),
    do: Workbench.close_editors(wb, paths)

  def close_editors_confirmed(wb, _args), do: wb

  # The tab named by the arguments (in the focused group), else the active one.
  defp tab_path(wb, [path | _]) when is_binary(path),
    do: if(Workbench.here?(wb, path), do: path)

  defp tab_path(wb, _args), do: wb.active

  # A tab's commands name its group after its path (its ×, its menu): that
  # group is the one meant, and focused. `{wb, effects}`.
  defp in_tab_group(wb, [_path, group | _]) when is_integer(group),
    do: wb |> Workbench.focus_group(group) |> Workbench.wrap()

  defp in_tab_group(wb, _args), do: {wb, []}

  # Closes them, asking first when some have unsaved changes.
  # (Not for a file another group still shows: nothing is lost.)
  defp close_editors(wb, paths) do
    case wb |> Workbench.dirty_paths(paths) |> Enum.reject(&Workbench.elsewhere?(wb, &1)) do
      [] ->
        Workbench.close_editors(wb, paths)

      dirty ->
        names = Enum.map_join(dirty, ", ", &Path.basename/1)

        Workbench.open_quick_pick(wb, %{
          items: [
            %{label: "Discard Changes and Close", description: names, value: paths},
            %{label: "Cancel", description: "", value: ""}
          ],
          command: "workbench.action.closeEditors.confirmed",
          placeholder: "Discard unsaved changes to #{names}?"
        })
    end
  end

  @command "workbench.action.toggleSidebarVisibility"
  def toggle_sidebar_visibility(wb), do: Workbench.toggle_sidebar(wb)

  @command "workbench.action.toggleAuxiliaryBar"
  def toggle_auxiliary_bar(wb), do: Workbench.toggle_auxiliary(wb)

  @command "workbench.action.closeAuxiliaryBar"
  def close_auxiliary_bar(%{auxiliary_open: true} = wb), do: Workbench.toggle_auxiliary(wb)
  def close_auxiliary_bar(wb), do: wb

  @command "workbench.view.explorer"
  def show_explorer(wb), do: Workbench.show_view(wb, "explorer")

  @command "workbench.view.search"
  def show_search(wb), do: Workbench.show_view(wb, "search")

  @command "workbench.action.findInFiles"
  def find_in_files(wb), do: {Workbench.reveal_view(wb, "search"), [{:find_in_files, false}]}

  @command "workbench.action.replaceInFiles"
  def replace_in_files(wb), do: {Workbench.reveal_view(wb, "search"), [{:find_in_files, true}]}

  @command "search.action.refreshSearchResults"
  def refresh_search(wb), do: Search.refresh(wb)

  @command "search.action.clearSearchResults"
  def clear_search(wb), do: Search.clear(wb)

  @command "search.action.collapseSearchResults"
  def collapse_search(wb), do: Search.collapse_all(wb)

  @command "toggleSearchCaseSensitive"
  def toggle_search_case_sensitive(wb), do: Search.toggle(wb, :case_sensitive)

  @command "toggleSearchWholeWord"
  def toggle_search_whole_word(wb), do: Search.toggle(wb, :whole_word)

  @command "toggleSearchRegex"
  def toggle_search_regex(wb), do: Search.toggle(wb, :regex)

  @command "workbench.view.extensions"
  def show_plugins(wb), do: Workbench.show_view(wb, "extensions")

  @command "workbench.action.togglePanel"
  def toggle_panel(wb), do: Workbench.toggle_panel(wb)

  ## Panel

  @command "workbench.action.closePanel"
  def close_panel(%{panel_open: true} = wb), do: Workbench.toggle_panel(wb)
  def close_panel(wb), do: wb

  @command "workbench.action.toggleMaximizedPanel"
  def toggle_maximized_panel(wb), do: Workbench.toggle_maximized_panel(wb)

  # A section's tab in the panel: [container id].
  @command "workbench.action.showPanel"
  def show_panel(wb, [id]) when is_binary(id), do: Workbench.show_panel(wb, id)
  def show_panel(wb, _args), do: wb

  ## Where the views containers are (Workbench "Views containers")
  #
  # The right-click menu of an activity bar icon or a panel tab
  # (viewContainer/title/context) passes its container id; from the palette
  # there is none: the container is picked from a list.

  @command "workbench.action.moveViewContainerToPanel"
  def move_container_to_panel(wb, args), do: move_container(wb, args, :panel)

  @command "workbench.action.moveViewContainerToSideBar"
  def move_container_to_side_bar(wb, args), do: move_container(wb, args, :activitybar)

  defp move_container(wb, [id | _], location) when is_binary(id),
    do: Workbench.move_container(wb, id, location)

  defp move_container(wb, _args, location) do
    {command, name} =
      case location do
        :panel -> {"workbench.action.moveViewContainerToPanel", "the panel"}
        :activitybar -> {"workbench.action.moveViewContainerToSideBar", "the side bar"}
      end

    pick_container(
      wb,
      Enum.filter(
        Bee.Views.all(),
        &(&1.movable and Workbench.container_location(wb, &1.id) != location)
      ),
      command,
      "Select what to move to #{name}"
    )
  end

  @command "workbench.action.hideViewContainer"
  def hide_container(wb, [id | _]) when is_binary(id), do: Workbench.hide_container(wb, id)

  def hide_container(wb, _args) do
    pick_container(
      wb,
      Enum.reject(Bee.Views.all(), &Workbench.container_hidden?(wb, &1.id)),
      "workbench.action.hideViewContainer",
      "Select what to hide"
    )
  end

  # Every container, to hide the one picked, or show it again.
  @command "workbench.action.toggleViewContainer"
  def toggle_container(wb, [id | _]) when is_binary(id) do
    if Workbench.container_hidden?(wb, id),
      do: Workbench.show_container(wb, id),
      else: Workbench.hide_container(wb, id)
  end

  def toggle_container(wb, _args) do
    pick_container(
      wb,
      Bee.Views.all(),
      "workbench.action.toggleViewContainer",
      "Select what to show or hide"
    )
  end

  @command "workbench.action.resetViewLocations"
  def reset_view_locations(wb), do: Workbench.reset_containers(wb)

  defp pick_container(wb, [], _command, _placeholder),
    do: Workbench.set_status(wb, "Nothing to pick")

  defp pick_container(wb, containers, command, placeholder) do
    items =
      for c <- containers do
        where =
          case Workbench.container_location(wb, c.id) do
            :activitybar -> "Side Bar"
            :panel -> "Panel"
            :auxiliarybar -> "Secondary Side Bar"
          end

        %{
          label: c.title,
          description:
            if(Workbench.container_hidden?(wb, c.id), do: "#{where}, hidden", else: where),
          value: c.id,
          icon: c.icon
        }
      end

    Workbench.open_quick_pick(wb, %{items: items, command: command, placeholder: placeholder})
  end

  # An Elixir shell inside Bee, the panel's Bee Console section (Bee.Console).
  @command "bee.console.open"
  def open_console(wb), do: Workbench.show_panel(wb, "console")

  # What extensions write for the user (Bee.Output), the panel's Output section.
  @command "workbench.action.output.toggleOutput"
  def show_output(wb), do: Workbench.show_panel(wb, "output")

  @command "workbench.actions.view.problems"
  def show_problems(wb), do: Workbench.show_panel(wb, "problems")

  @command "workbench.action.showReferences"
  def show_references(wb), do: Workbench.show_container(wb, "references")

  @command "workbench.output.action.clearOutput"
  def clear_output(wb), do: {wb, [:clear_output]}

  ## Notifications (the window's: BeeWeb.Workbench.Notifications)

  @command "notifications.toggleList"
  def toggle_notifications(wb), do: {wb, [{:notifications, :toggle}]}

  @command "notifications.showList"
  def show_notifications(wb), do: {wb, [{:notifications, :show}]}

  @command "notifications.hideList"
  def hide_notifications(wb), do: {wb, [{:notifications, :hide}]}

  @command "notifications.clearAll"
  def clear_notifications(wb), do: {wb, [{:notifications, :clear}]}

  @command "notifications.hideToasts"
  def hide_toasts(wb), do: {wb, [{:notifications, :hide_toasts}]}

  # Formatting by an extension's formatter (Bee.Languages.Features).
  @command "editor.action.formatDocument"
  def format_document(wb), do: format(wb, :document)

  @command "editor.action.formatSelection"
  def format_selection(wb), do: format(wb, :selection)

  defp format(wb, what) do
    case Workbench.active_file(wb) do
      nil -> wb
      path -> {wb, [{:format, path, what}]}
    end
  end

  @command "bee.console.clear"
  def clear_console(%{console: nil} = wb), do: wb
  def clear_console(wb), do: {wb, [{:clear_console, wb.console}]}

  @command "workbench.action.terminal.new"
  def new_terminal(wb), do: {wb, [:new_terminal]}

  # Terminal commands act on the terminal of their first argument (the
  # tab right-clicked), else the active one. Given a value too (a name, an
  # icon, a colour) they set it; else they ask for it.

  @command "workbench.action.terminal.kill"
  def kill_terminal(wb, args), do: Workbench.kill_terminal(wb, terminal_id(wb, args))

  @command "workbench.action.terminal.rename"
  def rename_terminal(wb, [id, name]) when is_binary(name),
    do: Workbench.rename_terminal(wb, id, name)

  def rename_terminal(wb, args) do
    case terminal(wb, args) do
      nil ->
        wb

      t ->
        Workbench.open_input_box(wb, %{
          command: "workbench.action.terminal.rename",
          arguments: [t.id],
          value: t.name,
          prompt: "Terminal name",
          placeholder: "Enter a name for the terminal"
        })
    end
  end

  @terminal_icons ~w(command-line code-bracket cpu-chip server server-stack circle-stack
                     cloud globe-alt rocket-launch play bolt fire beaker bug-ant
                     wrench-screwdriver cog-6-tooth cube sparkles star heart flag
                     bookmark document-text folder home shield-check eye chart-bar)

  @command "workbench.action.terminal.changeIcon"
  def change_terminal_icon(wb, [id, icon]) when icon in @terminal_icons,
    do: Workbench.set_terminal_icon(wb, id, icon)

  def change_terminal_icon(wb, args) do
    case terminal(wb, args) do
      nil ->
        wb

      t ->
        Workbench.open_quick_pick(wb, %{
          items:
            for(
              icon <- @terminal_icons,
              do: %{label: icon, description: "", value: icon, icon: icon, color: t.color}
            ),
          command: "workbench.action.terminal.changeIcon",
          arguments: [t.id],
          placeholder: "Select an icon for #{t.name}"
        })
    end
  end

  @command "workbench.action.terminal.changeColor"
  def change_terminal_color(wb, [id, color]) when is_binary(color),
    do: Workbench.set_terminal_color(wb, id, if(color == "default", do: nil, else: color))

  def change_terminal_color(wb, args) do
    case terminal(wb, args) do
      nil ->
        wb

      t ->
        colors =
          for c <- ["default" | Workbench.terminal_colors()],
              do: %{
                label: String.capitalize(c),
                description: if(c == (t.color || "default"), do: "current", else: ""),
                value: c,
                icon: t.icon,
                color: if(c != "default", do: c)
              }

        Workbench.open_quick_pick(wb, %{
          items: colors,
          command: "workbench.action.terminal.changeColor",
          arguments: [t.id],
          placeholder: "Select a color for #{t.name}"
        })
    end
  end

  defp terminal(wb, args) do
    id = terminal_id(wb, args)
    Enum.find(wb.terminals, &(&1.id == id))
  end

  defp terminal_id(_wb, [id | _]) when is_integer(id), do: id
  defp terminal_id(wb, _args), do: wb.active_term

  # The settings page (BeeWeb.Workbench.SettingsEditor), on the user's
  # settings or the folder's.
  # (With a text, as in VS Code: the settings it finds.)
  @command "workbench.action.openSettings"
  def open_settings(wb, args \\ [])

  def open_settings(wb, [query | _]) when is_binary(query),
    do: Workbench.open_settings(wb, :user, {query, System.unique_integer([:positive])})

  def open_settings(wb, _args), do: Workbench.open_settings(wb, :user)

  @command "workbench.action.openWorkspaceSettings"
  def open_workspace_settings(wb), do: Workbench.open_settings(wb, :workspace)

  @command "workbench.action.openSettingsJson"
  def open_settings_json(wb), do: Workbench.open_editor(wb, Bee.Settings.ensure_user_file!())

  @command "workbench.action.openWorkspaceSettingsFile"
  def open_workspace_settings_file(wb),
    do: Workbench.open_editor(wb, Bee.Settings.ensure_workspace_file!(wb.root))

  @command "workbench.action.openGlobalKeybindingsFile"
  def open_global_keybindings_file(wb),
    do: Workbench.open_editor(wb, Bee.Commands.Keybindings.ensure_user_file!())

  # Like VS Code's: pick one of the contributed color themes, light ones
  # first; the selected one is previewed until the pick closes. With a
  # plugin's name, only its themes (its details page's Set Color Theme).
  @command "workbench.action.selectTheme"
  def select_theme(wb, args \\ []) do
    current = Bee.ColorThemes.get(Bee.Settings.get("workbench.colorTheme")).id

    themes =
      Bee.ColorThemes.themes()
      |> only_plugin(args)
      |> Enum.sort_by(&(&1.base == :dark))

    items =
      for t <- themes do
        source = if t.plugin, do: t.plugin, else: "Bee"
        kind = if t.base == :light, do: "light", else: "dark"

        %{
          label: t.label,
          description:
            Enum.join([source, kind] ++ if(t.id == current, do: ["current"], else: []), " · "),
          value: t.id
        }
      end

    Workbench.open_quick_pick(wb, %{
      items: items,
      index: Enum.find_index(themes, &(&1.id == current)) || 0,
      preview: :color_theme,
      command: "workbench.action.setColorTheme",
      placeholder: "Select Color Theme (Up/Down keys to preview)"
    })
  end

  # The pick's choice, saved in the user settings.
  @command "workbench.action.setColorTheme"
  def set_color_theme(wb, [id]) when is_binary(id),
    do: {wb, [{:update_setting, "workbench.colorTheme", id}]}

  def set_color_theme(wb, _args), do: wb

  defp only_plugin(themes, [name | _]) when is_binary(name),
    do: Enum.filter(themes, &(&1.plugin == name))

  defp only_plugin(themes, _args), do: themes

  # Like VS Code's: pick one of the contributed file icon themes (or none);
  # with a plugin's name, one of its themes.
  @command "workbench.action.selectIconTheme"
  def select_icon_theme(wb, args \\ []) do
    current = Bee.Settings.get("workbench.iconTheme")
    none = if args == [], do: [{"None", "Bee's own icons", nil}], else: []

    items =
      for {label, plugin, id} <-
            none ++
              for(t <- only_plugin(Bee.IconThemes.themes(), args), do: {t.label, t.plugin, t.id}) do
        %{
          label: label,
          description: if(id == current, do: "#{plugin} · current", else: plugin),
          value: id || ""
        }
      end

    Workbench.open_quick_pick(wb, %{
      items: items,
      command: "workbench.action.setIconTheme",
      placeholder: "Select File Icon Theme"
    })
  end

  # The pick's choice: a theme id, "" for none. Saved in the user settings.
  @command "workbench.action.setIconTheme"
  def set_icon_theme(wb, [id]) when is_binary(id),
    do: {wb, [{:update_setting, "workbench.iconTheme", if(id == "", do: nil, else: id)}]}

  def set_icon_theme(wb, _args), do: wb

  ## Plugins' details

  # Like VS Code's extension editor: the plugin's details in an editor tab.
  @command "extension.open"
  def open_extension(wb, [name | _]) when is_binary(name), do: Workbench.open_extension(wb, name)
  def open_extension(wb, _args), do: wb

  ## Folders (workspaces)

  # Like VS Code's: the desktop app shows its native folder dialog, a
  # browser can't, so there the folder's path is typed.
  @command "workbench.action.files.openFolder"
  def open_folder(wb), do: ask_folder(wb, "same", "Folder to open in this window")

  @command "workbench.action.files.openFolderInNewWindow"
  def open_folder_in_new_window(wb), do: ask_folder(wb, "new", "Folder to open in a new window")

  # The answer of the input box or the dialog: [where, path].
  @command "bee.openFolder"
  def open_folder_path(wb, [where, path]) when where in ["same", "new"] and is_binary(path),
    do: {wb, [{:open_folder, path, if(where == "new", do: :new_window, else: :this_window)}]}

  def open_folder_path(wb, _args), do: wb

  # A file to open in this window, by absolute path (the desktop app's
  # `bee FILE`): any file, like the settings files outside the folder.
  @command "bee.openFile"
  def open_file_path(wb, [path]) when is_binary(path) do
    if File.regular?(path),
      do: Workbench.open_editor(wb, path),
      else: {wb, [{:notify, :error, "Can't open #{path}: no such file"}]}
  end

  def open_file_path(wb, _args), do: wb

  defp ask_folder(wb, where, prompt) do
    if Bee.Mode.desktop?(),
      do: {wb, [{:pick_folder, where, prompt}]},
      else: type_folder(wb, where, prompt)
  end

  defp type_folder(wb, where, prompt) do
    Workbench.open_input_box(wb, %{
      command: "bee.openFolder",
      arguments: [where],
      value: Path.dirname(wb.root) <> "/",
      prompt: prompt,
      placeholder: "/path/to/folder, ~/folder, or relative to this one"
    })
  end

  ## Explorer (its right-click menu, explorer/context)
  #
  # The menu passes the file's or folder's absolute path; from the palette
  # or the Explorer's title buttons there is none: the workspace folder.

  @command "explorer.newFile"
  def new_file(wb, args), do: explorer_edit(wb, %{kind: :new_file, dir: folder(wb, args)})

  @command "explorer.newFolder"
  def new_folder(wb, args), do: explorer_edit(wb, %{kind: :new_folder, dir: folder(wb, args)})

  @command "renameFile"
  def rename_file(wb, [path]) when is_binary(path),
    do: explorer_edit(wb, %{kind: :rename, path: path})

  def rename_file(wb, _args), do: wb

  # Asks first, in the quick input.
  @command "deleteFile"
  def delete_file(wb, [path]) when is_binary(path) do
    name = Path.basename(path)
    what = if File.dir?(path), do: "the folder '#{name}' and its contents", else: "'#{name}'"

    Workbench.open_quick_pick(wb, %{
      items: [
        %{
          label: "Delete",
          description: "permanently: #{Bee.Workspace.FS.relative(wb.root, path)}",
          value: path
        },
        %{label: "Cancel", description: "", value: ""}
      ],
      command: "deleteFile.confirmed",
      placeholder: "Are you sure you want to delete #{what}?"
    })
  end

  def delete_file(wb, _args), do: wb

  @command "deleteFile.confirmed"
  def delete_file_confirmed(wb, [path]) when is_binary(path) and path != "",
    do: {wb, [{:delete_file, path}]}

  def delete_file_confirmed(wb, _args), do: wb

  @command "filesExplorer.cut"
  def cut_file(wb, [path]) when is_binary(path), do: Workbench.set_clipboard(wb, :cut, [path])
  def cut_file(wb, _args), do: wb

  @command "filesExplorer.copy"
  def copy_file(wb, [path]) when is_binary(path), do: Workbench.set_clipboard(wb, :copy, [path])
  def copy_file(wb, _args), do: wb

  # Into the folder right-clicked, or the folder of the file.
  @command "filesExplorer.paste"
  def paste_file(%{clipboard: %{op: op, paths: paths}} = wb, args) do
    wb = if op == :cut, do: Workbench.clear_clipboard(wb), else: wb
    {wb, [{:paste_files, op, paths, folder(wb, args)}]}
  end

  def paste_file(wb, _args), do: wb

  defp explorer_edit(wb, edit),
    do: {Workbench.reveal_view(wb, "explorer"), [{:explorer_edit, edit}]}

  defp folder(_wb, [path | _]) when is_binary(path),
    do: if(File.dir?(path), do: path, else: Path.dirname(path))

  defp folder(wb, _args), do: wb.root

  ## Snippets (Bee.Snippets)

  # VS Code's: a pick of the active file's language's snippets.
  @command "editor.action.insertSnippet"
  def insert_snippet(wb) do
    case Workbench.active_file(wb) do
      nil ->
        {wb, [{:notify, :info, "Open a file to insert a snippet into"}]}

      path ->
        lang = Workbench.language(wb, path)

        case Bee.Snippets.for_language(lang) do
          [] ->
            {wb, [{:notify, :info, "No snippets for #{Bee.Languages.name(lang)}"}]}

          snippets ->
            Workbench.open_quick_pick(wb, %{
              items:
                for(
                  s <- snippets,
                  do: %{label: s.name, description: Enum.join(s.prefixes, ", "), value: s.name}
                ),
              command: "bee.insertSnippet",
              arguments: [lang],
              placeholder: "Select a snippet"
            })
        end
    end
  end

  # The pick: [language, snippet name]; the editor inserts it.
  @command "bee.insertSnippet"
  def insert_snippet_named(wb, [lang, name]) when is_binary(lang) and is_binary(name) do
    with path when is_binary(path) <- Workbench.active_file(wb),
         %{body: body} <- Enum.find(Bee.Snippets.for_language(lang), &(&1.name == name)) do
      {wb, [{:push, "cm:snippet", %{path: path, body: body}}]}
    else
      _ -> wb
    end
  end

  def insert_snippet_named(wb, _args), do: wb

  ## Open VSX (the Plugins view's search, `Bee.Workbench.Marketplace`)

  # VS Code's: shows the Plugins view searching for `query`.
  @command "workbench.extensions.search"
  def search_extensions(wb, args) do
    query = with [q | _] when is_binary(q) <- args, do: q, else: (_ -> "")

    {wb, effects} =
      wb |> Workbench.reveal_view("extensions") |> Marketplace.update(query) |> Workbench.wrap()

    {wb, effects ++ [{:push, "marketplace:focus", %{}}]}
  end

  @command "workbench.extensions.action.clearExtensionsSearchResults"
  def clear_extensions_search(wb), do: Marketplace.clear(wb)

  # From a search result's buttons or its details page, with its id
  # (publisher.name).
  @command "workbench.extensions.installExtension"
  def install_extension(wb, [id | _]) when is_binary(id), do: Marketplace.install(wb, id)
  def install_extension(wb, _args), do: wb

  @command "workbench.extensions.updateExtension"
  def update_extension(wb, args), do: install_extension(wb, args)

  @command "bee.plugins.reload"
  def reload_plugins(wb), do: {wb, [:reload_plugins]}

  # From the Plugins view's buttons, with the plugin's name.
  @command "bee.plugins.enable"
  def enable_plugin(wb, [name]) when is_binary(name),
    do: {wb, [{:set_plugin_enabled, name, true}]}

  def enable_plugin(wb, _args), do: wb

  # Asks first: the plugin's folder is deleted.
  @command "bee.plugins.uninstall"
  def uninstall_plugin(wb, [name]) when is_binary(name) do
    case Bee.Plugins.get(name) do
      %{display_name: display, dir: dir} ->
        Workbench.open_quick_pick(wb, %{
          items: [
            %{label: "Uninstall #{display}", description: "deletes #{dir}", value: name},
            %{label: "Cancel", description: "", value: ""}
          ],
          command: "bee.plugins.uninstallConfirmed",
          placeholder: "Uninstall #{display}?"
        })

      nil ->
        wb
    end
  end

  def uninstall_plugin(wb, _args), do: wb

  @command "bee.plugins.uninstallConfirmed"
  def uninstall_plugin_confirmed(wb, [name]) when is_binary(name) and name != "",
    do: {wb, [{:uninstall_plugin, name}]}

  def uninstall_plugin_confirmed(wb, _args), do: wb

  @command "bee.plugins.disable"
  def disable_plugin(wb, [name]) when is_binary(name),
    do: {wb, [{:set_plugin_enabled, name, false}]}

  def disable_plugin(wb, _args), do: wb
end

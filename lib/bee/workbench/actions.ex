defmodule Bee.Workbench.Actions do
  @moduledoc """
  Implementations of Bee's built-in server commands. Their titles, keys and
  menu entries are in `priv/contributions/bee.json`.
  """
  use Bee.Commands.Command

  alias Bee.Workbench
  alias Bee.Workbench.Search

  @command "workbench.action.showCommands"
  def show_commands(wb), do: Workbench.open_palette(wb)

  @command "workbench.action.closeActiveEditor"
  def close_active_editor(%{active: nil} = wb), do: wb
  def close_active_editor(wb), do: Workbench.close_editor(wb, wb.active)

  @command "workbench.action.toggleSidebarVisibility"
  def toggle_sidebar_visibility(wb), do: Workbench.toggle_sidebar(wb)

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

  @command "workbench.action.terminal.new"
  def new_terminal(wb), do: {wb, [:new_terminal]}

  @command "workbench.action.terminal.kill"
  def kill_terminal(wb), do: Workbench.kill_terminal(wb, wb.active_term)

  @command "workbench.action.openSettingsJson"
  def open_settings_json(wb), do: Workbench.open_editor(wb, Bee.Settings.ensure_user_file!())

  @command "workbench.action.openWorkspaceSettingsFile"
  def open_workspace_settings_file(wb),
    do: Workbench.open_editor(wb, Bee.Settings.ensure_workspace_file!())

  @command "workbench.action.openGlobalKeybindingsFile"
  def open_global_keybindings_file(wb),
    do: Workbench.open_editor(wb, Bee.Commands.Keybindings.ensure_user_file!())

  # Like VS Code's: pick one of the contributed file icon themes (or none).
  @command "workbench.action.selectIconTheme"
  def select_icon_theme(wb) do
    current = Bee.Settings.get("workbench.iconTheme")

    items =
      for {label, plugin, id} <- [
            {"None", "Bee's own icons", nil}
            | for(t <- Bee.IconThemes.themes(), do: {t.label, t.plugin, t.id})
          ] do
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

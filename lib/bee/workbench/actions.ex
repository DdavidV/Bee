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

  @command "bee.plugins.reload"
  def reload_plugins(wb), do: {wb, [:reload_plugins]}
end

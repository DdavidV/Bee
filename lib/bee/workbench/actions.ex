defmodule Bee.Workbench.Actions do
  @moduledoc """
  Implementations of Bee's built-in server commands. Their titles, keys and
  menu entries are in `priv/contributions/bee.json`.
  """
  use Bee.Commands.Command

  alias Bee.Workbench

  @command "workbench.action.showCommands"
  def show_commands(wb), do: Workbench.open_palette(wb)

  @command "workbench.action.closeActiveEditor"
  def close_active_editor(%{active: nil} = wb), do: wb
  def close_active_editor(wb), do: Workbench.close_editor(wb, wb.active)

  @command "workbench.action.toggleSidebarVisibility"
  def toggle_sidebar_visibility(wb), do: Workbench.toggle_sidebar(wb)

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
end

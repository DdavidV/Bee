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
    do: Workbench.open_editor(wb, Bee.Settings.ensure_workspace_file!(wb.root))

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
      else: {wb, [{:flash, :error, "Can't open #{path}: no such file"}]}
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

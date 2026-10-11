defmodule BeeWeb.EditorLive.Editors do
  @moduledoc """
  The editors: tabs and groups, and the files they show.

  Text lives in CodeMirror (the `CodeEditor` hook) and in a
  `Bee.Editor.Buffer` per file: the editor's changes come as `doc_changed`
  and `save`, the buffer's (plugins' edits, reloads) go back as `cm:edit`
  and `cm:reload`. Tabs follow their files when Bee moves or deletes them.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Languages
  alias Bee.Settings
  alias Bee.Workbench
  alias Bee.Workspace
  alias Bee.Commands.Keybindings
  alias Bee.Editor.Buffer
  alias Bee.Workspace.RecentFiles
  alias BeeWeb.EditorLive.{Formatting, Json, LanguageFeatures, Notifications}

  ## Events

  def handle_event("activate_tab", %{"path" => path} = params, socket) do
    group = int(params["group"]) || socket.assigns.group
    {:halt, change(socket, &Workbench.activate_editor(&1, group, path))}
  end

  # An editor group got the focus in the page (a click into its editor).
  def handle_event("focus_group", %{"group" => group}, socket),
    do: {:halt, change(socket, &Workbench.focus_group(&1, int(group)))}

  # A tab was dragged to another group (`to`), or to an edge of it (`zone`
  # "right" or "down"): a new group there.
  def handle_event("move_tab", %{"path" => path, "from" => from, "to" => to} = params, socket) do
    zone =
      case params["zone"] do
        "right" -> :right
        "down" -> :down
        _ -> :center
      end

    index = if is_integer(params["index"]), do: params["index"]
    {:halt, change(socket, &Workbench.move_tab(&1, path, int(from), int(to), index, zone))}
  end

  # A tab was dragged to another place: the tabs' new order (paths).
  def handle_event("reorder_tabs", %{"order" => order} = params, socket) when is_list(order) do
    group = int(params["group"]) || socket.assigns.group
    {:halt, change(socket, &Workbench.reorder_tabs(&1, group, order))}
  end

  def handle_event("doc_changed", %{"path" => path, "text" => text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      dirty = Buffer.dirty?(Buffer.update(path, text))

      {:halt,
       socket |> change(&Workbench.set_dirty(&1, path, dirty)) |> Json.validate_json(path, text)}
    else
      {:halt, socket}
    end
  end

  # Format on save: the file's formatter (an extension's) goes first, and
  # the file is saved when it answered – or didn't in time.
  def handle_event("save", %{"path" => path, "text" => text}, socket) do
    if Workbench.open?(workbench(socket), path) and
         Formatting.file_settings(socket, path)["editor.formatOnSave"] == true and
         Formatting.formatter?(socket, path, "formatting") do
      Buffer.update(path, text)
      {:halt, Formatting.format(socket, path, :document, true)}
    else
      {:halt, save_file(socket, path, text)}
    end
  end

  def handle_event("open_problem", %{"path" => path}, socket),
    do: {:halt, change(socket, &Workbench.open_editor(&1, path))}

  # Undo/redo availability of the active editor (enables the undo/redo commands).
  def handle_event("history_changed", %{"canUndo" => can_undo, "canRedo" => can_redo}, socket),
    do: {:halt, change(socket, &Workbench.set_history(&1, can_undo == true, can_redo == true))}

  # Selections of the active editor, UTF-8 byte offsets (for plugin commands).
  def handle_event("selection_changed", %{"path" => path, "ranges" => ranges}, socket) do
    ranges = for [from, to] <- ranges, is_integer(from), is_integer(to), do: {from, to}
    socket = assign(socket, selection: {path, ranges})
    if path == socket.assigns.active, do: tell_extension_host(socket)
    {:halt, socket}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  def handle_info({:open_file, rel}, socket) do
    case Workspace.resolve(socket.assigns.root, rel) do
      # A click in the Explorer: a preview, as in VS Code.
      {:ok, abs} ->
        {:halt, change(socket, &Workbench.open_editor(&1, abs, preview: preview?(socket)))}

      {:error, _} ->
        {:halt, Notifications.notify(socket, :error, "Path outside workspace")}
    end
  end

  # The Explorer created or renamed a file (see FileTree).
  def handle_info({:explorer_changed, request, path}, socket) do
    case request do
      %{kind: :new_file} -> {:halt, change(socket, &Workbench.open_editor(&1, path))}
      %{kind: :rename, path: from} -> {:halt, files_moved(socket, [{from, path}])}
      _ -> {:halt, socket}
    end
  end

  def handle_info({:fs_changed, path}, socket) do
    send_update(BeeWeb.Workbench.FileTree, id: "explorer", fs_changed: path)
    {:halt, socket}
  end

  def handle_info({:buffer_edited, path, _version, edits, text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      edits = for {from, to, insert} <- edits, do: [from, to, insert]

      {:halt,
       socket
       |> push_event("cm:edit", %{path: path, edits: edits, text: text})
       |> Json.validate_json(path, text)}
    else
      {:halt, socket}
    end
  end

  def handle_info({:buffer_reloaded, path, text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      {:halt,
       socket
       |> change(&Workbench.set_dirty(&1, path, false))
       |> push_event("cm:reload", %{path: path, text: text})
       |> Json.validate_json(path, text)}
    else
      {:halt, socket}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  # Opens `path` in a new tab. `text`: unsaved text to carry over (a file
  # that was moved with unsaved changes).
  # `preview?`: in the tab that the next previewed file reuses.
  def open_buffer(socket, path, text \\ nil, preview? \\ false) do
    with {:ok, buffer} <- Buffer.open(path) do
      buffer = if text, do: Buffer.update(path, text), else: buffer
      RecentFiles.add(socket.assigns.root, path)
      lang = Languages.detect(path, first_line: Languages.first_line(buffer.text))

      socket
      |> change(&Workbench.editor_opened(&1, path, Buffer.dirty?(buffer), lang, preview?))
      |> push_event(
        "cm:open",
        Map.merge(
          %{path: path, text: buffer.text, lang: lang, group: socket.assigns.group},
          highlight(lang)
        )
      )
      |> Json.validate_json(path, buffer.text)
      |> LanguageFeatures.push_language_diagnostics(path)
      |> LanguageFeatures.push_language_features(path)
    else
      {:error, reason} ->
        message = "Cannot open #{display_path(socket.assigns.root, path)}: #{inspect(reason)}"
        Notifications.notify(socket, :error, message)
    end
  end

  # Bee changed files: the tree shows them now, not when the watcher tells.
  def files_changed(socket) do
    send_update(BeeWeb.Workbench.FileTree, id: "explorer", refresh: true)
    socket
  end

  # Tabs of moved files (or files in moved folders) follow them, unsaved
  # changes included; the active one stays active.
  def files_moved(socket, pairs) do
    Enum.reduce(pairs, socket, fn {from, to}, socket ->
      moved =
        for %{path: path} = tab <- open_tabs(socket), under?(path, from) do
          {tab, to <> String.replace_prefix(path, from, "")}
        end

      Enum.reduce(moved, socket, &file_moved/2)
    end)
  end

  # In every group that showed it.
  defp file_moved({tab, new_path}, socket) do
    wb = workbench(socket)
    focused = wb.group
    text = if tab.dirty, do: Buffer.get(tab.path).text

    holders =
      for group <- Workbench.groups(wb), Enum.any?(group.tabs, &(&1.path == tab.path)) do
        {group.id, group.active}
      end

    socket = change(socket, &Workbench.close_everywhere(&1, tab.path))

    holders
    |> Enum.reduce(socket, fn {group, active}, socket ->
      # (A group whose only editor it was went with it: the focused one, then.)
      socket
      |> change(&Workbench.focus_group(&1, group))
      |> open_buffer(new_path, text)
      |> then(
        &if(active not in [tab.path, nil],
          do: change(&1, fn wb -> Workbench.activate_editor(wb, active) end),
          else: &1
        )
      )
    end)
    |> change(&Workbench.focus_group(&1, focused))
  end

  # Tabs of deleted files close (their buffers had nothing left to save to).
  def files_deleted(socket, path) do
    socket
    |> open_tabs()
    |> Enum.filter(&under?(&1.path, path))
    |> Enum.reduce(socket, fn tab, socket ->
      change(socket, &Workbench.close_everywhere(&1, tab.path))
    end)
  end

  defp under?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  # How the editor highlights `lang` – a CodeMirror `mode` or a TextMate
  # `scope` – its language configuration (`config`, or nil) and snippets.
  defp highlight(lang),
    do:
      %{
        mode: nil,
        scope: nil,
        config: Languages.configuration(lang),
        snippets: Bee.Snippets.editor_snippets(lang),
        json: Bee.JSONValidation.language?(lang)
      }
      |> Map.merge(Languages.highlight(lang))

  # Language contributions or files.associations changed: re-detect open tabs.
  def redetect_languages(socket) do
    Enum.reduce(open_tabs(socket), socket, fn
      %{kind: :file, path: path, lang: old}, socket ->
        text =
          try do
            Buffer.get(path).text
          catch
            :exit, _ -> ""
          end

        # Its highlighting may have changed too (a grammar was added): the
        # editor ignores a cm:language that changes nothing.
        lang = Languages.detect(path, first_line: Languages.first_line(text))

        socket =
          if lang == old,
            do: socket,
            else: change(socket, &Workbench.set_language(&1, path, lang))

        push_event(socket, "cm:language", Map.merge(%{path: path, lang: lang}, highlight(lang)))

      _other, socket ->
        socket
    end)
  end

  def save_file(socket, path, text) do
    with true <- Workbench.open?(workbench(socket), path),
         {:ok, _buffer} <- Buffer.save(path, text) do
      # Apply right away, also when file watching is unavailable.
      if path in [Settings.user_path(), Settings.workspace_path(socket.assigns.root)],
        do: Settings.reload()

      if path == Keybindings.user_path(), do: Keybindings.reload()

      change(socket, fn wb ->
        wb
        |> Workbench.set_dirty(path, false)
        |> Workbench.set_status("Saved #{display_path(wb.root, path)}")
      end)
    else
      false ->
        socket

      {:error, reason} ->
        message = "Could not save #{display_path(socket.assigns.root, path)}: #{inspect(reason)}"
        Notifications.notify(socket, :error, message)
    end
  end
end

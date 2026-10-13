defmodule BeeWeb.EditorLive.Editors do
  @moduledoc """
  The editors: tabs and groups, and the files they show.

  Text lives in CodeMirror (the `CodeEditor` hook) and in a
  `Bee.Editor.Buffer` per file: the editor's changes come as `doc_changed`
  and `save`, the buffer's (plugins' edits, reloads) go back as `cm:edit`
  and `cm:reload`. Tabs follow their files when Bee moves or deletes them.

  The two agree on the text by its version (`Bee.Editor.Buffer`): the
  editor sends what was typed (`changes`, of version `base`) and is told
  the new version – or `resync`, when the buffer has another text, and
  then sends its whole `text`, which always wins.
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

  # How often the Explorer follows files changing on disk.
  @fs_ms 100

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

  # What was typed, in version `base` of the text.
  def handle_event(
        "doc_changed",
        %{"path" => path, "base" => base, "changes" => changes},
        socket
      ) do
    with true <- Workbench.open?(workbench(socket), path),
         {:ok, buffer} <- Buffer.change(path, base, changes) do
      {:halt, %{version: buffer.version}, text_changed(socket, buffer)}
    else
      _ -> {:halt, %{resync: true}, socket}
    end
  end

  # The editor's whole text.
  def handle_event("doc_changed", %{"path" => path, "text" => text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      buffer = Buffer.update(path, text)
      {:halt, %{version: Buffer.sync_version(buffer)}, text_changed(socket, buffer)}
    else
      {:halt, %{}, socket}
    end
  end

  # Save: the buffer's text when it is the editor's (version `base`), else
  # the editor's whole `text`.
  def handle_event("save", %{"path" => path} = params, socket) do
    with true <- Workbench.open?(workbench(socket), path),
         {:ok, buffer} <- saved_text(path, params) do
      {:halt, %{version: Buffer.sync_version(buffer)}, save(socket, path, buffer.text)}
    else
      _ -> {:halt, %{resync: true}, socket}
    end
  end

  def handle_event("open_problem", %{"path" => path}, socket),
    do: {:halt, change(socket, &Workbench.open_editor(&1, path))}

  # Undo/redo availability of the active editor (enables the undo/redo commands).
  def handle_event("history_changed", %{"canUndo" => can_undo, "canRedo" => can_redo}, socket),
    do: {:halt, change(socket, &Workbench.set_history(&1, can_undo == true, can_redo == true))}

  # Selections of the active editor, as positions (`Bee.Editor.Positions`):
  # for extensions as they are, for plugin commands as byte offsets when
  # one runs (`BeeWeb.EditorLive.Window.plugin_context/1`).
  def handle_event("selection_changed", %{"path" => path, "ranges" => ranges}, socket) do
    position? = &match?(%{"line" => l, "character" => c} when is_integer(l) and is_integer(c), &1)
    ranges = for [from, to] <- ranges, position?.(from), position?.(to), do: {from, to}
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

  # A file changed on disk: the Explorer lists its folder again – at once,
  # and then at most every @fs_ms while changes keep coming (a build, a
  # log), each folder once.
  def handle_info({:fs_changed, path}, socket) do
    socket = media_changed(socket, path)
    dir = Path.dirname(path)

    case socket.private[:fs_dirs] do
      nil ->
        send_update(BeeWeb.Workbench.FileTree, id: "explorer", fs_changed: [dir])
        Process.send_after(self(), :fs_changed_dirs, @fs_ms)
        {:halt, put_private(socket, :fs_dirs, MapSet.new())}

      dirs ->
        {:halt, put_private(socket, :fs_dirs, MapSet.put(dirs, dir))}
    end
  end

  def handle_info(:fs_changed_dirs, socket) do
    dirs = socket.private[:fs_dirs]

    if MapSet.size(dirs) == 0 do
      {:halt, put_private(socket, :fs_dirs, nil)}
    else
      send_update(BeeWeb.Workbench.FileTree, id: "explorer", fs_changed: MapSet.to_list(dirs))
      Process.send_after(self(), :fs_changed_dirs, @fs_ms)
      {:halt, put_private(socket, :fs_dirs, MapSet.new())}
    end
  end

  # Edits made here: for the editor that has the version they were made
  # of (`base`); another one sends its text instead.
  def handle_info({:buffer_edited, path, version, edits, text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      edits = for {from, to, insert} <- edits, do: [from, to, insert]

      {:halt,
       socket
       |> change(&Workbench.set_dirty(&1, path, dirty?(path)))
       |> push_event("cm:edit", %{
         path: path,
         edits: edits,
         base: version - 1,
         version: sync_version(version, text)
       })
       |> Json.validate_json(path, text)}
    else
      {:halt, socket}
    end
  end

  def handle_info({:buffer_reloaded, path, version, text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      {:halt,
       socket
       |> change(&Workbench.set_dirty(&1, path, false))
       |> push_event("cm:reload", %{path: path, text: text, version: sync_version(version, text)})
       |> Json.validate_json(path, text)}
    else
      {:halt, socket}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  # Whether the open file `path` has unsaved changes.
  defp dirty?(path) do
    Buffer.dirty?(Buffer.get(path))
  catch
    :exit, _ -> false
  end

  defp sync_version(version, text),
    do: Buffer.sync_version(%Buffer{version: version, text: text})

  # The buffer's text changed with the editor's: its tab, its problems.
  defp text_changed(socket, buffer) do
    dirty = Buffer.dirty?(buffer)

    socket
    |> change(&Workbench.set_dirty(&1, buffer.path, dirty))
    |> Json.validate_json(buffer.path, buffer.text)
  end

  defp saved_text(path, %{"text" => text}) when is_binary(text),
    do: {:ok, Buffer.update(path, text)}

  defp saved_text(path, %{"base" => base}) do
    case Buffer.get(path) do
      %{version: ^base} = buffer -> {:ok, buffer}
      _ -> :stale
    end
  end

  # Format on save: the file's formatter (an extension's) goes first, and
  # the file is saved when it answered – or didn't in time.
  defp save(socket, path, text) do
    if Formatting.file_settings(socket, path)["editor.formatOnSave"] == true and
         Formatting.formatter?(socket, path, "formatting"),
       do: Formatting.format(socket, path, :document, true),
       else: save_file(socket, path, text)
  end

  # Opens `path` in a new tab. `text`: unsaved text to carry over (a file
  # that was moved with unsaved changes).
  # `preview?`: in the tab that the next previewed file reuses.
  #
  # As VS Code does, not every file is opened as text: an image, audio or
  # video is shown or played (`Bee.CustomEditors`), a very large file
  # (`workbench.editorLargeFileConfirmation`) or another binary one
  # (`Bee.Editor.Buffer`) only said to be so. `editor` asks for one way: the
  # text editor (`"default"`: Open Anyway, Open With…), or a `viewType` –
  # also a plugin's editor, whose LiveView then draws the file.
  # Without it a file open already opens the same way again.
  def open_buffer(socket, path, text \\ nil, preview? \\ false, editor \\ nil) do
    text_editor = Bee.CustomEditors.text()
    settings = socket.assigns.settings
    tabs = Enum.filter(Workbench.all_tabs(workbench(socket)), &(&1.path == path))

    editor =
      cond do
        editor != nil -> editor
        text != nil or Enum.any?(tabs, &(&1.kind == :file)) -> text_editor
        open = Enum.find(tabs, &(&1.kind in [:media, :custom])) -> open.view_type
        true -> Bee.CustomEditors.for_file(path, settings["workbench.editorAssociations"])
      end

    as_text? = editor == text_editor

    with true <- as_text? or editor == nil,
         :ok <- if(as_text?, do: :ok, else: small_enough(path, settings)),
         {:ok, buffer} <- Buffer.open(path, self(), binary: as_text?) do
      buffer = if text, do: Buffer.update(path, text), else: buffer
      RecentFiles.add(socket.assigns.root, path)
      lang = Languages.detect(path, first_line: Languages.first_line(buffer.text))

      socket
      |> change(&Workbench.editor_opened(&1, path, Buffer.dirty?(buffer), lang, preview?))
      |> push_event(
        "cm:open",
        Map.merge(
          %{
            path: path,
            text: buffer.text,
            version: Buffer.sync_version(buffer),
            lang: lang,
            group: socket.assigns.group
          },
          highlight(lang)
        )
      )
      |> Json.validate_json(path, buffer.text)
      |> LanguageFeatures.push_language_diagnostics(path)
      |> LanguageFeatures.push_language_features(path)
    else
      false ->
        case {Bee.CustomEditors.viewer(editor), Bee.CustomEditors.live_editor(editor)} do
          {nil, nil} ->
            case Bee.CustomEditors.extension_editor(editor) do
              nil -> cannot_open(socket, path, "there is no editor #{editor}")
              %{plugin: plugin} -> open_extension_editor(socket, path, editor, plugin, preview?)
            end

          # A plugin's: its LiveView draws the file (its code must run).
          {nil, %{plugin: plugin}} ->
            Bee.Plugins.activate(plugin, socket.assigns.root)
            tab = %{kind: :custom, view_type: editor, plugin: plugin}
            open_viewer(socket, path, tab, preview?)

          {media, _} ->
            tab = %{
              kind: :media,
              view_type: editor,
              media: media,
              src: BeeWeb.MediaController.url(path)
            }

            open_viewer(socket, path, tab, preview?)
        end

      :large ->
        open_viewer(socket, path, %{kind: :binary, reason: :large}, preview?)

      {:error, :binary_file} ->
        open_viewer(socket, path, %{kind: :binary, reason: :binary}, preview?)

      {:error, reason} ->
        cannot_open(socket, path, inspect(reason))
    end
  end

  # Whether the file is one to open as text without asking: `:ok`, or
  # `:large` (workbench.editorLargeFileConfirmation, in MB).
  defp small_enough(path, settings) do
    limit = settings["workbench.editorLargeFileConfirmation"]

    case File.stat(path) do
      {:ok, %{size: size}} when is_number(limit) and size > limit * 1024 * 1024 -> :large
      _ -> :ok
    end
  end

  # A file in a custom editor of a VS Code extension: a tab whose page is a
  # webview panel the extension's provider draws (`Bee.Webviews`; the id
  # is made here). The file has that editor once in the window: open
  # already, it is shown. A text file is open as text too – its buffer is
  # what the provider reads and edits, and what Save writes.
  defp open_extension_editor(socket, path, view_type, plugin, preview?) do
    wb = workbench(socket)
    mine? = &(&1.path == path and &1.kind == :custom and &1[:webview] != nil)

    case Enum.find(Workbench.groups(wb), fn group -> Enum.any?(group.tabs, mine?) end) do
      %{id: group} ->
        change(socket, &Workbench.activate_editor(&1, group, path))

      nil ->
        root = socket.assigns.root
        id = "custom-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        Bee.Plugins.activate(plugin, root)

        buffer =
          with :ok <- small_enough(path, socket.assigns.settings),
               {:ok, buffer} <- Buffer.open(path) do
            buffer
          else
            _ -> nil
          end

        tab = %{
          kind: :custom,
          view_type: view_type,
          plugin: plugin,
          webview: id,
          dirty: buffer != nil and Buffer.dirty?(buffer)
        }

        socket = open_viewer(socket, path, tab, preview?)

        cond do
          not Enum.any?(open_tabs(socket), &(&1[:webview] == id)) ->
            if buffer && not Workbench.open?(workbench(socket), path), do: Buffer.close(path)
            socket

          Bee.Extensions.Host.resolve_custom_editor(root, id, view_type, path) == :error ->
            Notifications.notify(
              socket,
              :error,
              "#{plugin} isn't running: it can't show the file"
            )

          true ->
            socket
        end
    end
  end

  # A file that isn't shown as text: `tab` says as what (`Bee.Workbench`).
  defp open_viewer(socket, path, tab, preview?) do
    case file_info(path) do
      {:ok, info} ->
        RecentFiles.add(socket.assigns.root, path)
        tab = tab |> Map.merge(info) |> Map.put(:path, path)
        change(socket, &Workbench.viewer_opened(&1, tab, preview?))

      {:error, reason} ->
        cannot_open(socket, path, inspect(reason))
    end
  end

  defp cannot_open(socket, path, reason) do
    message = "Cannot open #{display_path(socket.assigns.root, path)}: #{reason}"
    Notifications.notify(socket, :error, message)
  end

  # What an editor shows of a file besides its content: its `size`, and a
  # `version` that is another one once the file has changed.
  defp file_info(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        {:ok, %{size: size, version: :erlang.phash2({mtime, size})}}

      {:ok, _other} ->
        {:error, :eisdir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An image (audio, video) shown changed on disk: shown as it is now.
  defp media_changed(socket, path) do
    with %{} = tab <-
           Enum.find(
             Workbench.all_tabs(workbench(socket)),
             &(&1.path == path and &1.kind == :media)
           ),
         {:ok, info} when info != %{size: tab.size, version: tab.version} <- file_info(path) do
      change(socket, &Workbench.set_file_info(&1, path, info))
    else
      _ -> socket
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

      # (Shown as an image in another group: as saved, at once.)
      socket
      |> media_changed(path)
      |> change(fn wb ->
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

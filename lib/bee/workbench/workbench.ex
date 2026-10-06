defmodule Bee.Workbench do
  @moduledoc """
  The state of one editor window – open editors, panel, terminals, menus,
  palette – and the functions that change it.

  Functions return the new workbench, or `{workbench, effects}` when
  something has to happen outside the struct. The LiveView carries effects
  out (`BeeWeb.EditorLive.run_effects/2`):

    * `{:push, event, payload}` – event to the browser (CodeMirror etc.)
    * `{:open_file, path}` – open a `Bee.Editor.Buffer`, then `editor_opened/3`
    * `{:close_buffer, path}` – detach from the file's `Bee.Editor.Buffer`
    * `:new_terminal` – start a `Bee.Terminal`, then `terminal_started/3`
    * `{:stop_terminal, id}` – stop it (`{:forget_terminal, id}` when it already exited)
    * `:panel_hidden` – the terminals' xterm views were unmounted
    * `{:exec_client, command}` – run a client-side command in the browser
    * `{:run_plugin_command, command}` – run a plugin's server command
    * `:reload_plugins`
    * `{:set_plugin_enabled, name, enabled?}` – see `Bee.Plugins.set_enabled/2`
    * `{:update_setting, key, value}` – write it to the user settings file
    * `{:uninstall_plugin, name}` – see `Bee.Plugins.uninstall/1`
    * `{:open_folder, path, :this_window | :new_window}` – another workspace
    * `{:pick_folder, "same" | "new", title}` – the desktop app's folder
      dialog, its pick running `bee.openFolder`
    * `{:flash, kind, message}`
    * `{:explorer_edit, edit}` – an input in the Explorer's tree: a new
      file's or folder's name in `dir`, or a new name for `path`
    * `{:delete_file, path}`, `{:paste_files, op, paths, dir}` – see
      `Bee.Workspace.Files`
    * search effects, see `Bee.Workbench.Search`

  Commands (`Bee.Workbench.Actions`) are built from these functions.
  """

  defstruct root: nil,
            tabs: [],
            active: nil,
            status: nil,
            sidebar_open: true,
            sidebar_view: "explorer",
            sidebar_width: 256,
            panel_height: 288,
            activity_order: [],
            panel_open: false,
            terminals: [],
            active_term: nil,
            open_menu: nil,
            context_menu: nil,
            clipboard: nil,
            palette: nil,
            can_undo: false,
            can_redo: false,
            search: nil

  @type tab :: %{path: String.t(), dirty: boolean(), lang: String.t()}
  @type terminal :: %{id: integer(), name: String.t()}
  @type effect :: tuple() | atom()
  @type t :: %__MODULE__{}

  @fields [
    :tabs,
    :active,
    :status,
    :sidebar_open,
    :sidebar_view,
    :activity_order,
    :sidebar_width,
    :panel_height,
    :panel_open,
    :terminals,
    :active_term,
    :open_menu,
    :context_menu,
    :clipboard,
    :palette,
    :can_undo,
    :can_redo,
    :search,
    :root
  ]

  @doc "The struct's fields (the LiveView keeps them as individual assigns)."
  def fields, do: @fields

  def new(root), do: %__MODULE__{root: root, search: Bee.Workbench.Search.new()}

  @doc "Normalizes a handler result to `{workbench, effects}`."
  def wrap({%__MODULE__{} = wb, effects}) when is_list(effects), do: {wb, effects}
  def wrap(%__MODULE__{} = wb), do: {wb, []}

  @doc "Runs `fun` on the workbench of `{wb, effects}`, collecting its effects."
  def chain({wb, effects}, fun) do
    {wb, more} = wrap(fun.(wb))
    {wb, effects ++ more}
  end

  ## Editors

  def open?(wb, path), do: Enum.any?(wb.tabs, &(&1.path == path))

  @doc "Shows `path`: activates its tab, or asks for the file to be opened."
  def open_editor(wb, path) do
    if open?(wb, path), do: activate_editor(wb, path), else: {wb, [{:open_file, path}]}
  end

  @doc "Called once the buffer for `path` is open; `lang` is its language id."
  def editor_opened(wb, path, dirty, lang) do
    %{wb | tabs: wb.tabs ++ [%{path: path, dirty: dirty, lang: lang}], active: path}
  end

  def language(wb, path), do: Enum.find_value(wb.tabs, &(&1.path == path && &1.lang))

  def activate_editor(wb, path) do
    if open?(wb, path) do
      {%{wb | active: path}, [{:push, "cm:activate", %{path: path}}]}
    else
      wb
    end
  end

  def close_editor(wb, path) do
    case Enum.find_index(wb.tabs, &(&1.path == path)) do
      nil ->
        wb

      index ->
        remaining = List.delete_at(wb.tabs, index)
        effects = [{:close_buffer, path}, {:push, "cm:close", %{path: path}}]
        wb = %{wb | tabs: remaining}

        cond do
          wb.active != path ->
            {wb, effects}

          remaining == [] ->
            {%{wb | active: nil}, effects}

          true ->
            neighbour = Enum.at(remaining, min(index, length(remaining) - 1)).path
            chain({wb, effects}, &activate_editor(&1, neighbour))
        end
    end
  end

  def set_dirty(wb, path, dirty), do: update_tab(wb, path, &%{&1 | dirty: dirty})

  def set_language(wb, path, lang), do: update_tab(wb, path, &%{&1 | lang: lang})

  @doc "Whether the active editor has something to undo / redo (reported by the browser)."
  def set_history(wb, can_undo, can_redo), do: %{wb | can_undo: can_undo, can_redo: can_redo}

  defp update_tab(wb, path, fun) do
    %{wb | tabs: Enum.map(wb.tabs, &if(&1.path == path, do: fun.(&1), else: &1))}
  end

  ## Layout

  def toggle_sidebar(wb), do: %{wb | sidebar_open: not wb.sidebar_open}

  @doc """
  Shows sidebar view `view` ("explorer", "extensions" – the plugins); like clicking its
  activity bar icon in VS Code, this hides the sidebar when it is already shown.
  """
  def show_view(%{sidebar_open: true, sidebar_view: view} = wb, view),
    do: %{wb | sidebar_open: false}

  def show_view(wb, view), do: reveal_view(wb, view)

  # Sizes in CSS pixels: {default, min, max}.
  @sizes %{sidebar: {256, 170, 800}, panel: {288, 80, 1200}}

  @doc """
  Sets the sidebar width or panel height (dragging their sash), clamped to
  sensible bounds; `nil` restores the default (double-clicking the sash).
  """
  def resize(wb, part, size) when is_map_key(@sizes, part) do
    {default, min, max} = @sizes[part]
    size = if is_number(size), do: size |> round() |> max(min) |> min(max), else: default

    case part do
      :sidebar -> %{wb | sidebar_width: size}
      :panel -> %{wb | panel_height: size}
    end
  end

  @doc """
  Remembers the order of the activity bar's icons (views container ids),
  as the user dragged them. Non-strings are dropped.
  """
  def reorder_activity(wb, order) when is_list(order),
    do: %{wb | activity_order: order |> Enum.filter(&is_binary/1) |> Enum.uniq()}

  @doc """
  Sorts views containers by an `activity_order`; those it doesn't name (a
  plugin's, installed since) keep their order, after the others.
  """
  def sort_activity(containers, order) do
    index = order |> Enum.with_index() |> Map.new()

    containers
    |> Enum.with_index()
    |> Enum.sort_by(fn {c, i} -> {Map.get(index, c.id, length(order)), i} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Shows sidebar view `view`, also when it is already shown."
  def reveal_view(wb, view), do: %{wb | sidebar_open: true, sidebar_view: view}

  @doc """
  Closing the panel keeps the shells running (their views re-attach on
  reopen); opening an empty panel starts a shell.
  """
  def toggle_panel(%{panel_open: true} = wb), do: {%{wb | panel_open: false}, [:panel_hidden]}
  def toggle_panel(%{terminals: []} = wb), do: {wb, [:new_terminal]}
  def toggle_panel(wb), do: %{wb | panel_open: true}

  ## Terminals

  def terminal?(wb, id), do: Enum.any?(wb.terminals, &(&1.id == id))

  @doc "Called once a `Bee.Terminal` with `id` is running."
  def terminal_started(wb, id, name) do
    %{wb | terminals: wb.terminals ++ [%{id: id, name: name}], active_term: id, panel_open: true}
  end

  def activate_terminal(wb, id) do
    if terminal?(wb, id), do: %{wb | active_term: id}, else: wb
  end

  def kill_terminal(wb, id) do
    if terminal?(wb, id), do: {remove_terminal(wb, id), [{:stop_terminal, id}]}, else: wb
  end

  @doc "The shell exited on its own."
  def terminal_exited(wb, id) do
    if terminal?(wb, id), do: {remove_terminal(wb, id), [{:forget_terminal, id}]}, else: wb
  end

  defp remove_terminal(wb, id) do
    terminals = Enum.reject(wb.terminals, &(&1.id == id))

    active =
      cond do
        wb.active_term != id -> wb.active_term
        terminals == [] -> nil
        true -> List.last(terminals).id
      end

    %{wb | terminals: terminals, active_term: active}
  end

  ## Menus and palette

  @doc """
  Opens context menu `menu` (e.g. `"explorer/context"`) at `x`, `y` (px).
  Its commands get `args`; `context` adds `when` keys for its items (e.g.
  `explorerResourceIsFolder`). Both come from the element right-clicked.
  """
  def open_context_menu(wb, menu, x, y, args, context) do
    %{
      wb
      | context_menu: %{menu: menu, x: x, y: y, args: args, context: context},
        open_menu: nil
    }
  end

  def close_context_menu(wb), do: %{wb | context_menu: nil}

  @doc "The Explorer's cut or copied files (`op` `:cut` or `:copy`), for pasting."
  def set_clipboard(wb, op, paths) when op in [:cut, :copy],
    do: %{wb | clipboard: %{op: op, paths: paths}}

  def clear_clipboard(wb), do: %{wb | clipboard: nil}

  def toggle_menu(wb, menu), do: %{wb | open_menu: if(wb.open_menu == menu, do: nil, else: menu)}
  def close_menu(wb), do: %{wb | open_menu: nil}

  @doc """
  Opens the title bar's quick input. Modes (VS Code's quick input):

    * `:commands` – the command palette
    * `:pick` – choose one of `items` (`%{label, description, value}`); the
      choice runs `command` with `arguments ++ [value]`
    * `:input` – type a line; Enter runs `command` with `arguments ++ [text]`
  """
  def open_palette(wb),
    do: %{wb | palette: %{mode: :commands, query: "", index: 0}, open_menu: nil}

  def open_quick_pick(wb, %{items: items, command: command} = spec) do
    palette = %{
      mode: :pick,
      query: "",
      index: 0,
      items: items,
      command: command,
      arguments: Map.get(spec, :arguments, []),
      placeholder: Map.get(spec, :placeholder, "")
    }

    %{wb | palette: palette, open_menu: nil}
  end

  def open_input_box(wb, %{command: command} = spec) do
    palette = %{
      mode: :input,
      query: Map.get(spec, :value, ""),
      index: 0,
      command: command,
      arguments: Map.get(spec, :arguments, []),
      prompt: Map.get(spec, :prompt, ""),
      placeholder: Map.get(spec, :placeholder, "")
    }

    %{wb | palette: palette, open_menu: nil}
  end

  def close_palette(wb), do: %{wb | palette: nil}

  def filter_palette(%{palette: %{} = palette} = wb, query),
    do: %{wb | palette: %{palette | query: query, index: 0}}

  def filter_palette(wb, _query), do: wb

  @doc "Moves the palette selection by `delta`, within `count` items."
  def move_palette(%{palette: %{index: index} = p} = wb, delta, count) do
    %{wb | palette: %{p | index: index |> Kernel.+(delta) |> min(count - 1) |> max(0)}}
  end

  def move_palette(wb, _delta, _count), do: wb

  def set_status(wb, status), do: %{wb | status: status}

  ## `when` context

  @doc """
  The server half of the `when` context (VS Code context keys where they
  exist). `settings` adds `config.*`. The browser adds focus keys.
  """
  def context(wb, settings \\ %{}) do
    active = wb.active

    settings
    |> Map.new(fn {key, value} -> {"config." <> key, value} end)
    |> Map.merge(%{
      "activeEditor" => active && Bee.Workspace.FS.relative(wb.root, active),
      "activeEditorIsDirty" => Enum.any?(wb.tabs, &(&1.path == active and &1.dirty)),
      "resourceFilename" => active && Path.basename(active),
      "resourceExtname" => active && Path.extname(active),
      "resourcePath" => active,
      "editorLangId" => active && language(wb, active),
      "editorIsOpen" => wb.tabs != [],
      "canUndo" => active != nil and wb.can_undo,
      "canRedo" => active != nil and wb.can_redo,
      "sideBarVisible" => wb.sidebar_open,
      "activeViewlet" => wb.sidebar_open && "workbench.view.#{wb.sidebar_view}",
      "panelVisible" => wb.panel_open,
      "terminalCount" => length(wb.terminals),
      "searchHasQuery" => wb.search != nil and String.trim(wb.search.query) != "",
      "hasSearchResult" => wb.search != nil and wb.search.results != %{},
      "searchCaseSensitive" => wb.search != nil and wb.search.case_sensitive,
      "searchWholeWord" => wb.search != nil and wb.search.whole_word,
      "searchRegex" => wb.search != nil and wb.search.regex,
      "inQuickOpen" => wb.palette != nil,
      "menuOpen" => wb.open_menu != nil,
      "explorerCanPaste" => wb.clipboard != nil
    })
  end
end

defmodule Bee.Workbench do
  @moduledoc """
  The state of one editor window – open editors, panel, terminals, menus,
  palette – and the functions that change it.

  Functions return the new workbench, or `{workbench, effects}` when
  something has to happen outside the struct. The LiveView carries effects
  out (`BeeWeb.EditorLive.Effects.run_effects/2`):

    * `{:push, event, payload}` – event to the browser (CodeMirror etc.)
    * `{:open_file, path}`, `{:open_file, path, :preview}` – open a
      `Bee.Editor.Buffer`, then `editor_opened/5`
    * `{:close_buffer, path}` – detach from the file's `Bee.Editor.Buffer`
    * `:new_terminal` – start a `Bee.Terminal`, then `terminal_started/3`
    * `:start_console` – start the window's `Bee.Console`, then `console_started/2`
    * `{:stop_terminal, id}` – stop it (`{:forget_terminal, id}` when it already exited)
    * `:clear_output` – empty the Output section's channel (`Bee.Output`)
    * `:panel_hidden` – the panel's xterm views (terminals, console) were unmounted
    * `{:panel_shown, id}` – panel section `id` is shown (a plugin's starts)
    * `{:exec_client, command}` – run a client-side command in the browser
    * `{:run_plugin_command, command}` – run a plugin's server command
    * `{:run_extension_command, command, args}` – run a command of a VS
      Code extension's code (`Bee.Extensions.Host`)
    * `:reload_plugins`
    * `{:set_plugin_enabled, name, enabled?}` – see `Bee.Plugins.set_enabled/2`
    * `{:update_setting, key, value}` – write it to the user settings file
    * `{:uninstall_plugin, name}` – see `Bee.Plugins.uninstall/1`
    * `{:open_folder, path, :this_window | :new_window}` – another workspace
    * `{:pick_folder, "same" | "new", title}` – the desktop app's folder
      dialog, its pick running `bee.openFolder`
    * `{:notify, severity, message}` – tell the user (a notification)
    * `{:explorer_edit, edit}` – an input in the Explorer's tree: a new
      file's or folder's name in `dir`, or a new name for `path`
    * `{:delete_file, path}`, `{:paste_files, op, paths, dir}` – see
      `Bee.Workspace.Files`
    * search effects, see `Bee.Workbench.Search`
    * Open VSX effects (searching, installing), see `Bee.Workbench.Marketplace`

  Commands (`Bee.Workbench.Actions`) are built from these functions.
  """

  defstruct root: nil,
            # The focused editor group's editors, and the one shown in it.
            tabs: [],
            active: nil,
            # Editor groups (the editor area split, as in VS Code): the
            # focused one's id, the others (`%{id, tabs, active}`), how they
            # are laid out (`editor_layout`), and the next new one's id. See "Editor groups".
            group: 1,
            others: [],
            editor_layout: {:leaf, 1},
            next_group: 2,
            # Where the next file opened goes among the tabs: `{path, index}`.
            insert_at: nil,
            status: nil,
            sidebar_open: true,
            sidebar_view: "explorer",
            sidebar_width: 256,
            panel_height: 288,
            activity_order: [],
            panel_open: false,
            # The panel's section shown (a panel views container).
            panel_view: "terminal",
            # The sections' order, as dragged (container ids).
            panel_order: [],
            panel_maximized: false,
            # The window's Bee Console (its id, once started).
            console: nil,
            terminals: [],
            active_term: nil,
            open_menu: nil,
            context_menu: nil,
            clipboard: nil,
            palette: nil,
            can_undo: false,
            can_redo: false,
            search: nil,
            marketplace: nil

  @type tab :: %{path: String.t(), dirty: boolean(), lang: String.t()}
  @type terminal :: %{id: integer(), name: String.t()}
  @type effect :: tuple() | atom()
  @type t :: %__MODULE__{}

  @fields [
    :tabs,
    :active,
    :group,
    :others,
    :editor_layout,
    :next_group,
    :insert_at,
    :status,
    :sidebar_open,
    :sidebar_view,
    :activity_order,
    :sidebar_width,
    :panel_height,
    :panel_open,
    :panel_view,
    :panel_order,
    :panel_maximized,
    :console,
    :terminals,
    :active_term,
    :open_menu,
    :context_menu,
    :clipboard,
    :palette,
    :can_undo,
    :can_redo,
    :search,
    :marketplace,
    :root
  ]

  @doc "The struct's fields (the LiveView keeps them as individual assigns)."
  def fields, do: @fields

  def new(root),
    do: %__MODULE__{
      root: root,
      search: Bee.Workbench.Search.new(),
      marketplace: Bee.Workbench.Marketplace.new()
    }

  @doc "Normalizes a handler result to `{workbench, effects}`."
  def wrap({%__MODULE__{} = wb, effects}) when is_list(effects), do: {wb, effects}
  def wrap(%__MODULE__{} = wb), do: {wb, []}

  @doc "Runs `fun` on the workbench of `{wb, effects}`, collecting its effects."
  def chain({wb, effects}, fun) do
    {wb, more} = wrap(fun.(wb))
    {wb, effects ++ more}
  end

  ## Editors
  #
  # Each tab is an editor, `path` its id: a file (`kind: :file`, its
  # absolute path; CodeMirror shows it) or a plugin's details page
  # (`kind: :extension`, path "extension:<name>", like VS Code's extension
  # editor; see `BeeWeb.Workbench.ExtensionEditor`) or an editor a plugin
  # draws itself (`kind: :live`, path "live:<plugin>/<editor>[#<key>]", a
  # LiveView of its; see `BeeWeb.Workbench.PluginLive`), the settings page
  # (`kind: :settings`, path "settings:"), or a webview panel
  # of a VS Code extension (`kind: :webview`, path "webview:<id>", see
  # `Bee.Webviews`).

  @doc "Whether `path` has an editor, in any group."
  def open?(wb, path), do: Enum.any?(all_tabs(wb), &(&1.path == path))

  @doc "Whether `path` has an editor in the focused group."
  def here?(wb, path), do: Enum.any?(wb.tabs, &(&1.path == path))

  @doc "Whether a group other than the focused one has an editor of `path`."
  def elsewhere?(wb, path),
    do: Enum.any?(wb.others, fn group -> Enum.any?(group.tabs, &(&1.path == path)) end)

  @doc "The tab of `path` (the focused group's, else another group's), or nil."
  def tab(wb, path), do: Enum.find(all_tabs(wb), &(&1.path == path))

  @doc "The active editor's file, or nil (none, or not a file)."
  def active_file(wb) do
    case Enum.find(wb.tabs, &(&1.path == wb.active)) do
      %{kind: :file, path: path} -> path
      _ -> nil
    end
  end

  ## Editor groups
  #
  # The editor area can be split, as in VS Code: each group has its own
  # tabs and its own editor shown. `editor_layout` says where they are: a tree of
  # `{:row, [node]}` (side by side) and `{:col, [node]}` (one above the
  # other) with `{:leaf, group_id}` leaves. One group is focused: commands
  # act on it, and its tabs are `tabs` / `active` (the other groups are in
  # `others`), so that everything about "the editors" means the focused
  # group's unless it says otherwise. A file can be open in several groups
  # (the browser keeps their text the same); its buffer is closed with the
  # last of them. Editors that aren't files are open once.

  @doc "The groups, `[%{id, tabs, active}]`, in layout order."
  def groups(wb), do: wb.editor_layout |> leaves() |> Enum.map(&group(wb, &1))

  @doc "Group `id`, or nil."
  def group(%{group: id} = wb, id), do: %{id: id, tabs: wb.tabs, active: wb.active}
  def group(wb, id), do: Enum.find(wb.others, &(&1.id == id))

  @doc "Every group's tabs, the focused group's first."
  def all_tabs(wb), do: wb.tabs ++ Enum.flat_map(wb.others, & &1.tabs)

  @doc "Focuses group `id`: commands act on it, keys go to its editor."
  def focus_group(%{group: id} = wb, id), do: wb

  def focus_group(wb, id) do
    if group(wb, id), do: {swap(wb, id), [{:push, "cm:focus", %{group: id}}]}, else: wb
  end

  @doc """
  Splits the focused group: a new one to its right (`:right`) or below it
  (`:down`), focused, showing the same file. Nothing to split without a
  file shown.
  """
  def split(wb, direction) when direction in [:right, :down] do
    case active_file(wb) do
      nil ->
        wb

      path ->
        {wb, id} = add_group(wb, wb.group, direction)
        wb |> focus_group(id) |> wrap() |> chain(&{&1, [{:open_file, path}]})
    end
  end

  @doc """
  Moves the editor of `path` from group `from` to group `to` (a tab that
  was dragged), at `index` among its tabs (default: last). `zone` `:right`
  or `:down` puts it into a new group beside `to` instead. The group it
  leaves goes away when it was its last editor.
  """
  def move_tab(wb, path, from, to, index \\ nil, zone \\ :center) do
    source = group(wb, from)
    tab = source && Enum.find(source.tabs, &(&1.path == path))

    cond do
      tab == nil or group(wb, to) == nil ->
        wb

      zone == :center and from == to ->
        wb

      zone in [:right, :down] and from == to and length(source.tabs) == 1 ->
        wb

      zone in [:right, :down] ->
        {wb, id} = add_group(wb, to, zone)
        move(wb, tab, from, id, nil)

      true ->
        move(wb, tab, from, to, index)
    end
  end

  defp move(wb, tab, from, to, index) do
    wb
    |> in_group(from, &close_here(&1, tab.path, false))
    |> chain(&focus_group(&1, to))
    |> chain(fn wb ->
      cond do
        here?(wb, tab.path) ->
          activate_editor(wb, tab.path)

        tab.kind == :file ->
          {%{wb | insert_at: {tab.path, index}}, [{:open_file, tab.path}]}

        true ->
          activate_editor(%{wb | tabs: insert(wb.tabs, tab, index)}, tab.path)
      end
    end)
  end

  defp insert(tabs, tab, nil), do: tabs ++ [tab]
  defp insert(tabs, tab, index), do: List.insert_at(tabs, min(max(index, 0), length(tabs)), tab)

  # A new, empty group beside `beside`: `{wb, its id}`.
  defp add_group(wb, beside, direction) do
    id = wb.next_group

    {%{
       wb
       | others: wb.others ++ [%{id: id, tabs: [], active: nil}],
         editor_layout: layout_split(wb.editor_layout, beside, id, direction),
         next_group: id + 1
     }, id}
  end

  # The focused group is `id` now (no effects).
  defp swap(wb, id) do
    target = group(wb, id)
    here = %{id: wb.group, tabs: wb.tabs, active: wb.active}

    %{
      wb
      | group: id,
        tabs: target.tabs,
        active: target.active,
        others: Enum.map(wb.others, &if(&1.id == id, do: here, else: &1))
    }
  end

  # Runs `fun` with group `id` as the focused one, then focuses the group
  # that was (if it is still there): `{wb, effects}`.
  defp in_group(wb, id, fun) do
    focused = wb.group

    cond do
      id == focused ->
        wrap(fun.(wb))

      group(wb, id) == nil ->
        {wb, []}

      true ->
        {wb, effects} = wrap(fun.(swap(wb, id)))
        wb = if wb.group != focused and group(wb, focused), do: swap(wb, focused), else: wb
        # (What `fun` said about the focus isn't true any more.)
        effects = Enum.reject(effects, &match?({:push, "cm:focus", _}, &1))
        {wb, effects ++ [{:push, "cm:focus", %{group: wb.group}}]}
    end
  end

  # The focused group has no editors left: it goes, unless it is the only
  # one; the first of the others is focused.
  defp drop_group(%{others: []} = wb), do: wb

  defp drop_group(wb) do
    layout = layout_remove(wb.editor_layout, wb.group)
    next = group(wb, hd(leaves(layout)))

    {%{
       wb
       | editor_layout: layout,
         group: next.id,
         tabs: next.tabs,
         active: next.active,
         others: Enum.reject(wb.others, &(&1.id == next.id))
     }, [{:push, "cm:focus", %{group: next.id}}]}
  end

  defp leaves({:leaf, id}), do: [id]
  defp leaves({_axis, nodes}), do: Enum.flat_map(nodes, &leaves/1)

  defp axis(:right), do: :row
  defp axis(:down), do: :col

  # `new` beside leaf `target`: in its row (column) when that runs the
  # right way, else in a row (column) of the two in its place.
  defp layout_split({:leaf, target}, target, new, direction),
    do: {axis(direction), [{:leaf, target}, {:leaf, new}]}

  defp layout_split({:leaf, _} = leaf, _target, _new, _direction), do: leaf

  defp layout_split({axis, nodes}, target, new, direction) do
    if axis == axis(direction) and {:leaf, target} in nodes do
      {axis, Enum.flat_map(nodes, &if(&1 == {:leaf, target}, do: [&1, {:leaf, new}], else: [&1]))}
    else
      {axis, Enum.map(nodes, &layout_split(&1, target, new, direction))}
    end
  end

  defp layout_remove({:leaf, id}, id), do: nil
  defp layout_remove({:leaf, _} = leaf, _id), do: leaf

  defp layout_remove({axis, nodes}, id) do
    case nodes |> Enum.map(&layout_remove(&1, id)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      [only] -> only
      nodes -> {axis, nodes}
    end
  end

  # Shows the editor of `path` where it is: its group focused, its tab
  # activated.
  defp reveal(wb, path) do
    case Enum.find(groups(wb), fn group -> Enum.any?(group.tabs, &(&1.path == path)) end) do
      nil -> wb
      %{id: id} -> wb |> focus_group(id) |> wrap() |> chain(&activate_editor(&1, path))
    end
  end

  @doc "Shows plugin `name`'s details in an editor tab (VS Code's extension editor)."
  def open_extension(wb, name) do
    path = "extension:" <> name

    if open?(wb, path),
      do: reveal(wb, path),
      else:
        activate_editor(
          %{
            wb
            | tabs:
                wb.tabs ++ [%{path: path, kind: :extension, name: name, dirty: false, lang: nil}]
          },
          path
        )
  end

  @doc """
  Shows the settings page (`BeeWeb.Workbench.SettingsEditor`) in an editor
  tab, on the user's settings (`:user`) or the folder's (`:workspace`): its
  own tab, or the open one, turned to that scope.
  """
  def open_settings(wb, scope) when scope in [:user, :workspace] do
    path = "settings:"

    if open?(wb, path) do
      wb |> update_tab(path, &%{&1 | scope: scope}) |> reveal(path)
    else
      tab = %{path: path, kind: :settings, scope: scope, dirty: false, lang: nil}
      activate_editor(%{wb | tabs: wb.tabs ++ [tab]}, path)
    end
  end

  @doc """
  Shows a plugin's editor (`%{plugin, id, title, params, key}`, see
  `Bee.API.open_editor/3`) in an editor tab: its own, or the open one.
  """
  def open_live_editor(wb, %{plugin: plugin, id: id} = spec) do
    path = "live:#{plugin}/#{id}" <> if(spec[:key], do: "#" <> spec.key, else: "")

    if open?(wb, path) do
      reveal(wb, path)
    else
      tab = %{
        path: path,
        kind: :live,
        plugin: plugin,
        editor: id,
        key: spec[:key],
        title: spec.title,
        params: spec[:params] || %{},
        dirty: false,
        lang: nil
      }

      activate_editor(%{wb | tabs: wb.tabs ++ [tab]}, path)
    end
  end

  @doc """
  Shows webview panel `id` (`Bee.Webviews`) in an editor tab named `title`:
  a new one (shown unless `activate?` is false), or the open one.
  """
  def open_webview(wb, id, title, activate? \\ true) do
    path = "webview:" <> id

    cond do
      open?(wb, path) ->
        if activate?, do: reveal(wb, path), else: wb

      true ->
        tab = %{path: path, kind: :webview, webview: id, title: title, dirty: false, lang: nil}
        wb = %{wb | tabs: wb.tabs ++ [tab]}
        if activate? or wb.active == nil, do: activate_editor(wb, path), else: wb
    end
  end

  @doc "The title of webview panel `id`'s tab is `title` now."
  def set_webview_title(wb, id, title),
    do: update_tab(wb, "webview:" <> id, &%{&1 | title: title})

  @doc """
  Shows `path` in the focused group: activates its tab there, or asks for
  the file to be opened (also when another group has it open).

  With `preview: true` it opens as VS Code's preview editor does (a single
  click in the Explorer): in the one tab that is reused by the next file
  opened that way, until it is kept (`keep_editor/2`: a double click, an
  edit). Without it the file's tab is kept – also one that was a preview.
  """
  def open_editor(wb, path, opts \\ []) do
    preview? = Keyword.get(opts, :preview, false)

    cond do
      here?(wb, path) and preview? -> activate_editor(wb, path)
      here?(wb, path) -> wb |> keep_here(path) |> activate_editor(path)
      preview? -> {wb, [{:open_file, path, :preview}]}
      opts[:replace] -> {wb, [{:open_file, path, :replace}]}
      true -> {wb, [{:open_file, path}]}
    end
  end

  @doc """
  Called once the buffer for `path` is open; `lang` is its language id: a
  tab for it in the focused group. As a preview (`preview?`, and nothing
  unsaved in it) it takes the place of the group's tab that is one, whose
  file is closed.
  """
  def editor_opened(wb, path, dirty, lang, preview? \\ false) do
    tab = %{
      path: path,
      kind: :file,
      dirty: dirty,
      lang: lang,
      preview: preview? == true and not dirty
    }

    {index, wb} = insert_index(wb, path)

    cond do
      here?(wb, path) ->
        activate_editor(wb, path)

      # (`:replace`: kept, but where the preview is – a double click whose
      # second click came before the first one's file was open.)
      old = (tab.preview or preview? == :replace) && Enum.find_index(wb.tabs, &preview?/1) ->
        closed = Enum.at(wb.tabs, old).path

        {%{wb | tabs: List.replace_at(wb.tabs, old, tab), active: path},
         file_closed(wb, closed, true)}

      true ->
        %{wb | tabs: insert(wb.tabs, tab, index), active: path}
    end
  end

  defp insert_index(%{insert_at: {path, index}} = wb, path), do: {index, %{wb | insert_at: nil}}
  defp insert_index(wb, _path), do: {nil, %{wb | insert_at: nil}}

  # The effects of the focused group's editor of file `path` going: the
  # browser's, and – unless another group shows the file (or `buffer?` is
  # false: the file is only moving) – its buffer's.
  defp file_closed(wb, path, buffer?) do
    if(buffer? and not elsewhere?(wb, path), do: [{:close_buffer, path}], else: []) ++
      [{:push, "cm:close", %{path: path, group: wb.group}}]
  end

  @doc "Whether `tab` is a preview: the next file previewed takes its place."
  def preview?(tab), do: Map.get(tab, :preview, false)

  @doc "Keeps the editor of `path` open: it is no preview any more."
  def keep_editor(wb, path), do: update_tab(wb, path, &Map.put(&1, :preview, false))

  defp keep_here(wb, path) do
    %{
      wb
      | tabs: Enum.map(wb.tabs, &if(&1.path == path, do: Map.put(&1, :preview, false), else: &1))
    }
  end

  def language(wb, path), do: Enum.find_value(all_tabs(wb), &(&1.path == path && &1.lang))

  @doc "Shows the focused group's editor of `path`."
  def activate_editor(wb, path) do
    case Enum.find(wb.tabs, &(&1.path == path)) do
      %{kind: :file} ->
        {%{wb | active: path}, [{:push, "cm:activate", %{path: path, group: wb.group}}]}

      # Not a file: CodeMirror puts its file away (and its focus).
      %{} ->
        {%{wb | active: path}, [{:push, "cm:deactivate", %{group: wb.group}}]}

      nil ->
        wb
    end
  end

  @doc "Shows group `group`'s editor of `path` (a click on its tab), focusing the group."
  def activate_editor(wb, group, path),
    do: wb |> focus_group(group) |> wrap() |> chain(&activate_editor(&1, path))

  @doc """
  Closes the editor of `path`: the focused group's, else the one of the
  group that has it.
  """
  def close_editor(wb, path) do
    cond do
      here?(wb, path) ->
        close_here(wb, path, true)

      holder = Enum.find(wb.others, fn group -> Enum.any?(group.tabs, &(&1.path == path)) end) ->
        in_group(wb, holder.id, &close_here(&1, path, true))

      true ->
        wb
    end
  end

  @doc "Closes group `group`'s editor of `path`."
  def close_editor(wb, group, path), do: in_group(wb, group, &close_here(&1, path, true))

  @doc "Closes every group's editor of `path` (its file is gone)."
  def close_everywhere(wb, path) do
    if open?(wb, path),
      do: wb |> close_editor(path) |> wrap() |> chain(&close_everywhere(&1, path)),
      else: wb
  end

  # Closes the focused group's editor of `path`; `gone?` false: it is only
  # moving to another group (its buffer, its webview panel stay).
  defp close_here(wb, path, gone?) do
    case Enum.find_index(wb.tabs, &(&1.path == path)) do
      nil ->
        wb

      index ->
        remaining = List.delete_at(wb.tabs, index)

        effects =
          case Enum.at(wb.tabs, index) do
            %{kind: :file} -> file_closed(wb, path, gone?)
            # Its extension is told: the panel is disposed of.
            %{kind: :webview, webview: id} when gone? -> [{:webview_closed, id}]
            _ -> []
          end

        wb = %{wb | tabs: remaining}

        cond do
          remaining == [] ->
            chain({%{wb | active: nil}, effects}, &drop_group/1)

          wb.active != path ->
            {wb, effects}

          true ->
            neighbour = Enum.at(remaining, min(index, length(remaining) - 1)).path
            chain({wb, effects}, &activate_editor(&1, neighbour))
        end
    end
  end

  @doc """
  Closes the focused group's editors of `paths` (in tab order), as
  `close_editor/2` does one: unsaved changes are dropped – callers ask
  first (see `Bee.Workbench.Actions`).
  """
  def close_editors(wb, paths) do
    group = wb.group
    Enum.reduce(paths, {wb, []}, fn path, acc -> chain(acc, &close_editor(&1, group, path)) end)
  end

  @doc "The open editors' paths, in tab order."
  def tab_paths(wb), do: Enum.map(wb.tabs, & &1.path)

  @doc "The paths of `paths` whose editors have unsaved changes."
  def dirty_paths(wb, paths),
    do: Enum.uniq(for(%{path: p, dirty: true} <- all_tabs(wb), p in paths, do: p))

  @doc """
  Puts the tabs in `order` (paths, e.g. after one was dragged); open
  editors it doesn't name keep their order, after the others.
  """
  def reorder_tabs(wb, group, order), do: in_group(wb, group, &reorder_tabs(&1, order)) |> elem(0)

  def reorder_tabs(wb, order) when is_list(order) do
    index = order |> Enum.with_index() |> Map.new()

    tabs =
      wb.tabs
      |> Enum.with_index()
      |> Enum.sort_by(fn {tab, i} -> {Map.get(index, tab.path, length(order)), i} end)
      |> Enum.map(&elem(&1, 0))

    %{wb | tabs: tabs}
  end

  # (An edited file is kept, as in VS Code.)
  def set_dirty(wb, path, dirty) do
    update_tab(wb, path, fn tab ->
      tab = %{tab | dirty: dirty}
      if dirty, do: Map.put(tab, :preview, false), else: tab
    end)
  end

  def set_language(wb, path, lang), do: update_tab(wb, path, &%{&1 | lang: lang})

  @doc "Whether the active editor has something to undo / redo (reported by the browser)."
  def set_history(wb, can_undo, can_redo), do: %{wb | can_undo: can_undo, can_redo: can_redo}

  # Every group's tab of `path`.
  defp update_tab(wb, path, fun) do
    update = fn tabs -> Enum.map(tabs, &if(&1.path == path, do: fun.(&1), else: &1)) end
    %{wb | tabs: update.(wb.tabs), others: Enum.map(wb.others, &%{&1 | tabs: update.(&1.tabs)})}
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

  @doc "Remembers the order of the panel's sections (container ids), as dragged."
  def reorder_panel(wb, order) when is_list(order),
    do: %{wb | panel_order: order |> Enum.filter(&is_binary/1) |> Enum.uniq()}

  @doc """
  Sorts views containers by an order as dragged (`activity_order`,
  `panel_order`); those it doesn't name (a plugin's, installed since) keep
  their order, after the others.
  """
  def sort_containers(containers, order) do
    index = order |> Enum.with_index() |> Map.new()

    containers
    |> Enum.with_index()
    |> Enum.sort_by(fn {c, i} -> {Map.get(index, c.id, length(order)), i} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Shows sidebar view `view`, also when it is already shown."
  def reveal_view(wb, view), do: %{wb | sidebar_open: true, sidebar_view: view}

  ## Panel
  #
  # Sections (panel views containers, `Bee.Views.containers(:panel)`):
  # Terminal and Bee Console, and plugins'. Showing one prepares it: the
  # terminal section starts a shell when there is none, the console section
  # the window's console when it isn't running.

  @doc """
  Closing the panel keeps the shells and the console running (their views
  re-attach on reopen).
  """
  def toggle_panel(%{panel_open: true} = wb), do: {%{wb | panel_open: false}, [:panel_hidden]}
  def toggle_panel(wb), do: show_panel(wb, wb.panel_view)

  @doc "Opens the panel on section `id`."
  def show_panel(wb, id) do
    wb = %{wb | panel_open: true, panel_view: id}

    case id do
      "terminal" when wb.terminals == [] -> {wb, [:new_terminal]}
      "console" when wb.console == nil -> {wb, [:start_console]}
      _ -> {wb, [{:panel_shown, id}]}
    end
  end

  def toggle_maximized_panel(%{panel_open: false} = wb),
    do: chain({%{wb | panel_maximized: true}, []}, &toggle_panel/1)

  def toggle_maximized_panel(wb), do: %{wb | panel_maximized: not wb.panel_maximized}

  @doc "Called once the window's `Bee.Console` with `id` is running."
  def console_started(wb, id), do: %{wb | console: id, panel_open: true, panel_view: "console"}

  @doc "A terminal or the console: an xterm view of the panel."
  def term_view?(wb, id), do: id == wb.console or terminal?(wb, id)

  ## Terminals

  def terminal?(wb, id), do: Enum.any?(wb.terminals, &(&1.id == id))

  @doc """
  Called once a `Bee.Terminal` with `id` is running. A terminal has a
  `name`, an `icon` (a Heroicons outline name) and a `color` (nil or one of
  `terminal_colors/0`), all of which the user can change.
  """
  def terminal_started(wb, id, name) do
    terminal = %{id: id, name: name, icon: "command-line", color: nil}

    %{
      wb
      | terminals: wb.terminals ++ [terminal],
        active_term: id,
        panel_open: true,
        panel_view: "terminal"
    }
  end

  @terminal_colors ~w(red green yellow blue magenta cyan)

  @doc "The colours a terminal can have (VS Code's terminal.ansi* ones)."
  def terminal_colors, do: @terminal_colors

  def rename_terminal(wb, id, name) do
    case String.trim(name) do
      "" -> wb
      name -> update_terminal(wb, id, &%{&1 | name: name})
    end
  end

  def set_terminal_icon(wb, id, icon), do: update_terminal(wb, id, &%{&1 | icon: icon})

  def set_terminal_color(wb, id, color) when color == nil or color in @terminal_colors,
    do: update_terminal(wb, id, &%{&1 | color: color})

  def set_terminal_color(wb, _id, _color), do: wb

  @doc "Puts the terminals in `order` (ids, after a drag); others keep their order, after."
  def reorder_terminals(wb, order) when is_list(order) do
    index = order |> Enum.with_index() |> Map.new()

    terminals =
      wb.terminals
      |> Enum.with_index()
      |> Enum.sort_by(fn {t, i} -> {Map.get(index, t.id, length(order)), i} end)
      |> Enum.map(&elem(&1, 0))

    %{wb | terminals: terminals}
  end

  defp update_terminal(wb, id, fun) do
    %{wb | terminals: Enum.map(wb.terminals, &if(&1.id == id, do: fun.(&1), else: &1))}
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

    * `:quick_open` – files and commands, by the query: see
      `Bee.Workbench.QuickOpen` (`>` for commands)
    * `:pick` – choose one of `items` (`%{label, description, value}`); the
      choice runs `command` with `arguments ++ [value]`. Optional: `index`,
      the item selected first; `preview`, what the selected item previews
      while it is selected (`:color_theme`: its value is a theme id, see
      `BeeWeb.EditorLive.Config`)
    * `:input` – type a line; Enter runs `command` with `arguments ++ [text]`

  `open_quick_open/2` opens the first with `query` typed in: `""` for
  files, `">"` for commands (the command palette, `open_palette/1`).
  """
  def open_palette(wb), do: open_quick_open(wb, ">")

  def open_quick_open(wb, query \\ "") do
    was_open? = wb.palette != nil
    wb = %{wb | palette: %{mode: :quick_open, query: query, index: 0}, open_menu: nil}

    # Already open, its input keeps what was typed while it has focus:
    # replace it. (Not when it opens: it shows the query, and the event
    # could come after the first keys typed, and wipe them.)
    if was_open?, do: {wb, [{:push, "palette:query", %{query: query}}]}, else: wb
  end

  # A pick (or, below, a text) runs `command` with it – or, with `reply:
  # {pid, ref}` and no command, is sent there: `{:bee_answer, ref, value}`,
  # `nil` when the palette closes without one (BeeWeb.EditorLive.Window).
  def open_quick_pick(wb, %{items: items} = spec) do
    palette = %{
      mode: :pick,
      query: "",
      index: Map.get(spec, :index, 0),
      items: items,
      command: Map.get(spec, :command),
      reply: Map.get(spec, :reply),
      arguments: Map.get(spec, :arguments, []),
      placeholder: Map.get(spec, :placeholder, ""),
      preview: Map.get(spec, :preview)
    }

    %{wb | palette: palette, open_menu: nil}
  end

  def open_input_box(wb, spec) do
    palette = %{
      mode: :input,
      query: Map.get(spec, :value, ""),
      index: 0,
      command: Map.get(spec, :command),
      reply: Map.get(spec, :reply),
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
    # resource*, editorLangId, undo/redo: the active editor's file, if it is one.
    active = active_file(wb)

    settings
    |> Map.new(fn {key, value} -> {"config." <> key, value} end)
    |> Map.merge(%{
      "activeEditor" =>
        if(active, do: Bee.Workspace.FS.relative(wb.root, active), else: wb.active),
      "activeEditorIsDirty" => Enum.any?(wb.tabs, &(&1.path == active and &1.dirty)),
      "activeEditorIsNotPreview" =>
        not Enum.any?(wb.tabs, &(&1.path == wb.active and preview?(&1))),
      "resourceScheme" => wb.active && if(active, do: "file", else: "extension"),
      "resourceFilename" => active && Path.basename(active),
      "resourceExtname" => active && Path.extname(active),
      "resourcePath" => active,
      "resourceDirname" => active && Path.dirname(active),
      "resourceLangId" => active && language(wb, active),
      "editorLangId" => active && language(wb, active),
      "editorReadonly" => false,
      "workspaceFolderCount" => 1,
      "isWorkspaceTrusted" => true,
      "editorIsOpen" => wb.tabs != [],
      "multipleEditorGroups" => wb.others != [],
      "canUndo" => active != nil and wb.can_undo,
      "canRedo" => active != nil and wb.can_redo,
      "sideBarVisible" => wb.sidebar_open,
      "activeViewlet" => wb.sidebar_open && "workbench.view.#{wb.sidebar_view}",
      "panelVisible" => wb.panel_open,
      "activePanel" => wb.panel_open && wb.panel_view,
      "panelMaximized" => wb.panel_maximized,
      "terminalCount" => length(wb.terminals),
      "searchHasQuery" => wb.search != nil and String.trim(wb.search.query) != "",
      "hasSearchResult" => wb.search != nil and wb.search.results != %{},
      "searchCaseSensitive" => wb.search != nil and wb.search.case_sensitive,
      "searchWholeWord" => wb.search != nil and wb.search.whole_word,
      "searchRegex" => wb.search != nil and wb.search.regex,
      "inQuickOpen" => wb.palette != nil,
      "menuOpen" => wb.open_menu != nil,
      "explorerCanPaste" => wb.clipboard != nil,
      "searchMarketplaceExtensions" =>
        wb.marketplace != nil and String.trim(wb.marketplace.query) != ""
    })
  end
end

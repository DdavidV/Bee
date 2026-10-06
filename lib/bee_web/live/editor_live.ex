defmodule BeeWeb.EditorLive do
  @moduledoc """
  The editor window.

  Window state is a `%Bee.Workbench{}`, kept as individual assigns (one per
  field) so LiveView change tracking stays fine-grained. Events and commands
  change it through `Bee.Workbench` functions and command handlers, which
  return effects; `run_effects/2` performs them (buffers, terminals, browser
  events).

  Every user action (menus, palette, keybindings, buttons) goes through
  `run_command` with a `Bee.Commands.Registry` id: Bee's server commands run
  their `use Bee.Commands.Command` handler here, plugin server commands are
  handed to `Bee.Plugins` (the plugin answers with `{:bee_api, request}`
  messages, see `Bee.API`), client ones are sent to the browser as
  `bee:exec`. The `when` context (`Bee.Workbench.context/2`) is evaluated
  here for menus and the palette, and sent to the browser (`data-context`)
  for keybindings.

  Text lives in CodeMirror (`CodeEditor` hook) and in a `Bee.Editor.Buffer` per
  file. Terminals are `Bee.Terminal` processes owned by this LiveView, shown
  by the `Terminal` hook; output is forwarded only after the hook reported
  ready and replayed the scrollback (`term_seq` = last forwarded sequence).
  """
  use BeeWeb, :live_view

  alias Bee.{Languages, Plugins, Settings, Terminal, Workbench, Workspace}
  alias Bee.Commands.Registry, as: CommandRegistry
  alias Bee.Commands.Keybindings
  alias Bee.Editor.Buffer
  alias Bee.Workspace.{FileFinder, Files, RecentFiles}
  alias Bee.Workbench.{QuickOpen, Search}

  @impl true
  def mount(params, _session, socket) do
    # The window's folder: ?folder=…, else the one Bee was started for.
    {root, problem} = folder(params["folder"])
    if connected?(socket), do: Workspace.open(root)

    if connected?(socket) do
      Workspace.subscribe()
      Buffer.subscribe()
      Settings.subscribe()
      Keybindings.subscribe()
      CommandRegistry.subscribe()
      Plugins.subscribe()
      Bee.API.subscribe_window(root)
      Bee.UI.subscribe(root)
    end

    {:ok,
     socket
     |> assign(page_title: Path.basename(root), term_seq: %{}, selection: nil)
     |> assign(root: root)
     |> assign(connected: connected?(socket))
     |> assign(view_inputs: %{}, collapsed: MapSet.new(), collapsed_views: MapSet.new())
     |> assign(view_sizes: %{})
     |> assign(quick_open: nil)
     |> load_views()
     |> assign(status_items: Bee.UI.status_items(root), ui_context: Bee.UI.context(root))
     |> load_decorations()
     |> put_workbench(restore_layout(Workbench.new(root), socket))
     |> load_settings(Settings.all(root), Settings.errors(root))
     |> assign(keybindings: Keybindings.all(), keybinding_errors: Keybindings.errors())
     |> load_commands()
     |> load_plugins()
     |> allow_upload(:vsix,
       accept: :any,
       max_entries: 1,
       max_file_size: 200_000_000,
       auto_upload: true,
       progress: &vsix_progress/3
     )
     |> then(&if(problem, do: put_flash(&1, :error, problem), else: &1))
     |> open_file_param(params["file"])}
  end

  # ?file=… or ?file[]=…: files to open (the desktop app's `bee FILE…`),
  # once connected.
  defp open_file_param(socket, files) do
    if connected?(socket) do
      for path <- List.wrap(files), is_binary(path), path != "", reduce: socket do
        socket -> run_command(socket, "bee.openFile", [Path.expand(path, socket.assigns.root)])
      end
    else
      socket
    end
  end

  # `{root, problem}`: the folder asked for, or Bee's own with why not.
  defp folder(nil), do: {Workspace.root(), nil}

  defp folder(path) do
    root = Path.expand(path)

    if File.dir?(root),
      do: {root, nil},
      else: {Workspace.root(), "Can't open #{root}: not a folder"}
  end

  ## Commands

  # `args`: optional JSON array (view items, buttons with arguments).
  @impl true
  def handle_event("run_command", %{"command" => id} = params, socket) do
    {:noreply,
     socket
     |> change(
       &(&1
         |> Workbench.close_menu()
         |> Workbench.close_palette()
         |> Workbench.close_context_menu())
     )
     |> run_command(id, decode_args(params["args"]))}
  end

  ## Context menus (ContextMenus hook): the element right-clicked names the
  ## menu, its commands' arguments and extra `when` keys.

  def handle_event("open_context_menu", %{"menu" => menu, "x" => x, "y" => y} = params, socket)
      when is_binary(menu) and is_number(x) and is_number(y) do
    args = if is_list(params["args"]), do: params["args"], else: []
    context = if is_map(params["context"]), do: params["context"], else: %{}

    {:noreply,
     change(socket, &Workbench.open_context_menu(&1, menu, round(x), round(y), args, context))}
  end

  def handle_event("close_context_menu", _params, socket),
    do: {:noreply, change(socket, &Workbench.close_context_menu/1)}

  ## Sidebar views

  # Activity bar: show a container's views (or hide the sidebar, VS Code style).
  def handle_event("show_view", %{"container" => id}, socket) do
    socket = change(socket, &Workbench.show_view(&1, id))
    if socket.assigns.sidebar_open, do: views_shown(socket)
    {:noreply, socket}
  end

  # An activity bar icon was dragged to another place: the containers' new order.
  def handle_event("reorder_activity", %{"order" => order}, socket) when is_list(order),
    do: {:noreply, change(socket, &Workbench.reorder_activity(&1, order))}

  ## Search view

  def handle_event("search_update", params, socket) do
    fields =
      for {key, value} <- params,
          key in ~w(query replace include exclude),
          into: %{},
          do: {String.to_existing_atom(key), value}

    {:noreply, change(socket, &Search.update(&1, fields))}
  end

  def handle_event("search_toggle", %{"key" => key}, socket)
      when key in ~w(show_replace show_details),
      do: {:noreply, change(socket, &Search.toggle(&1, String.to_existing_atom(key)))}

  def handle_event("search_refresh", _params, socket),
    do: {:noreply, change(socket, &Search.refresh/1)}

  def handle_event("search_toggle_file", %{"path" => path}, socket),
    do: {:noreply, change(socket, &Search.toggle_file(&1, path))}

  # A match: open its file and select it.
  def handle_event("search_open", %{"path" => rel, "from" => from, "to" => to}, socket) do
    case Workspace.resolve(socket.assigns.root, rel) do
      {:ok, path} ->
        socket = change(socket, &Workbench.open_editor(&1, path))

        if Workbench.open?(workbench(socket), path),
          do:
            {:noreply,
             push_event(socket, "cm:reveal", %{path: path, from: int(from), to: int(to)})},
          else: {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("search_replace", %{"target" => "all"}, socket),
    do: {:noreply, change(socket, &Search.replace(&1, :all))}

  def handle_event("search_replace", %{"target" => "file", "path" => path}, socket),
    do: {:noreply, change(socket, &Search.replace(&1, {:file, path}))}

  def handle_event(
        "search_replace",
        %{"target" => "match", "path" => path, "from" => from},
        socket
      ),
      do: {:noreply, change(socket, &Search.replace(&1, {:match, path, int(from)}))}

  ## Layout

  # A sash was dragged (or double-clicked: size nil) – see the Sash hook.
  def handle_event("layout_resize", %{"part" => part, "size" => size}, socket)
      when part in ["sidebar", "panel"],
      do: {:noreply, change(socket, &Workbench.resize(&1, String.to_existing_atom(part), size))}

  # A sash was pulled past the minimum and released: hide that part.
  def handle_event("layout_hide", %{"part" => "sidebar"}, socket) do
    if socket.assigns.sidebar_open,
      do: {:noreply, change(socket, &Workbench.toggle_sidebar/1)},
      else: {:noreply, socket}
  end

  def handle_event("layout_hide", %{"part" => "panel"}, socket) do
    if socket.assigns.panel_open,
      do: {:noreply, change(socket, &Workbench.toggle_panel/1)},
      else: {:noreply, socket}
  end

  def handle_event("toggle_view_item", %{"view" => view, "item" => item}, socket) do
    key = {view, item}

    collapsed =
      if MapSet.member?(socket.assigns.collapsed, key),
        do: MapSet.delete(socket.assigns.collapsed, key),
        else: MapSet.put(socket.assigns.collapsed, key)

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  ## Installing from VSIX (workbench.extensions.action.installVSIX)

  # Required by uploads; the file goes up as soon as it is picked.
  def handle_event("vsix_validate", _params, socket) do
    case socket.assigns.uploads.vsix.entries do
      [%{} = entry] ->
        case upload_errors(socket.assigns.uploads.vsix, entry) do
          [] ->
            {:noreply, socket}

          errors ->
            {:noreply,
             socket
             |> cancel_upload(:vsix, entry.ref)
             |> put_flash(:error, "Can't upload #{entry.client_name}: #{inspect(errors)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # A view's header folds the view (when its container shows several).
  def handle_event("toggle_view", %{"view" => view}, socket) do
    collapsed =
      if MapSet.member?(socket.assigns.collapsed_views, view),
        do: MapSet.delete(socket.assigns.collapsed_views, view),
        else: MapSet.put(socket.assigns.collapsed_views, view)

    {:noreply, assign(socket, collapsed_views: collapsed)}
  end

  # A sash between views was dragged: the body heights of the open views.
  def handle_event("view_resize", %{"sizes" => sizes}, socket) when is_map(sizes) do
    sizes =
      for {view, size} <- sizes,
          is_number(size),
          size >= 0,
          into: %{},
          do: {view, min(size, 10_000)}

    {:noreply, update(socket, :view_sizes, &Map.merge(&1, sizes))}
  end

  # Double-clicked: these views share the height evenly again.
  def handle_event("view_resize", %{"reset" => views}, socket) when is_list(views),
    do: {:noreply, update(socket, :view_sizes, &Map.drop(&1, views))}

  def handle_event("view_input", %{"view" => view, "value" => value}, socket),
    do: {:noreply, update(socket, :view_inputs, &Map.put(&1, view, value))}

  def handle_event("view_submit", %{"view" => view_id} = params, socket) do
    value = params["value"] || Map.get(socket.assigns.view_inputs, view_id, "")

    case socket.assigns.view_contents[view_id] do
      %{input: %{command: command, arguments: args}} ->
        {:noreply,
         socket
         |> update(:view_inputs, &Map.put(&1, view_id, value))
         |> run_command(command, args ++ [value])}

      _ ->
        {:noreply, socket}
    end
  end

  ## Menus

  def handle_event("toggle_menu", %{"menu" => menu}, socket),
    do: {:noreply, change(socket, &Workbench.toggle_menu(&1, menu))}

  def handle_event("close_menu", _params, socket),
    do: {:noreply, change(socket, &Workbench.close_menu/1)}

  ## Command palette

  def handle_event("palette_filter", %{"query" => query}, socket),
    do: {:noreply, change(socket, &Workbench.filter_palette(&1, query))}

  def handle_event("palette_key", %{"key" => key}, socket) do
    count = length(palette_items(socket.assigns))

    case key do
      "ArrowDown" -> {:noreply, change(socket, &Workbench.move_palette(&1, 1, count))}
      "ArrowUp" -> {:noreply, change(socket, &Workbench.move_palette(&1, -1, count))}
      "Escape" -> {:noreply, change(socket, &Workbench.close_palette/1)}
      _ -> {:noreply, socket}
    end
  end

  # Enter in the input submits the form.
  def handle_event("palette_run", _params, %{assigns: %{palette: %{mode: :input} = p}} = socket) do
    {:noreply,
     socket
     |> change(&Workbench.close_palette/1)
     |> run_command(p.command, p.arguments ++ [p.query])}
  end

  def handle_event("palette_run", _params, %{assigns: %{palette: %{index: index}}} = socket) do
    case Enum.at(palette_items(socket.assigns), index) do
      nil -> {:noreply, socket}
      item -> {:noreply, palette_choose(socket, item)}
    end
  end

  def handle_event("palette_run", _params, socket), do: {:noreply, socket}

  # Clicking a quick pick item.
  def handle_event("palette_pick", %{"index" => index}, socket) do
    case Enum.at(palette_items(socket.assigns), String.to_integer(index)) do
      nil -> {:noreply, socket}
      item -> {:noreply, palette_choose(socket, item)}
    end
  end

  def handle_event("close_palette", _params, socket),
    do: {:noreply, change(socket, &Workbench.close_palette/1)}

  ## Editor

  def handle_event("activate_tab", %{"path" => path}, socket),
    do: {:noreply, change(socket, &Workbench.activate_editor(&1, path))}

  def handle_event("close_tab", %{"path" => path}, socket),
    do: {:noreply, change(socket, &Workbench.close_editor(&1, path))}

  def handle_event("doc_changed", %{"path" => path, "text" => text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      dirty = Buffer.dirty?(Buffer.update(path, text))
      {:noreply, change(socket, &Workbench.set_dirty(&1, path, dirty))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"path" => path, "text" => text}, socket) do
    with true <- Workbench.open?(workbench(socket), path),
         {:ok, _buffer} <- Buffer.save(path, text) do
      # Apply right away, also when file watching is unavailable.
      if path in [Settings.user_path(), Settings.workspace_path(socket.assigns.root)],
        do: Settings.reload()

      if path == Keybindings.user_path(), do: Keybindings.reload()

      {:noreply,
       change(socket, fn wb ->
         wb
         |> Workbench.set_dirty(path, false)
         |> Workbench.set_status("Saved #{display_path(wb.root, path)}")
       end)}
    else
      false ->
        {:noreply, socket}

      {:error, reason} ->
        message = "Could not save #{display_path(socket.assigns.root, path)}: #{inspect(reason)}"
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("open_problem", %{"path" => path}, socket),
    do: {:noreply, change(socket, &Workbench.open_editor(&1, path))}

  # bee.request() of a browser plugin: answered later with plugin:reply.
  def handle_event("plugin_request", %{"plugin" => plugin, "ref" => ref} = params, socket) do
    ctx = plugin_context(socket.assigns)

    case Plugins.request(plugin, params["method"], params["params"], ctx, ref) do
      :ok ->
        {:noreply, socket}

      {:error, message} ->
        {:noreply, push_event(socket, "plugin:reply", %{ref: ref, error: message})}
    end
  end

  # bee.showMessage() of a browser plugin.
  def handle_event("plugin_message", %{"plugin" => plugin, "text" => text} = params, socket) do
    level = if params["level"] == "error", do: :error, else: :info
    {:noreply, put_flash(socket, level, "#{plugin}: #{text}")}
  end

  # Undo/redo availability of the active editor (enables the undo/redo commands).
  def handle_event("history_changed", %{"canUndo" => can_undo, "canRedo" => can_redo}, socket),
    do: {:noreply, change(socket, &Workbench.set_history(&1, can_undo == true, can_redo == true))}

  # Selections of the active editor, UTF-8 byte offsets (for plugin commands).
  def handle_event("selection_changed", %{"path" => path, "ranges" => ranges}, socket) do
    ranges = for [from, to] <- ranges, is_integer(from), is_integer(to), do: {from, to}
    {:noreply, assign(socket, selection: {path, ranges})}
  end

  ## Terminal

  def handle_event("activate_terminal", %{"id" => id}, socket),
    do: {:noreply, change(socket, &Workbench.activate_terminal(&1, String.to_integer(id)))}

  def handle_event("close_terminal", %{"id" => id}, socket),
    do: {:noreply, change(socket, &Workbench.kill_terminal(&1, String.to_integer(id)))}

  def handle_event("term_ready", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    if Workbench.terminal?(workbench(socket), id) do
      Terminal.resize(id, cols, rows)
      {scrollback, seq} = Terminal.scrollback(id)

      {:reply, %{data: Base.encode64(scrollback)},
       update(socket, :term_seq, &Map.put(&1, id, seq))}
    else
      {:reply, %{data: ""}, socket}
    end
  catch
    # The shell exited in the meantime; :term_exit removes the tab.
    :exit, _ -> {:reply, %{data: ""}, socket}
  end

  def handle_event("term_input", %{"id" => id, "data" => data}, socket) do
    if Workbench.terminal?(workbench(socket), id), do: Terminal.input(id, data)
    {:noreply, socket}
  end

  def handle_event("term_resize", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    if Workbench.terminal?(workbench(socket), id), do: Terminal.resize(id, cols, rows)
    {:noreply, socket}
  end

  ## PubSub

  @impl true
  def handle_info({:open_file, rel}, socket) do
    case Workspace.resolve(socket.assigns.root, rel) do
      {:ok, abs} -> {:noreply, change(socket, &Workbench.open_editor(&1, abs))}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Path outside workspace")}
    end
  end

  # The Explorer created or renamed a file (see FileTree).
  def handle_info({:explorer_changed, request, path}, socket) do
    case request do
      %{kind: :new_file} -> {:noreply, change(socket, &Workbench.open_editor(&1, path))}
      %{kind: :rename, path: from} -> {:noreply, files_moved(socket, [{from, path}])}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:fs_changed, path}, socket) do
    send_update(BeeWeb.Workbench.FileTree, id: "explorer", fs_changed: path)
    {:noreply, socket}
  end

  # Ours changed: the user's settings, or this window's workspace's.
  def handle_info({:settings_changed, scope}, socket)
      when scope == :user or scope == {:workspace, socket.assigns.root} do
    old = socket.assigns.settings
    {settings, errors} = {Settings.all(socket.assigns.root), Settings.errors(socket.assigns.root)}

    if settings["files.exclude"] != old["files.exclude"],
      do: send_update(BeeWeb.Workbench.FileTree, id: "explorer", refresh: true)

    socket = load_settings(socket, settings, errors)

    if settings["files.associations"] != old["files.associations"],
      do: {:noreply, redetect_languages(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:keybindings_changed, bindings, errors}, socket),
    do: {:noreply, load_keybindings(socket, bindings, errors)}

  def handle_info({:search_results, ref, files}, socket),
    do: {:noreply, change(socket, &Search.results(&1, ref, files))}

  def handle_info({:search_done, ref, stats}, socket),
    do: {:noreply, change(socket, &Search.done(&1, ref, stats))}

  def handle_info({:ui_changed, {:view, id}}, socket),
    do:
      {:noreply,
       update(socket, :view_contents, &Map.put(&1, id, Bee.UI.view(socket.assigns.root, id)))}

  def handle_info({:ui_changed, :status_items}, socket),
    do: {:noreply, assign(socket, status_items: Bee.UI.status_items(socket.assigns.root))}

  def handle_info({:ui_changed, :context}, socket),
    do: {:noreply, assign(socket, ui_context: Bee.UI.context(socket.assigns.root))}

  def handle_info({:ui_changed, :decorations}, socket), do: {:noreply, load_decorations(socket)}

  def handle_info({:contributions_changed, keys}, socket) do
    socket = if :commands in keys, do: load_commands(socket), else: socket

    socket =
      if :views in keys do
        socket = load_views(socket)

        # The shown container went away with its plugin.
        if Enum.any?(socket.assigns.containers, &(&1.id == socket.assigns.sidebar_view)),
          do: socket,
          else: change(socket, &%{&1 | sidebar_view: "explorer"})
      else
        socket
      end

    socket = if :languages in keys, do: redetect_languages(socket), else: socket

    socket =
      if :icon_themes in keys,
        do: assign(socket, icon_theme: icon_theme(socket.assigns.settings)),
        else: socket

    {:noreply, socket}
  end

  def handle_info(:plugins_changed, socket), do: {:noreply, load_plugins(socket)}

  # Quick Open's file finder answered.
  def handle_info(
        {:file_finder, finder, query, paths, loading?},
        %{assigns: %{quick_open: %{finder: finder} = data}} = socket
      ),
      do:
        {:noreply,
         assign(socket,
           quick_open: %{data | results: paths, results_for: query, loading?: loading?}
         )}

  def handle_info({:file_finder, _old, _query, _paths, _loading?}, socket), do: {:noreply, socket}

  # It stopped: on purpose, or it crashed (no results then, nothing worse).
  def handle_info({:DOWN, _ref, :process, finder, _reason}, socket) do
    case socket.assigns.quick_open do
      %{finder: ^finder} = data ->
        {:noreply, assign(socket, quick_open: %{data | finder: nil, loading?: false})}

      _ ->
        {:noreply, socket}
    end
  end

  # Requests from plugins (Bee.API).
  def handle_info({:bee_api, request}, socket), do: {:noreply, plugin_request(socket, request)}

  def handle_info({:buffer_edited, path, _version, edits, text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      edits = for {from, to, insert} <- edits, do: [from, to, insert]
      {:noreply, push_event(socket, "cm:edit", %{path: path, edits: edits, text: text})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:buffer_reloaded, path, text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      {:noreply,
       socket
       |> change(&Workbench.set_dirty(&1, path, false))
       |> push_event("cm:reload", %{path: path, text: text})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:term_data, id, seq, data}, socket) do
    case socket.assigns.term_seq do
      %{^id => last} when seq > last ->
        {:noreply,
         socket
         |> push_event("term:data", %{id: id, data: Base.encode64(data)})
         |> update(:term_seq, &Map.put(&1, id, seq))}

      # Not attached yet (replayed from scrollback on term_ready) or already sent.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:term_exit, id, _reason}, socket),
    do: {:noreply, change(socket, &Workbench.terminal_exited(&1, id))}

  # The remaining buffer events are for plugins and LSP.
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Workbench state and effects

  defp workbench(socket), do: workbench_from(socket.assigns)
  defp workbench_from(assigns), do: struct(Workbench, Map.take(assigns, Workbench.fields()))

  defp put_workbench(socket, wb),
    do: assign(socket, Map.take(Map.from_struct(wb), Workbench.fields()))

  # Applies `fun` (a Workbench function or command handler) and its effects.
  defp change(socket, fun) do
    {wb, effects} = Workbench.wrap(fun.(workbench(socket)))
    socket |> put_workbench(wb) |> run_effects(effects) |> sync_quick_open()
  end

  @doc false
  def run_effects(socket, effects), do: Enum.reduce(effects, socket, &run_effect/2)

  defp run_effect({:push, event, payload}, socket), do: push_event(socket, event, payload)

  defp run_effect({:open_file, path}, socket), do: open_buffer(socket, path)

  defp run_effect({:explorer_edit, edit}, socket) do
    send_update(BeeWeb.Workbench.FileTree, id: "explorer", edit: edit)
    socket
  end

  defp run_effect({:delete_file, path}, socket) do
    case Files.delete(socket.assigns.root, path) do
      {:ok, path} -> socket |> files_deleted(path) |> files_changed()
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  defp run_effect({:paste_files, op, paths, dir}, socket) do
    case Files.paste(socket.assigns.root, paths, dir, op) do
      {:ok, pairs} ->
        socket = files_changed(socket)
        if op == :cut, do: files_moved(socket, pairs), else: socket

      {:error, message} ->
        socket |> files_changed() |> put_flash(:error, message)
    end
  end

  defp run_effect({:close_buffer, path}, socket) do
    Buffer.close(path)
    socket
  end

  defp run_effect(:new_terminal, socket) do
    id = System.unique_integer([:positive])
    shell = Terminal.default_shell(socket.assigns.root)
    Phoenix.PubSub.subscribe(Bee.PubSub, Terminal.topic(id))

    case Terminal.start(id: id, owner: self(), shell: shell, cwd: socket.assigns.root) do
      {:ok, _pid} ->
        change(socket, &Workbench.terminal_started(&1, id, Path.basename(shell)))

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Bee.PubSub, Terminal.topic(id))
        put_flash(socket, :error, "Could not start terminal: #{inspect(reason)}")
    end
  end

  defp run_effect({:stop_terminal, id}, socket) do
    Terminal.stop(id)
    run_effect({:forget_terminal, id}, socket)
  end

  defp run_effect({:forget_terminal, id}, socket) do
    Phoenix.PubSub.unsubscribe(Bee.PubSub, Terminal.topic(id))
    update(socket, :term_seq, &Map.delete(&1, id))
  end

  # The xterm views were unmounted; they re-attach via term_ready.
  defp run_effect(:panel_hidden, socket), do: assign(socket, term_seq: %{})

  defp run_effect({:exec_client, command}, socket),
    do: run_effect({:exec_client, command, []}, socket)

  defp run_effect({:exec_client, command, args}, socket),
    do: push_event(socket, "bee:exec", %{command: command, args: args})

  defp run_effect({:run_plugin_command, %{handler: {:plugin, name}, id: id}, args}, socket) do
    case Plugins.execute(name, id, %{plugin_context(socket.assigns) | args: args}) do
      :ok -> socket
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  defp run_effect(:reload_plugins, socket) do
    Plugins.reload()
    socket |> load_plugins() |> put_flash(:info, "Plugins reloaded")
  end

  defp run_effect({:update_setting, key, value}, socket) do
    case Settings.update(:user, key, fn _ -> value end) do
      :ok -> socket
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  # Another folder: this window shows it (a new LiveView, `?folder=`), or a
  # new browser window does. Not while this one has unsaved changes – its
  # editors would be dropped.
  defp run_effect({:open_folder, path, where}, socket) do
    root = Path.expand(path, socket.assigns.root)
    dirty = for %{dirty: true, path: p} <- socket.assigns.tabs, do: Path.basename(p)
    url = ~p"/?#{[folder: root]}"

    cond do
      not File.dir?(root) ->
        put_flash(socket, :error, "#{root} is not a folder")

      where == :new_window ->
        push_event(socket, "bee:open_window", %{url: url})

      root == socket.assigns.root ->
        socket

      dirty != [] ->
        put_flash(socket, :error, "Save or close #{Enum.join(dirty, ", ")} first")

      true ->
        push_navigate(socket, to: url)
    end
  end

  # The desktop app's native dialog (assets/js/app.js); the pick comes
  # back as bee.openFolder [where, path].
  defp run_effect({:pick_folder, where, title}, socket),
    do:
      push_event(socket, "bee:pick_folder", %{
        where: where,
        title: title,
        start: socket.assigns.root
      })

  defp run_effect({:uninstall_plugin, name}, socket) do
    case Plugins.uninstall(name) do
      :ok -> socket |> load_plugins() |> put_flash(:info, "Uninstalled #{name}")
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  defp run_effect({:set_plugin_enabled, name, enabled?}, socket) do
    case Plugins.set_enabled(name, enabled?) do
      :ok -> socket
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  defp run_effect({:flash, kind, message}, socket), do: put_flash(socket, kind, message)

  defp run_effect({:start_search, opts}, socket) do
    case Bee.Search.start(Map.put(opts, :root, socket.assigns.root), self()) do
      {:ok, handle} -> change(socket, &Search.started(&1, handle))
      {:error, message} -> change(socket, &Search.failed(&1, message))
    end
  end

  defp run_effect({:cancel_search, handle}, socket) do
    Bee.Search.cancel(handle)
    socket
  end

  defp run_effect({:replace, paths, opts, replacement, only}, socket) do
    case Bee.Search.replace(paths, Map.put(opts, :root, socket.assigns.root), replacement, only) do
      {:ok, count} ->
        socket
        |> put_flash(
          :info,
          "Replaced #{count} #{if count == 1, do: "occurrence", else: "occurrences"}"
        )
        |> change(&Search.refresh/1)

      {:error, message} ->
        put_flash(socket, :error, message)
    end
  end

  # Find / Replace in Files: the selected text (one line) becomes the query.
  defp run_effect({:find_in_files, replace?}, socket) do
    socket =
      case selected_text(socket.assigns) do
        text when is_binary(text) and text != "" ->
          if String.contains?(text, "\n"),
            do: socket,
            else: change(socket, &Search.update(&1, %{query: text}))

        _ ->
          socket
      end

    socket =
      if replace? and not socket.assigns.search.show_replace,
        do: change(socket, &Search.toggle(&1, :show_replace)),
        else: socket

    push_event(socket, "search:focus", %{})
  end

  # Opens `path` in a new tab. `text`: unsaved text to carry over (a file
  # that was moved with unsaved changes).
  defp open_buffer(socket, path, text \\ nil) do
    with {:ok, buffer} <- Buffer.open(path) do
      buffer = if text, do: Buffer.update(path, text), else: buffer
      RecentFiles.add(socket.assigns.root, path)
      lang = Languages.detect(path, first_line: Languages.first_line(buffer.text))

      socket
      |> change(&Workbench.editor_opened(&1, path, Buffer.dirty?(buffer), lang))
      |> push_event("cm:open", %{
        path: path,
        text: buffer.text,
        lang: lang,
        mode: Languages.mode(lang)
      })
    else
      {:error, reason} ->
        message = "Cannot open #{display_path(socket.assigns.root, path)}: #{inspect(reason)}"
        put_flash(socket, :error, message)
    end
  end

  ## Explorer file operations

  # Bee changed files: the tree shows them now, not when the watcher tells.
  defp files_changed(socket) do
    send_update(BeeWeb.Workbench.FileTree, id: "explorer", refresh: true)
    socket
  end

  # Tabs of moved files (or files in moved folders) follow them, unsaved
  # changes included; the active one stays active.
  defp files_moved(socket, pairs) do
    Enum.reduce(pairs, socket, fn {from, to}, socket ->
      moved =
        for %{path: path} = tab <- socket.assigns.tabs, under?(path, from) do
          {tab, to <> String.replace_prefix(path, from, "")}
        end

      Enum.reduce(moved, socket, fn {tab, new_path}, socket ->
        active? = socket.assigns.active == tab.path
        text = if tab.dirty, do: Buffer.get(tab.path).text

        socket
        |> change(&Workbench.close_editor(&1, tab.path))
        |> open_buffer(new_path, text)
        |> then(
          &if(active?,
            do: change(&1, fn wb -> Workbench.activate_editor(wb, new_path) end),
            else: &1
          )
        )
      end)
    end)
  end

  # Tabs of deleted files close (their buffers had nothing left to save to).
  defp files_deleted(socket, path) do
    socket.assigns.tabs
    |> Enum.filter(&under?(&1.path, path))
    |> Enum.reduce(socket, fn tab, socket ->
      change(socket, &Workbench.close_editor(&1, tab.path))
    end)
  end

  defp under?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  ## Command execution

  # `args` reach plugin and client commands, and Bee's own server commands
  # whose handler takes them.
  defp run_command(socket, id, args \\ []) do
    case Enum.find(socket.assigns.commands, &(&1.id == id)) do
      nil ->
        put_flash(socket, :error, "Command '#{id}' not found")

      command ->
        cond do
          not CommandRegistry.enabled?(command, context(socket.assigns)) ->
            socket

          command.runtime == :client ->
            run_effect({:exec_client, id, args}, socket)

          match?({:plugin, _}, command.handler) ->
            run_effect({:run_plugin_command, command, args}, socket)

          true ->
            change(socket, &CommandRegistry.run_handler(command.handler, &1, args))
        end
    end
  end

  ## Plugins

  defp vsix_progress(:vsix, %{done?: false}, socket), do: {:noreply, socket}

  defp vsix_progress(:vsix, entry, socket) do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Bee.Plugins.Vsix.install(path)}
      end)

    case result do
      {:ok, name} ->
        {:noreply,
         socket
         |> load_plugins()
         |> change(&Workbench.reveal_view(&1, "extensions"))
         |> put_flash(:info, "Installed #{name} from #{entry.client_name}")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, "#{entry.client_name}: #{message}")}
    end
  end

  defp plugin_context(assigns) do
    active = assigns.active

    selections =
      case assigns.selection do
        {^active, ranges} when active != nil -> ranges
        _ -> []
      end

    %Bee.Plugins.Context{
      window: self(),
      root: assigns.root,
      active_editor: active,
      language: active && Workbench.language(workbench_from(assigns), active),
      selections: selections
    }
  end

  # What a plugin may ask of a window (Bee.API).
  defp plugin_request(socket, {:show_message, level, text}), do: put_flash(socket, level, text)

  defp plugin_request(socket, {:set_status, text}),
    do: change(socket, &Workbench.set_status(&1, text))

  defp plugin_request(socket, {:open_file, path, reveal}) do
    if File.regular?(path) do
      socket = change(socket, &Workbench.open_editor(&1, path))
      # After cm:open / cm:activate, so the editor has the file.
      if reveal && Workbench.open?(workbench(socket), path),
        do: push_event(socket, "cm:reveal", Map.put(reveal, :path, path)),
        else: socket
    else
      put_flash(socket, :error, "Cannot open #{path}: no such file")
    end
  end

  defp plugin_request(socket, {:execute_command, id}), do: run_command(socket, id)

  defp plugin_request(socket, {:set_view_input, view, value}) do
    socket
    |> update(:view_inputs, &Map.put(&1, view, value))
    # The box may have focus, where LiveView leaves its value alone.
    |> push_event("view:input", %{view: view, value: value})
  end

  defp plugin_request(socket, {:input_box, spec}),
    do: change(socket, &Workbench.open_input_box(&1, spec))

  defp plugin_request(socket, {:quick_pick, spec}),
    do: change(socket, &Workbench.open_quick_pick(&1, spec))

  defp plugin_request(socket, {:post_message, plugin, data}),
    do: push_event(socket, "plugin:message", %{plugin: plugin, data: data})

  defp plugin_request(socket, {:reply, ref, {:ok, result}}),
    do: push_event(socket, "plugin:reply", %{ref: ref, result: result})

  defp plugin_request(socket, {:reply, ref, {:error, message}}),
    do: push_event(socket, "plugin:reply", %{ref: ref, error: message})

  defp plugin_request(socket, _unknown), do: socket

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_binary(value), do: String.to_integer(value)

  # Text of the active editor's first selection, if any.
  defp selected_text(assigns) do
    with %{active: active, selection: {active, [{from, to} | _]}} when to > from <- assigns,
         text when is_binary(text) <- Bee.API.text(active),
         true <- to <= byte_size(text) do
      binary_part(text, from, to - from)
    else
      _ -> nil
    end
  end

  defp decode_args(nil), do: []

  defp decode_args(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, args} when is_list(args) -> args
      _ -> []
    end
  end

  ## Views

  defp load_views(socket) do
    views = Bee.Views.views()

    assign(socket,
      containers: Bee.Views.containers(),
      views: views,
      view_contents: Map.new(views, &{&1.id, Bee.UI.view(socket.assigns.root, &1.id)})
    )
  end

  # The shown container's plugin views need their plugin running.
  defp views_shown(socket) do
    for view <- socket.assigns.views,
        view.container == socket.assigns.sidebar_view,
        do: Plugins.view_shown(view.id, socket.assigns.root)

    :ok
  end

  @doc false
  # Views of the shown container whose `when` holds.
  def visible_views(assigns) do
    ctx = context(assigns)

    for view <- assigns.views,
        view.container == assigns.sidebar_view,
        Bee.Commands.When.eval(view.when_ast, ctx),
        do: view
  end

  @doc false
  # The shown views with their header buttons and their items' inline buttons
  # (per item context), for BeeWeb.Workbench.Sidebar.
  def sidebar_views(assigns) do
    for view <- visible_views(assigns) do
      contexts =
        case assigns.view_contents[view.id] do
          %{items: items} ->
            item_contexts(items)

          # Bee's Plugins view: its rows (BeeWeb.Workbench.PluginsView).
          _ when view.id == "workbench.extensions.installed" ->
            BeeWeb.Workbench.PluginsView.contexts()

          _ ->
            []
        end

      %{
        view: view,
        title_actions: toolbar(assigns, "view/title", %{"view" => view.id}),
        item_actions:
          Map.new(contexts, fn context ->
            {context,
             toolbar(
               assigns,
               "view/item/context",
               %{"view" => view.id, "viewItem" => context},
               true
             )}
          end)
      }
    end
  end

  defp item_contexts(items) do
    items
    |> Enum.flat_map(&[&1.context | item_contexts(&1.children)])
    |> Enum.uniq()
  end

  @doc false
  # Activity bar entries with the summed badges of their plugin views.
  def activity_bar(assigns) do
    for container <- Workbench.sort_activity(assigns.containers, assigns.activity_order) do
      badge =
        assigns.views
        |> Enum.filter(&(&1.container == container.id))
        |> Enum.map(&((assigns.view_contents[&1.id] || %{})[:badge] || 0))
        |> Enum.sum()

      Map.put(container, :badge, if(badge > 0, do: badge))
    end
  end

  defp load_plugins(socket) do
    assign(socket,
      plugins: Plugins.list(socket.assigns.root),
      plugin_errors: Plugins.errors(socket.assigns.root),
      browser_plugins: Plugins.browser_modules(socket.assigns.root)
    )
  end

  ## Languages

  # Language contributions or files.associations changed: re-detect open tabs.
  defp redetect_languages(socket) do
    Enum.reduce(socket.assigns.tabs, socket, fn %{path: path, lang: old}, socket ->
      text =
        try do
          Buffer.get(path).text
        catch
          :exit, _ -> ""
        end

      case Languages.detect(path, first_line: Languages.first_line(text)) do
        ^old ->
          socket

        lang ->
          socket
          |> change(&Workbench.set_language(&1, path, lang))
          |> push_event("cm:language", %{path: path, lang: lang, mode: Languages.mode(lang)})
      end
    end)
  end

  ## `when` context

  @doc false
  def context(assigns) do
    assigns
    |> workbench_from()
    |> Workbench.context(assigns.settings)
    |> Map.merge(assigns[:ui_context] || %{})
  end

  ## Settings / keybindings → assigns

  defp load_settings(socket, settings, errors) do
    socket
    |> assign(icon_theme: icon_theme(settings))
    |> assign(
      settings: settings,
      settings_errors: errors,
      editor_settings: %{
        fontSize: settings["editor.fontSize"],
        tabSize: settings["editor.tabSize"],
        wordWrap: settings["editor.wordWrap"],
        lineNumbers: settings["editor.lineNumbers"],
        theme: settings["workbench.colorTheme"]
      },
      terminal_settings: %{
        fontSize: settings["terminal.integrated.fontSize"],
        theme: settings["workbench.colorTheme"]
      }
    )
  end

  # The file icon theme picked in workbench.iconTheme, in its light or dark
  # variant; nil (Bee's own icons) when none is set or it isn't loaded (yet).
  defp icon_theme(settings) do
    variant = if settings["workbench.colorTheme"] == "light", do: :light, else: :dark

    with id when is_binary(id) <- settings["workbench.iconTheme"],
         {:ok, theme} <- Bee.IconThemes.load(id, variant) do
      theme
    else
      _ -> nil
    end
  end

  defp load_commands(socket) do
    socket
    |> assign(commands: CommandRegistry.commands(), menus: CommandRegistry.menus())
    |> then(&load_keybindings(&1, &1.assigns.keybindings, &1.assigns.keybinding_errors))
  end

  # Bindings of client commands carry their enablement: the browser runs those
  # itself, without a round trip.
  defp load_keybindings(socket, bindings, errors) do
    commands = Map.new(socket.assigns[:commands] || [], &{&1.id, &1})

    client =
      Enum.map(bindings, fn binding ->
        base = Map.take(binding, [:key, :mac, :command, :when])

        case commands[binding.command] do
          %{runtime: :client, enablement_ast: ast} ->
            Map.merge(base, %{client: true, enablement: ast})

          _ ->
            base
        end
      end)

    assign(socket, keybindings: bindings, keybinding_errors: errors, client_keybindings: client)
  end

  ## Menus and palette (rendering helpers)

  defp menubar(assigns) do
    ctx = context(assigns)
    commands = Map.new(assigns.commands, &{&1.id, &1})

    for menu <- assigns.menus do
      items =
        menu.items
        |> Enum.flat_map(fn
          :separator ->
            [:separator]

          %{command: id, when_ast: when_ast} ->
            command = commands[id]

            if command && Bee.Commands.When.eval(when_ast, ctx) do
              [
                %{
                  command: id,
                  label: command.title,
                  shortcut: Keybindings.label(id, assigns.keybindings),
                  disabled: not CommandRegistry.enabled?(command, ctx),
                  checked: CommandRegistry.toggled?(command, ctx)
                }
              ]
            else
              []
            end
        end)
        |> tidy_separators()

      %{id: menu.id, label: menu.label, items: items}
    end
  end

  @doc false
  # Buttons of an icon menu ("editor/title", …): `[%{command, label, icon,
  # disabled}]`, the items whose `when` holds in `ctx` (+ `extra` keys).
  # `inline_only`: just the items of group "inline…" (view/item/context).
  def toolbar(assigns, menu, extra \\ %{}, inline_only \\ false) do
    ctx = Map.merge(context(assigns), extra)
    commands = Map.new(assigns.commands, &{&1.id, &1})

    for %{command: id, when_ast: when_ast, group: group} <- CommandRegistry.menu(menu),
        not inline_only or String.starts_with?(group, "inline"),
        command = commands[id],
        command != nil and Bee.Commands.When.eval(when_ast, ctx) do
      shortcut = Keybindings.label(id, assigns.keybindings)

      %{
        command: id,
        label: if(shortcut, do: "#{command.title} (#{shortcut})", else: command.title),
        icon: command.icon,
        disabled: not CommandRegistry.enabled?(command, ctx)
      }
    end
  end

  @doc false
  # Items of the open context menu: its contributed entries whose `when`
  # holds (the element's keys on top of the window's), grouped like VS
  # Code's – "navigation" first, then by group name – with separators.
  # "inline" groups are buttons, not menu items.
  def context_menu_items(%{context_menu: nil}), do: []

  def context_menu_items(%{context_menu: menu} = assigns) do
    ctx = Map.merge(context(assigns), menu.context)
    commands = Map.new(assigns.commands, &{&1.id, &1})

    menu.menu
    |> CommandRegistry.menu()
    |> Enum.reject(&String.starts_with?(&1.group, "inline"))
    |> Enum.sort_by(&(&1.group != "navigation"))
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn group ->
      for %{command: id, when_ast: when_ast} <- group,
          command = commands[id],
          command != nil and Bee.Commands.When.eval(when_ast, ctx) do
        %{
          command: id,
          label: command.title,
          shortcut: Keybindings.label(id, assigns.keybindings),
          disabled: not CommandRegistry.enabled?(command, ctx)
        }
      end
    end)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([:separator])
    |> List.flatten()
  end

  # No leading, trailing or doubled separators once hidden items are gone.
  defp tidy_separators(items) do
    items
    |> Enum.chunk_by(&(&1 == :separator))
    |> Enum.reject(&(&1 |> hd() == :separator))
    |> Enum.intersperse([:separator])
    |> List.flatten()
  end

  defp palette_items(%{palette: nil}), do: []
  defp palette_items(%{palette: %{mode: :input}}), do: []

  defp palette_items(%{palette: %{mode: :pick, items: items, query: query}}) do
    query = String.downcase(query)

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, i} -> Map.merge(item, %{kind: :pick, key: i}) end)
    |> Enum.filter(&fuzzy_match?(String.downcase(&1.label), query))
  end

  defp palette_items(%{palette: %{mode: :quick_open, query: query}} = assigns) do
    case QuickOpen.mode(query) do
      {:commands, rest} -> command_items(assigns, String.downcase(rest))
      :recent -> mode_items() ++ recent_items(assigns)
      {:files, query} -> file_items(assigns, query)
    end
  end

  defp command_items(assigns, query) do
    ctx = context(assigns)
    hidden = hidden_from_palette(ctx)

    assigns.commands
    |> Enum.filter(&(CommandRegistry.enabled?(&1, ctx) and &1.id not in hidden))
    |> Enum.map(
      &%{
        kind: :command,
        id: &1.id,
        label: CommandRegistry.label(&1),
        shortcut: Keybindings.label(&1.id, assigns.keybindings)
      }
    )
    |> Enum.filter(&fuzzy_match?(String.downcase(&1.label), query))
    # Contiguous matches ("term" in "Terminal") before scattered ones.
    |> Enum.sort_by(&{not String.contains?(String.downcase(&1.label), query), &1.label})
  end

  defp mode_items do
    for %{prefix: prefix, label: label} <- QuickOpen.modes(),
        do: %{kind: :mode, prefix: prefix, label: label, description: prefix}
  end

  defp recent_items(%{quick_open: %{recent: recent}} = assigns) do
    recent
    |> Enum.take(assigns.settings["workbench.quickOpen.recentFiles"] || 10)
    |> Enum.with_index()
    |> Enum.map(fn {path, i} ->
      Map.put(file_item(assigns.root, path), :section, if(i == 0, do: "recently opened"))
    end)
  end

  defp recent_items(_assigns), do: []

  # The finder's latest answer (a newer query's is on its way).
  defp file_items(%{quick_open: %{results: results}} = assigns, _query),
    do: Enum.map(results, &file_item(assigns.root, Path.join(assigns.root, &1)))

  defp file_items(_assigns, _query), do: []

  # Its name, and the folder it is in (relative to the workspace).
  defp file_item(root, path) do
    dir = Path.dirname(Bee.Workspace.FS.relative(root, path))

    %{
      kind: :file,
      path: path,
      label: Path.basename(path),
      description: if(dir == ".", do: "", else: dir)
    }
  end

  # Quick Open's data: the recent files, read when it opens, and a file
  # finder (Bee.Workspace.FileFinder) searching the workspace's files off
  # this process, started with it (unless it opens on commands), stopped
  # when it closes. Its answers come as {:file_finder, …} messages.
  defp sync_quick_open(%{assigns: %{palette: %{mode: :quick_open, query: query}}} = socket) do
    data =
      socket.assigns.quick_open ||
        %{
          recent: RecentFiles.list(socket.assigns.root),
          finder: nil,
          sent: nil,
          results: [],
          results_for: nil,
          loading?: false
        }

    mode = QuickOpen.mode(query)

    data =
      case {data.finder, mode} do
        {nil, {:commands, _}} ->
          data

        {nil, _} ->
          {:ok, finder} = FileFinder.start(socket.assigns.root)
          Process.monitor(finder)
          %{data | finder: finder, loading?: true}

        _ ->
          data
      end

    data =
      case mode do
        {:files, q} when q != data.sent and data.finder != nil ->
          FileFinder.query(data.finder, q)
          %{data | sent: q}

        _ ->
          data
      end

    assign(socket, quick_open: data)
  end

  defp sync_quick_open(%{assigns: %{quick_open: nil}} = socket), do: socket

  defp sync_quick_open(%{assigns: %{quick_open: data}} = socket) do
    if data.finder, do: FileFinder.stop(data.finder)
    assign(socket, quick_open: nil)
  end

  # Quick Open waits for its file finder: listing, or a query not answered yet.
  @doc false
  def quick_open_busy?(%{palette: %{mode: :quick_open, query: query}, quick_open: %{} = data}) do
    case QuickOpen.mode(query) do
      {:files, q} -> data.loading? or data.results_for != q
      _ -> false
    end
  end

  def quick_open_busy?(_assigns), do: false

  # Commands whose "commandPalette" menu entry has a `when` that is false
  # (e.g. commands that need arguments from a view item).
  defp hidden_from_palette(ctx) do
    for %{command: id, when_ast: when_ast} <- CommandRegistry.menu("commandPalette"),
        not Bee.Commands.When.eval(when_ast, ctx),
        do: id
  end

  defp palette_choose(socket, %{kind: :command, id: id}),
    do: socket |> change(&Workbench.close_palette/1) |> run_command(id)

  defp palette_choose(socket, %{kind: :mode, prefix: prefix}),
    do: change(socket, &Workbench.open_quick_open(&1, prefix))

  defp palette_choose(socket, %{kind: :file, path: path}) do
    socket = change(socket, &Workbench.close_palette/1)

    if File.regular?(path) do
      # Already open: switched to (open_buffer records the others).
      if Workbench.open?(workbench(socket), path), do: RecentFiles.add(socket.assigns.root, path)
      change(socket, &Workbench.open_editor(&1, path))
    else
      put_flash(socket, :error, "Cannot open #{path}: no such file")
    end
  end

  defp palette_choose(%{assigns: %{palette: palette}} = socket, item) do
    socket
    |> change(&Workbench.close_palette/1)
    |> run_command(palette.command, palette.arguments ++ [item.value])
  end

  # Every query character appears in order ("tgpan" matches "Toggle Panel").
  defp fuzzy_match?(_label, ""), do: true

  defp fuzzy_match?(label, query) do
    Enum.reduce_while(String.graphemes(query), label, fn char, rest ->
      case String.split(rest, char, parts: 2) do
        [_, rest] -> {:cont, rest}
        [_] -> {:halt, nil}
      end
    end) != nil
  end

  defp problems(assigns),
    do: assigns.settings_errors ++ assigns.keybinding_errors ++ assigns.plugin_errors

  ## Layout

  # Sizes the browser remembered (sent with the connection), so the first
  # connected render already has them.
  defp restore_layout(wb, socket) do
    layout = if connected?(socket), do: get_connect_params(socket)["layout"], else: nil

    case layout do
      %{} ->
        wb =
          Enum.reduce([{"sidebar", :sidebar}, {"panel", :panel}], wb, fn {key, part}, wb ->
            if is_number(layout[key]), do: Workbench.resize(wb, part, layout[key]), else: wb
          end)

        if is_list(layout["activity"]),
          do: Workbench.reorder_activity(wb, layout["activity"]),
          else: wb

      _ ->
        wb
    end
  end

  @doc false
  # The layout's CSS variables. Before the LiveView connects, the sizes the
  # browser saved (root.html.heex) win over the defaults.
  def layout_style(assigns, connected?) do
    if connected? do
      "--sidebar-width: #{assigns.sidebar_width}px; --panel-height: #{assigns.panel_height}px"
    else
      "--sidebar-width: var(--saved-sidebar-width, #{assigns.sidebar_width}px); " <>
        "--panel-height: var(--saved-panel-height, #{assigns.panel_height}px)"
    end
  end

  ## File decorations

  defp load_decorations(socket) do
    root = socket.assigns.root
    decorations = Bee.UI.Decorations.for_workspace(Bee.UI.decorations(root), root)
    assign(socket, file_decorations: decorations)
  end

  # Tabs are coloured like their file in the Explorer (git status…).
  defp tab_color(decorations, root, path) do
    case decorations[Bee.Workspace.FS.relative(root, path)] do
      nil -> nil
      decoration -> BeeWeb.Workbench.Decoration.color_class(decoration)
    end
  end

  ## Status bar

  attr :item, :map, required: true

  # A plugin's status bar item (Bee.UI).
  defp status_item(assigns) do
    ~H"""
    <button
      id={"status-item-#{@item.owner}-#{@item.id}"}
      type="button"
      class={[
        "flex items-center gap-1 px-1 rounded shrink-0",
        @item.command && "cursor-pointer hover:bg-primary-content/15"
      ]}
      title={@item.tooltip}
      disabled={!@item.command}
      phx-click={@item.command && "run_command"}
      phx-value-command={@item.command}
      phx-value-args={@item.command && Jason.encode!(@item.arguments)}
    >
      <BeeWeb.Icons.named_icon :if={@item.icon} name={@item.icon} class="size-3.5" />
      <span>{@item.text}</span>
    </button>
    """
  end

  ## Paths

  # "file — workspace", like VS Code's window title.
  defp window_title(nil, root), do: Path.basename(root)
  defp window_title(active, root), do: "#{Path.basename(active)} — #{Path.basename(root)}"

  # Workspace-relative where possible; settings files get readable names.
  defp display_path(root, path) do
    cond do
      path == Settings.user_path() -> "User Settings"
      path == Keybindings.user_path() -> "Keyboard Shortcuts"
      String.starts_with?(path, root <> "/") -> Path.relative_to(path, root)
      true -> path
    end
  end
end

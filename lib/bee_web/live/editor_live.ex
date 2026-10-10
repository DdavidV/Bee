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
  `bee:exec`, and those of a VS Code extension's code run in the
  workspace's extension host (`Bee.Extensions.Host`), which is told this
  window's active editor and asks its questions here (`{:ask, …}`). The `when` context (`Bee.Workbench.context/2`) is evaluated
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
  alias Bee.Plugins.OpenVsx
  alias Bee.Workbench.{Marketplace, QuickOpen, Search}

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
      Bee.Diagnostics.subscribe(root)
      Bee.Languages.Features.subscribe(root)
      Bee.Webviews.subscribe(root)
      Bee.Output.subscribe(root)
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
     |> assign(grammars: Languages.grammars())
     |> assign(diagnostics: %{}, json_jobs: %{})
     |> assign(language_problems: language_problems(root), language_problems_timer: nil)
     |> assign(language_features: 0, language_gotos: %{}, formats: %{})
     |> assign(renames: %{}, references: nil, code_actions: %{}, problems_hidden: [])
     |> load_webviews()
     |> load_output_channels()
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
     # From a right-click menu, the arguments are the files clicked.
     |> run_command(id, decode_args(params["args"]), params["resource"] == "true")}
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

  ## Open VSX (the Plugins view's search box, Bee.Workbench.Marketplace)

  def handle_event("marketplace_search", %{"query" => query}, socket) when is_binary(query),
    do: {:noreply, change(socket, &Marketplace.update(&1, query))}

  def handle_event("marketplace_more", _params, socket),
    do: {:noreply, change(socket, &Marketplace.more/1)}

  def handle_event("marketplace_retry", _params, socket),
    do: {:noreply, change(socket, &Marketplace.refresh/1)}

  # An Open VSX extension's details failed to load: again.
  def handle_event("openvsx_details_retry", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     socket
     |> update(:extension_details, &Map.delete(&1, id))
     |> sync_extension_details()}
  end

  ## Search view

  ## JSON schemas: completion and hover (Bee.JSONValidation.Assist)

  # From the editor (editor/json_assist.js), which sent its text first;
  # `size`: the text's, to answer only for that text.
  def handle_event(
        "json_assist",
        %{"path" => path, "kind" => kind, "offset" => offset} = params,
        socket
      )
      when kind in ["complete", "hover"] and is_integer(offset) do
    reply =
      with true <- Workbench.open?(workbench(socket), path),
           %{text: text} <-
             (try do
                Buffer.get(path)
              catch
                :exit, _ -> nil
              end),
           true <- byte_size(text) == params["size"] do
        case kind do
          "complete" -> Bee.JSONValidation.Assist.complete(path, text, offset)
          "hover" -> Bee.JSONValidation.Assist.hover(path, text, offset) || %{}
        end
      else
        _ -> %{}
      end

    {:reply, reply, socket}
  end

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
  def handle_event("palette_run", _params, %{assigns: %{palette: %{mode: :input} = p}} = socket),
    do: {:noreply, palette_answer(socket, p, p.query)}

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

  # A panel section's tab was dragged to another place: their container ids.
  def handle_event("reorder_panel", %{"order" => order}, socket) when is_list(order),
    do: {:noreply, change(socket, &Workbench.reorder_panel(&1, order))}

  # A terminal was dragged to another place in the panel's list: their ids.
  def handle_event("reorder_terminals", %{"order" => order}, socket) when is_list(order) do
    ids = for id <- order, {int, ""} <- [Integer.parse(to_string(id))], do: int
    {:noreply, change(socket, &Workbench.reorder_terminals(&1, ids))}
  end

  # A tab was dragged to another place: the tabs' new order (paths).
  def handle_event("reorder_tabs", %{"order" => order}, socket) when is_list(order),
    do: {:noreply, change(socket, &Workbench.reorder_tabs(&1, order))}

  def handle_event("doc_changed", %{"path" => path, "text" => text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      dirty = Buffer.dirty?(Buffer.update(path, text))

      {:noreply,
       socket |> change(&Workbench.set_dirty(&1, path, dirty)) |> validate_json(path, text)}
    else
      {:noreply, socket}
    end
  end

  # Format on save: the file's formatter (an extension's) goes first, and
  # the file is saved when it answered – or didn't in time.
  def handle_event("save", %{"path" => path, "text" => text}, socket) do
    if Workbench.open?(workbench(socket), path) and
         file_settings(socket, path)["editor.formatOnSave"] == true and
         formatter?(socket, path, "formatting") do
      Buffer.update(path, text)
      {:noreply, format(socket, path, :document, true)}
    else
      {:noreply, save_file(socket, path, text)}
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
    socket = assign(socket, selection: {path, ranges})
    if path == socket.assigns.active, do: tell_extension_host(socket)
    {:noreply, socket}
  end

  ## Language features of extensions (Bee.Languages.Features)

  # From the editor (editor/language_features.js), which sent its text
  # first: answered later with language:reply, by `ref`.
  def handle_event(
        "language_request",
        %{"ref" => ref, "feature" => feature, "path" => path} = params,
        socket
      )
      when is_binary(ref) and is_binary(path) do
    if feature in ~w(completion completionResolve completionAccept hover signatureHelp
                     documentHighlight codeAction) and
         Workbench.open?(workbench(socket), path) do
      params = if is_map(params["params"]), do: params["params"], else: %{}
      Bee.Languages.Features.request(socket.assigns.root, feature, path, params, {self(), ref})
      {:noreply, socket}
    else
      {:noreply, push_event(socket, "language:reply", %{ref: ref, result: nil})}
    end
  end

  def handle_event("language_cancel", %{"ref" => ref}, socket) when is_binary(ref) do
    Bee.Languages.Features.cancel(socket.assigns.root, ref)
    {:noreply, socket}
  end

  # Go to Definition and its relatives: the place is opened when it is
  # known (`{:language_reply, ref, …}`), picked first if there are several.
  def handle_event(
        "language_goto",
        %{"feature" => feature, "path" => path, "position" => %{} = position},
        socket
      )
      when feature in ~w(definition typeDefinition declaration implementation references) and
             is_binary(path) do
    if Workbench.open?(workbench(socket), path) do
      ref = make_ref()
      root = socket.assigns.root
      Bee.Languages.Features.request(root, feature, path, %{position: position}, {self(), ref})
      {:noreply, update(socket, :language_gotos, &Map.put(&1, ref, feature))}
    else
      {:noreply, socket}
    end
  end

  # Rename Symbol at a place of the editor: what would be renamed is asked
  # first, then its new name (rename_step/3).
  def handle_event("language_rename", %{"path" => path, "position" => %{} = position}, socket)
      when is_binary(path) do
    if Workbench.open?(workbench(socket), path) do
      ref = make_ref()
      root = socket.assigns.root

      Bee.Languages.Features.request(
        root,
        "prepareRename",
        path,
        %{position: position},
        {self(), ref}
      )

      {:noreply, update(socket, :renames, &Map.put(&1, ref, {:prepare, path, position}))}
    else
      {:noreply, socket}
    end
  end

  # Quick Fix at a range of the editor: its code actions are asked for,
  # then picked from (code_action_step/3).
  def handle_event("language_code_actions", %{"path" => path, "range" => %{} = range}, socket)
      when is_binary(path) do
    if Workbench.open?(workbench(socket), path) do
      ref = make_ref()
      params = %{range: range, context: %{triggerKind: 1}}

      Bee.Languages.Features.request(
        socket.assigns.root,
        "codeAction",
        path,
        params,
        {self(), ref}
      )

      {:noreply, update(socket, :code_actions, &Map.put(&1, ref, :list))}
    else
      {:noreply, socket}
    end
  end

  # A row of the Problems section: its file, at the problem.
  def handle_event("problem_open", %{"index" => index}, socket) do
    case Enum.at(problem_entries(socket.assigns), int(index)) do
      %{path: path, line: line} when is_integer(line) ->
        place = %{
          "path" => path,
          "from" => %{
            "line" => line - 1,
            "character" => (problem_column(socket, int(index)) || 1) - 1
          }
        }

        {:noreply, open_place(socket, place)}

      %{path: path} ->
        {:noreply, change(socket, &Workbench.open_editor(&1, path))}

      nil ->
        {:noreply, socket}
    end
  end

  # Errors, warnings or infos shown or not, in the Problems section.
  def handle_event("problems_filter", %{"severity" => severity}, socket)
      when severity in ~w(error warning info) do
    severity = String.to_existing_atom(severity)

    hidden =
      if severity in socket.assigns.problems_hidden,
        do: List.delete(socket.assigns.problems_hidden, severity),
        else: [severity | socket.assigns.problems_hidden]

    {:noreply, assign(socket, problems_hidden: hidden)}
  end

  # A row of the References section: there.
  def handle_event("reference_open", %{"index" => index}, socket) do
    place = Enum.at(reference_places(socket.assigns.references), int(index))
    {:noreply, if(place, do: open_place(socket, place), else: socket)}
  end

  ## Webview panels of extensions (Bee.Webviews)

  # From a panel's page (the Webview hook): a message for its extension,
  # the state it keeps, a link to open, a key for Bee.
  def handle_event("webview_message", %{"id" => id} = params, socket) when is_binary(id) do
    if Workbench.open?(workbench(socket), "webview:" <> id),
      do: Bee.Extensions.Host.webview(socket.assigns.root, id, {:message, params["message"]})

    {:noreply, socket}
  end

  def handle_event("webview_state", %{"id" => id} = params, socket) when is_binary(id) do
    if Workbench.open?(workbench(socket), "webview:" <> id),
      do: Bee.Webviews.put_state(socket.assigns.root, id, params["state"])

    {:noreply, socket}
  end

  ## Output (Bee.Output): the panel's Output section shows one channel.

  # Its text element is there (the Output hook): the channel's text so far.
  def handle_event("output_ready", _params, socket), do: {:noreply, push_output(socket)}

  def handle_event("output_channel", %{"channel" => channel}, socket),
    do: {:noreply, socket |> assign(output_channel: channel) |> push_output()}

  ## Terminal

  def handle_event("activate_terminal", %{"id" => id}, socket),
    do: {:noreply, change(socket, &Workbench.activate_terminal(&1, String.to_integer(id)))}

  def handle_event("close_terminal", %{"id" => id}, socket),
    do: {:noreply, change(socket, &Workbench.kill_terminal(&1, String.to_integer(id)))}

  def handle_event("term_ready", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    if Workbench.term_view?(workbench(socket), id) do
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
    if Workbench.term_view?(workbench(socket), id), do: Terminal.input(id, data)
    {:noreply, socket}
  end

  def handle_event("term_resize", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    if Workbench.term_view?(workbench(socket), id), do: Terminal.resize(id, cols, rows)
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
        socket = socket |> load_views() |> load_live()

        # The shown container went away with its plugin.
        if Enum.any?(socket.assigns.containers, &(&1.id == socket.assigns.sidebar_view)),
          do: socket,
          else: change(socket, &%{&1 | sidebar_view: "explorer"})
      else
        socket
      end

    socket =
      if :languages in keys,
        do: socket |> assign(grammars: Languages.grammars()) |> redetect_languages(),
        else: socket

    socket =
      if :json_validation in keys or :languages in keys,
        do: validate_open_json(socket),
        else: socket

    socket =
      if :icon_themes in keys,
        do: assign(socket, icon_theme: icon_theme(socket.assigns)),
        else: socket

    socket = if :color_themes in keys, do: sync_theme(socket, true), else: socket

    {:noreply, socket}
  end

  def handle_info(:plugins_changed, socket), do: {:noreply, load_plugins(socket)}

  # Extensions' language features found (or cleared) problems in a file:
  # its editor underlines them; the count follows a moment later (they
  # come in bursts, a file at a time).
  def handle_info({:diagnostics_changed, path}, socket) do
    socket =
      if Workbench.open?(workbench(socket), path),
        do: push_language_diagnostics(socket, path),
        else: socket

    timer =
      socket.assigns.language_problems_timer ||
        Process.send_after(self(), :language_problems, 150)

    {:noreply, assign(socket, language_problems_timer: timer)}
  end

  # Extensions wrote to an output channel (Bee.Output): the shown one's
  # text goes to its element as it comes.
  def handle_info({:output, :appended, channel, text}, socket) do
    if channel == socket.assigns.output_channel and socket.assigns.panel_open,
      do: {:noreply, push_event(socket, "output:append", %{channel: channel, text: text})},
      else: {:noreply, socket}
  end

  def handle_info({:output, :cleared, channel}, socket) do
    if channel == socket.assigns.output_channel,
      do: {:noreply, push_output(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:output, :channels}, socket) do
    before = socket.assigns.output_channel
    socket = load_output_channels(socket)
    # The first channel there is, is shown.
    {:noreply, if(before == nil, do: push_output(socket), else: socket)}
  end

  # A webview panel of an extension (Bee.Webviews): its tab, here too.
  def handle_info({:webview, id, :opened}, socket) do
    case Bee.Webviews.get(socket.assigns.root, id) do
      nil -> {:noreply, socket}
      panel -> {:noreply, show_webview(socket, panel, true)}
    end
  end

  def handle_info({:webview, id, :changed}, socket) do
    case Bee.Webviews.get(socket.assigns.root, id) do
      nil ->
        {:noreply, socket}

      panel ->
        {:noreply,
         socket
         |> update(:webviews, &Map.put(&1, id, panel))
         |> change(&Workbench.set_webview_title(&1, id, panel.title))}
    end
  end

  def handle_info({:webview, id, :revealed}, socket),
    do: {:noreply, change(socket, &Workbench.activate_editor(&1, "webview:" <> id))}

  def handle_info({:webview, id, {:message, message}}, socket),
    do: {:noreply, push_event(socket, "webview:message", %{id: id, message: message})}

  def handle_info({:webview, id, :disposed}, socket) do
    {:noreply,
     socket
     |> update(:webviews, &Map.delete(&1, id))
     |> change(&Workbench.close_editor(&1, "webview:" <> id))}
  end

  # Extensions registered (or took back) language features: each open
  # file's editor is told what there is for it now.
  def handle_info(:language_features_changed, socket) do
    socket =
      Enum.reduce(socket.assigns.tabs, socket, fn
        %{kind: :file, path: path}, socket -> push_language_features(socket, path)
        _other, socket -> socket
      end)

    # (Menus and keybindings depend on them: the editorHas…Provider keys.)
    {:noreply, update(socket, :language_features, &(&1 + 1))}
  end

  # An extension's answer: the editor's (its `ref` is a string), or where
  # Go to Definition leads.
  def handle_info({:language_reply, ref, reply}, socket) when is_binary(ref) do
    result =
      case reply do
        {:ok, result} -> result
        {:error, _message} -> nil
      end

    {:noreply, push_event(socket, "language:reply", %{ref: ref, result: result})}
  end

  def handle_info({:language_reply, ref, reply}, socket) do
    cond do
      Map.has_key?(socket.assigns.formats, ref) ->
        {:noreply, formatted(socket, ref, reply)}

      Map.has_key?(socket.assigns.language_gotos, ref) ->
        {feature, gotos} = Map.pop(socket.assigns.language_gotos, ref)
        {:noreply, go_to(assign(socket, language_gotos: gotos), feature, reply)}

      Map.has_key?(socket.assigns.renames, ref) ->
        {step, renames} = Map.pop(socket.assigns.renames, ref)
        {:noreply, rename_step(assign(socket, renames: renames), step, reply)}

      Map.has_key?(socket.assigns.code_actions, ref) ->
        {step, actions} = Map.pop(socket.assigns.code_actions, ref)
        {:noreply, code_action_step(assign(socket, code_actions: actions), step, reply)}

      symbols_reply?(socket.assigns.quick_open, ref) ->
        {:noreply, symbols_reply(socket, ref, reply)}

      true ->
        {:noreply, socket}
    end
  end

  # The formatter of a file being saved took too long: saved as it is.
  def handle_info({:format_timeout, ref}, socket) do
    if Map.has_key?(socket.assigns.formats, ref) do
      Bee.Languages.Features.cancel(socket.assigns.root, ref)
      {:noreply, formatted(socket, ref, {:ok, nil})}
    else
      {:noreply, socket}
    end
  end

  # Which of several places to go to was picked (see go_to/3).
  def handle_info({:bee_answer, ref, answer}, socket) do
    cond do
      is_list(socket.assigns.language_gotos[ref]) ->
        {places, gotos} = Map.pop(socket.assigns.language_gotos, ref)
        socket = assign(socket, language_gotos: gotos)
        place = is_integer(answer) && Enum.at(places, answer)
        {:noreply, if(place, do: open_place(socket, place), else: socket)}

      # The code action picked.
      Map.has_key?(socket.assigns.code_actions, ref) ->
        {step, actions} = Map.pop(socket.assigns.code_actions, ref)
        {:noreply, code_action_step(assign(socket, code_actions: actions), step, answer)}

      # The new name of Rename Symbol.
      Map.has_key?(socket.assigns.renames, ref) ->
        {step, renames} = Map.pop(socket.assigns.renames, ref)
        {:noreply, rename_step(assign(socket, renames: renames), step, answer)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(:language_problems, socket) do
    {:noreply,
     assign(socket,
       language_problems: language_problems(socket.assigns.root),
       language_problems_timer: nil
     )}
  end

  def handle_info({:json_diagnostics, path, size, diagnostics}, socket) do
    {next, jobs} = Map.pop(socket.assigns.json_jobs, path)
    socket = assign(socket, json_jobs: jobs)
    socket = if next, do: validate_json(socket, path, next), else: socket

    if Workbench.open?(workbench(socket), path) do
      {:noreply,
       socket
       |> update(:diagnostics, &Map.put(&1, path, diagnostics))
       |> push_event("cm:diagnostics", %{
         path: path,
         size: size,
         diagnostics: for(d <- diagnostics, do: Map.take(d, [:from, :to, :severity, :message]))
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:marketplace_results, ref, offset, result}, socket),
    do: {:noreply, change(socket, &Marketplace.results(&1, ref, offset, result))}

  def handle_info({:extension_installed, id, result}, socket) do
    socket = socket |> change(&Marketplace.installed(&1, id)) |> load_plugins()

    case result do
      {:ok, name} ->
        {:noreply, put_flash(socket, :info, "Installed #{id} as the plugin #{name}")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, "Can't install #{id}: #{message}")}
    end
  end

  def handle_info({:openvsx_details, id, result}, socket) do
    details =
      case {socket.assigns.extension_details[id], result} do
        {nil, _} -> nil
        {_, {:ok, details}} -> Map.merge(details, %{source: :openvsx, loading: false, error: nil})
        {old, {:error, message}} -> %{old | loading: false, error: message}
      end

    {:noreply,
     if(details,
       do: update(socket, :extension_details, &Map.put(&1, id, details)),
       else: socket
     )}
  end

  # The Bee Console's window() (Bee.Console.Helpers).
  def handle_info({:bee_console, :window, from, ref}, socket) do
    a = socket.assigns

    send(
      from,
      {ref,
       %{
         root: a.root,
         active: a.active,
         tabs: Enum.map(a.tabs, &Map.take(&1, [:path, :dirty, :lang])),
         sidebar: if(a.sidebar_open, do: a.sidebar_view),
         panel: a.panel_open && Enum.map(a.terminals, & &1.name),
         palette: a.palette && Map.take(a.palette, [:mode, :query]),
         pid: self()
       }}
    )

    {:noreply, socket}
  end

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

      {:noreply,
       socket
       |> push_event("cm:edit", %{path: path, edits: edits, text: text})
       |> validate_json(path, text)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:buffer_reloaded, path, text}, socket) do
    if Workbench.open?(workbench(socket), path) do
      {:noreply,
       socket
       |> change(&Workbench.set_dirty(&1, path, false))
       |> push_event("cm:reload", %{path: path, text: text})
       |> validate_json(path, text)}
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
    before = workbench(socket)
    {wb, effects} = Workbench.wrap(fun.(before))

    socket
    |> put_workbench(wb)
    |> run_effects(effects)
    |> sync_quick_open()
    |> sync_theme()
    |> sync_extension_details()
    |> sync_asked(before)
    |> sync_active_editor(before)
    |> sync_webviews(before)
  end

  # A question asked through the palette (`reply`) that closed, or made way
  # for something else: answered with nothing. (After an answer, that is a
  # second one, which nobody waits for.)
  defp sync_asked(socket, %{palette: %{reply: {pid, ref}}}) do
    case socket.assigns.palette do
      %{reply: {^pid, ^ref}} -> :ok
      _ -> send(pid, {:bee_answer, ref, nil})
    end

    socket
  end

  defp sync_asked(socket, _before), do: socket

  # Another file is shown: what VS Code extensions see as the active editor.
  defp sync_active_editor(socket, before) do
    if Workbench.active_file(before) != Workbench.active_file(workbench(socket)),
      do: tell_extension_host(socket)

    socket
  end

  defp tell_extension_host(socket) do
    ctx = plugin_context(socket.assigns)
    Bee.Extensions.Host.active_editor(ctx.root, self(), ctx.active_editor, ctx.selections)
  end

  # The details of the plugins shown in editor tabs (BeeWeb.Workbench.ExtensionEditor),
  # read when a tab opens and again when plugins change (`reload?`). Tabs of
  # Open VSX extensions ("publisher.name", plugin names have no dots) are
  # fetched once, in a task (`{:openvsx_details, id, result}`).
  defp sync_extension_details(socket, reload? \\ false) do
    cached = socket.assigns[:extension_details] || %{}

    details =
      for %{kind: :extension, name: name} <- socket.assigns.tabs, into: %{} do
        case {String.contains?(name, "."), Map.fetch(cached, name)} do
          {true, {:ok, details}} ->
            {name, details}

          {true, :error} ->
            fetch_openvsx_details(name)
            {name, %{source: :openvsx, id: name, display_name: name, loading: true, error: nil}}

          {false, {:ok, details}} when not reload? ->
            {name, details}

          {false, _} ->
            plugin = Enum.find(socket.assigns[:plugins] || [], &(&1.name == name))
            {name, plugin && Bee.Plugins.Details.get(plugin)}
        end
      end

    assign(socket, extension_details: details)
  end

  defp fetch_openvsx_details(id) do
    window = self()

    Task.Supervisor.start_child(Bee.Plugins.OpenVsx.TaskSup, fn ->
      send(window, {:openvsx_details, id, OpenVsx.details(id)})
    end)
  end

  @doc false
  def run_effects(socket, effects), do: Enum.reduce(effects, socket, &run_effect/2)

  defp run_effect({:push, event, payload}, socket), do: push_event(socket, event, payload)

  defp run_effect({:open_file, path}, socket), do: open_buffer(socket, path)
  defp run_effect({:format, path, what}, socket), do: format(socket, path, what, false)

  defp run_effect({:webview_closed, id}, socket) do
    Bee.Extensions.Host.webview(socket.assigns.root, id, :closed)
    socket
  end

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
    update(socket, :diagnostics, &Map.delete(&1, path))
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

  defp run_effect(:start_console, socket) do
    id = System.unique_integer([:positive])
    Phoenix.PubSub.subscribe(Bee.PubSub, Terminal.topic(id))

    case Bee.Console.start(id: id, owner: self(), root: socket.assigns.root) do
      {:ok, _pid} ->
        change(socket, &Workbench.console_started(&1, id))

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Bee.PubSub, Terminal.topic(id))
        put_flash(socket, :error, "Could not start the Bee Console: #{inspect(reason)}")
    end
  end

  defp run_effect(:clear_output, socket) do
    if channel = socket.assigns.output_channel,
      do: Bee.Output.clear(socket.assigns.root, channel)

    socket
  end

  defp run_effect({:clear_console, id}, socket) do
    Terminal.input(id, <<12>>)
    socket
  end

  # A panel section is shown: its plugins' views need them running.
  defp run_effect({:panel_shown, container}, socket) do
    for view <- socket.assigns.views,
        view.container == container,
        do: Plugins.view_shown(view.id, socket.assigns.root)

    socket
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

  # A command of a VS Code extension's code, run by the workspace's
  # extension host. Files (a right-click menu's arguments, the editor
  # buttons' file) go as `{"$uri": path}`: the extension gets a vscode.Uri.
  defp run_effect(
         {:run_extension_command, %{handler: {:extension, name}, id: id}, args, resources?},
         socket
       ) do
    ctx = plugin_context(socket.assigns)

    args =
      if resources?,
        do: Enum.map(args, &if(is_binary(&1), do: %{"$uri" => &1}, else: &1)),
        else: args

    case Plugins.execute_extension(name, id, %{ctx | args: args}) do
      :ok -> socket
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  defp run_effect(:reload_plugins, socket) do
    Plugins.reload()
    socket |> load_plugins() |> put_flash(:info, "Plugins reloaded")
  end

  # Applied at once (the change notice comes later): a picked color theme
  # replaces the previewed one without showing the old one in between.
  defp run_effect({:update_setting, key, value}, socket) do
    case Settings.update(:user, key, fn _ -> value end) do
      :ok ->
        root = socket.assigns.root
        load_settings(socket, Settings.all(root), Settings.errors(root))

      {:error, message} ->
        put_flash(socket, :error, message)
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

  defp run_effect({:marketplace_search, ref, query, offset}, socket) do
    window = self()

    Task.Supervisor.start_child(Bee.Plugins.OpenVsx.TaskSup, fn ->
      send(window, {:marketplace_results, ref, offset, OpenVsx.search(query, offset: offset)})
    end)

    socket
  end

  defp run_effect({:install_extension, id}, socket) do
    window = self()

    Task.Supervisor.start_child(Bee.Plugins.OpenVsx.TaskSup, fn ->
      result =
        try do
          OpenVsx.install(id)
        rescue
          e -> {:error, Exception.message(e)}
        end

      send(window, {:extension_installed, id, result})
    end)

    socket
  end

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
      |> push_event(
        "cm:open",
        Map.merge(%{path: path, text: buffer.text, lang: lang}, highlight(lang))
      )
      |> validate_json(path, buffer.text)
      |> push_language_diagnostics(path)
      |> push_language_features(path)
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
  defp run_command(socket, id, args \\ [], resources? \\ false) do
    case Enum.find(socket.assigns.commands, &(&1.id == id)) do
      nil ->
        # One a VS Code extension registered without declaring it.
        case Bee.Extensions.Host.command(socket.assigns.root, id) do
          nil ->
            put_flash(socket, :error, "Command '#{id}' not found")

          name ->
            command = %{id: id, handler: {:extension, name}}
            run_effect({:run_extension_command, command, args, resources?}, socket)
        end

      command ->
        cond do
          not CommandRegistry.enabled?(command, context(socket.assigns)) ->
            socket

          command.runtime == :client ->
            run_effect({:exec_client, id, args}, socket)

          match?({:plugin, _}, command.handler) ->
            run_effect({:run_plugin_command, command, args}, socket)

          match?({:extension, _}, command.handler) ->
            run_effect({:run_extension_command, command, args, resources?}, socket)

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
    active = Workbench.active_file(workbench_from(assigns))

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

  defp plugin_request(socket, {:execute_command, id, args}), do: run_command(socket, id, args)

  defp plugin_request(socket, {:set_view_input, view, value}) do
    socket
    |> update(:view_inputs, &Map.put(&1, view, value))
    # The box may have focus, where LiveView leaves its value alone.
    |> push_event("view:input", %{view: view, value: value})
  end

  # A question of the extension host's (Bee.Extensions.Host): asked in the
  # palette, answered with `{:bee_answer, ref, value}` (see palette_answer/3).
  defp plugin_request(socket, {:ask, ref, pid, :pick, spec}),
    do: change(socket, &Workbench.open_quick_pick(&1, Map.put(spec, :reply, {pid, ref})))

  defp plugin_request(socket, {:ask, ref, pid, :input, spec}),
    do: change(socket, &Workbench.open_input_box(&1, Map.put(spec, :reply, {pid, ref})))

  # Answered in another window.
  defp plugin_request(%{assigns: %{palette: %{reply: {_pid, ref}}}} = socket, {:ask_done, ref}),
    do: change(socket, &Workbench.close_palette/1)

  # An extension shows one of its output channels (channel.show()).
  defp plugin_request(socket, {:show_output, channel}) do
    socket
    |> assign(output_channel: channel)
    |> load_output_channels()
    |> change(&Workbench.show_panel(&1, "output"))
    |> push_output()
  end

  # An address for the user's browser (env.openExternal of an extension).
  defp plugin_request(socket, {:open_external, url}),
    do: push_event(socket, "open-external", %{url: url})

  defp plugin_request(socket, {:open_live_editor, spec}),
    do: change(socket, &Workbench.open_live_editor(&1, spec))

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
  defp decode_args(args) when is_list(args), do: args

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
      panel_containers: Bee.Views.containers(:panel),
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
  def visible_views(assigns, container \\ nil) do
    ctx = context(assigns)
    container = container || assigns.sidebar_view

    for view <- assigns.views,
        view.container == container,
        Bee.Commands.When.eval(view.when_ast, ctx),
        do: view
  end

  @doc false
  # The shown views with their header buttons and their items' inline buttons
  # (per item context), for BeeWeb.Workbench.Sidebar.
  def sidebar_views(assigns), do: container_views(assigns, assigns.sidebar_view)

  @doc false
  # The panel's sections (BeeWeb.Workbench.Panel): its containers, with
  # their views like the sidebar's.
  def panel_sections(assigns) do
    for container <- Workbench.sort_containers(assigns.panel_containers, assigns.panel_order),
        do: %{container: container, views: container_views(assigns, container.id)}
  end

  @doc false
  # The panel's own buttons (panel/title): maximize reads "restore" when it is.
  def panel_actions(assigns) do
    for action <- toolbar(assigns, "panel/title") do
      if action.command == "workbench.action.toggleMaximizedPanel" and assigns.panel_maximized,
        do: %{action | icon: "chevron-down", label: "Restore Panel Size"},
        else: action
    end
  end

  defp container_views(assigns, container) do
    for view <- visible_views(assigns, container) do
      contexts =
        case assigns.view_contents[view.id] do
          %{items: items} ->
            item_contexts(items)

          # Bee's Plugins views: their rows (BeeWeb.Workbench.PluginsView).
          _ when view.id in ["workbench.extensions.installed", "workbench.extensions.builtin"] ->
            BeeWeb.Workbench.PluginsView.contexts()

          _ when view.id == "workbench.extensions.marketplace" ->
            BeeWeb.Workbench.MarketplaceView.contexts()

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
    for container <- Workbench.sort_containers(assigns.containers, assigns.activity_order) do
      badge =
        assigns.views
        |> Enum.filter(&(&1.container == container.id))
        |> Enum.map(&((assigns.view_contents[&1.id] || %{})[:badge] || 0))
        |> Enum.sum()

      Map.put(container, :badge, if(badge > 0, do: badge))
    end
  end

  defp load_plugins(socket) do
    socket
    |> assign(
      plugins: Plugins.list(socket.assigns.root),
      plugin_errors: Plugins.errors(socket.assigns.root),
      browser_plugins: Plugins.browser_modules(socket.assigns.root),
      plugin_styles: Plugins.styles(socket.assigns.root),
      marketplace_installed: OpenVsx.installed()
    )
    |> sync_extension_details(true)
    |> load_live()
  end

  # The LiveViews plugins draw their views and editors with
  # (BeeWeb.Workbench.PluginLive): `{:view | :editor, id} => %{plugin, name,
  # module, status, load_id}`, `module` once the plugin's code is loaded.
  defp load_live(socket) do
    plugins = Map.new(socket.assigns[:plugins] || [], &{&1.name, &1})

    declared =
      for(
        %{live: live, source: {:plugin, name}} = v <- Bee.Views.views(),
        live != nil,
        do: {{:view, v.id}, name, live}
      ) ++
        for(
          %{live: live, source: {:plugin, name}} = e <- Bee.Views.editors(),
          do: {{:editor, e.id}, name, live}
        )

    live =
      for {key, name, module_name} <- declared, plugin = plugins[name], into: %{} do
        module =
          with :active <- plugin.status,
               {:ok, module} <- Plugins.live_module(plugin, module_name) do
            module
          else
            _ -> nil
          end

        {key,
         %{
           plugin: name,
           name: module_name,
           module: module,
           status: plugin.status,
           load_id: plugin.load_id
         }}
      end

    # What is on screen needs its plugin running (again, after a reload):
    # open editor tabs, and the views of the shown containers.
    if connected?(socket) do
      shown = [
        socket.assigns[:sidebar_open] && socket.assigns[:sidebar_view],
        socket.assigns[:panel_open] && socket.assigns[:panel_view]
      ]

      on_screen =
        for(%{kind: :live, plugin: name} <- socket.assigns[:tabs] || [], do: name) ++
          for %{live: live, container: container, source: {:plugin, name}} <- Bee.Views.views(),
              live != nil and container in shown,
              do: name

      for name <- Enum.uniq(on_screen),
          match?(%{status: :inactive}, plugins[name]),
          do: Plugins.activate(name, socket.assigns.root)
    end

    assign(socket, live: live)
  end

  ## Languages

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
  defp redetect_languages(socket) do
    Enum.reduce(socket.assigns.tabs, socket, fn
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

  ## `when` context

  @doc false
  def context(assigns) do
    wb = workbench_from(assigns)
    active = Workbench.active_file(wb)

    wb
    |> Workbench.context(assigns.settings)
    |> Map.put(
      "editorHasSelection",
      match?({^active, _}, assigns[:selection]) and active != nil and
        Enum.any?(elem(assigns.selection, 1), fn {from, to} -> from != to end)
    )
    |> Map.merge(language_context(assigns[:root], active))
    |> Map.merge(assigns[:ui_context] || %{})
  end

  # VS Code's editorHas…Provider keys, of the shown file.
  @provider_keys %{
    "completion" => "editorHasCompletionItemProvider",
    "hover" => "editorHasHoverProvider",
    "definition" => "editorHasDefinitionProvider",
    "typeDefinition" => "editorHasTypeDefinitionProvider",
    "declaration" => "editorHasDeclarationProvider",
    "implementation" => "editorHasImplementationProvider",
    "formatting" => "editorHasDocumentFormattingProvider",
    "rangeFormatting" => "editorHasDocumentSelectionFormattingProvider",
    "signatureHelp" => "editorHasSignatureHelpProvider",
    "references" => "editorHasReferenceProvider",
    "rename" => "editorHasRenameProvider",
    "documentSymbol" => "editorHasDocumentSymbolProvider",
    "documentHighlight" => "editorHasDocumentHighlightProvider",
    "codeAction" => "editorHasCodeActionsProvider"
  }

  defp language_context(root, path) when is_binary(root) and is_binary(path) do
    features = Bee.Languages.Features.for_file(root, path)
    Map.new(@provider_keys, fn {feature, key} -> {key, Map.has_key?(features, feature)} end)
  end

  defp language_context(_root, _path), do: %{}

  @doc false
  # The file whose text the editor shows (its right-click menu's argument), or nil.
  def editor_menu(assigns), do: Workbench.active_file(workbench_from(assigns))

  ## Settings / keybindings → assigns

  defp load_settings(socket, settings, errors) do
    socket
    |> assign(
      settings: settings,
      settings_errors: errors,
      editor_settings: %{
        fontSize: settings["editor.fontSize"],
        tabSize: settings["editor.tabSize"],
        wordWrap: settings["editor.wordWrap"],
        lineNumbers: settings["editor.lineNumbers"]
      },
      terminal_settings: %{fontSize: settings["terminal.integrated.fontSize"]}
    )
    |> sync_theme(true)
  end

  ## Color theme

  # The color theme shown: the one selected in the Color Theme pick while
  # it is open (a preview), else workbench.colorTheme's. Loaded again only
  # when that changes, or when `reload?` (settings or themes changed).
  defp sync_theme(socket, reload? \\ false) do
    id = previewed_theme(socket.assigns) || socket.assigns.settings["workbench.colorTheme"]

    if not reload? and socket.assigns[:color_theme_id] == id do
      socket
    else
      theme = Bee.ColorThemes.get(id)
      base = to_string(theme.base)
      colors = theme.custom?

      socket
      |> assign(
        color_theme_id: id,
        color_theme: theme,
        color_theme_css: Bee.ColorThemes.Theme.css(theme, "#workbench"),
        token_colors: Bee.ColorThemes.Theme.token_colors(theme),
        editor_settings:
          Map.merge(socket.assigns.editor_settings, %{theme: base, themeColors: colors}),
        terminal_settings:
          Map.merge(socket.assigns.terminal_settings, %{
            theme: base,
            colors: Bee.ColorThemes.Theme.terminal(theme)
          })
      )
      |> then(&assign(&1, icon_theme: icon_theme(&1.assigns)))
    end
  end

  defp previewed_theme(%{palette: %{mode: :pick, preview: :color_theme, index: index}} = assigns) do
    case Enum.at(palette_items(assigns), index) do
      %{value: id} -> id
      nil -> nil
    end
  end

  defp previewed_theme(_assigns), do: nil

  # The file icon theme picked in workbench.iconTheme, in its variant for
  # the color theme's base; nil (Bee's own icons) when none is set or it
  # isn't loaded (yet).
  defp icon_theme(%{settings: settings, color_theme: color_theme}) do
    with id when is_binary(id) <- settings["workbench.iconTheme"],
         {:ok, theme} <- Bee.IconThemes.load(id, color_theme.base) do
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
        base = Map.take(binding, [:key, :mac, :linux, :win, :command, :when])
        # Sent with run_command (and to client commands) when it has any.
        base =
          if binding.args == nil,
            do: base,
            else: Map.put(base, :args, Keybindings.arguments(binding.args))

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
  # "inline" groups are buttons, not menu items. An item naming a submenu
  # is `%{submenu, label, items}`, its items built the same way (left out
  # when it has none).
  def context_menu_items(%{context_menu: nil}), do: []

  def context_menu_items(%{context_menu: menu} = assigns) do
    env = %{
      ctx: Map.merge(context(assigns), menu.context),
      commands: Map.new(assigns.commands, &{&1.id, &1}),
      submenus: CommandRegistry.submenus(),
      keybindings: assigns.keybindings
    }

    menu_items(menu.menu, env, 0)
  end

  # Submenus nest at most this deep (and can't loop).
  @max_menu_depth 3

  defp menu_items(menu, env, depth) do
    menu
    |> CommandRegistry.menu()
    |> Enum.reject(&String.starts_with?(&1.group, "inline"))
    |> Enum.sort_by(&(&1.group != "navigation"))
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn group ->
      Enum.flat_map(group, fn item ->
        if Bee.Commands.When.eval(item.when_ast, env.ctx),
          do: menu_item(item, env, depth),
          else: []
      end)
    end)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([:separator])
    |> List.flatten()
  end

  defp menu_item(%{command: id}, env, _depth) when is_binary(id) do
    case env.commands[id] do
      nil ->
        []

      command ->
        [
          %{
            command: id,
            label: command.title,
            shortcut: Keybindings.label(id, env.keybindings),
            disabled: not CommandRegistry.enabled?(command, env.ctx),
            runtime: command.runtime
          }
        ]
    end
  end

  defp menu_item(%{submenu: id}, env, depth) when is_binary(id) and depth < @max_menu_depth do
    with %{label: label} <- env.submenus[id],
         [_ | _] = items <- menu_items(id, env, depth + 1) do
      [%{submenu: id, label: label, items: items}]
    else
      _ -> []
    end
  end

  defp menu_item(_item, _env, _depth), do: []

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
      symbols -> symbol_items(assigns, symbols)
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
          loading?: false,
          # Go to Symbol: the file's (asked once), the workspace's (per query).
          symbols: nil,
          symbols_ref: nil,
          symbols_path: nil,
          workspace_symbols: nil,
          workspace_ref: nil,
          workspace_sent: nil
        }

    mode = QuickOpen.mode(query)

    data =
      case {data.finder, mode} do
        {nil, {kind, _}} when kind in [:commands, :symbols, :workspace_symbols] ->
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

    assign(socket, quick_open: sync_symbols(socket, data, mode))
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
      {:symbols, _} -> data.symbols_ref != nil
      {:workspace_symbols, _} -> data.workspace_ref != nil
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

  defp palette_choose(socket, %{kind: :symbol, place: place}),
    do: socket |> change(&Workbench.close_palette/1) |> open_place(place)

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

  defp palette_choose(%{assigns: %{palette: palette}} = socket, item),
    do: palette_answer(socket, palette, item.value)

  # What was picked or typed: to who asked (`reply`), or to the palette's command.
  defp palette_answer(socket, %{reply: {pid, ref}}, value) do
    send(pid, {:bee_answer, ref, value})
    change(socket, &Workbench.close_palette/1)
  end

  defp palette_answer(socket, palette, value) do
    socket
    |> change(&Workbench.close_palette/1)
    |> run_command(palette.command, palette.arguments ++ [value])
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
    do:
      assigns.settings_errors ++
        assigns.keybinding_errors ++
        assigns.plugin_errors ++
        diagnostic_problems(assigns) ++
        for(
          %{severity: severity, path: path, line: line, message: message} <-
            assigns.language_problems,
          severity in [:error, :warning],
          do: %{path: path, message: "line #{line}: #{first_line(message)}"}
        )

  # What extensions' language features found in the workspace's files
  # (Bee.Diagnostics), errors first; hints aren't problems:
  # `[%{path, severity, message, line, column, source}]`.
  defp language_problems(root) do
    for(
      {path, diagnostics} <- Bee.Diagnostics.all(root),
      %{severity: severity} = d when severity in [:error, :warning, :info] <- diagnostics,
      do: %{
        path: path,
        severity: severity,
        message: d.message,
        line: d.from.line + 1,
        column: d.from.character + 1,
        source:
          Enum.join(Enum.reject([d.source, d.code && "(#{d.code})"], &(&1 in [nil, false])), " ")
      }
    )
    |> Enum.sort_by(&{&1.severity != :error, &1.path, &1.line})
  end

  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd()

  # The channels there are; the one shown stays, else the first is.
  defp load_output_channels(socket) do
    channels = Bee.Output.channels(socket.assigns.root)
    shown = socket.assigns[:output_channel]
    shown = if shown in channels, do: shown, else: List.first(channels)
    assign(socket, output_channels: channels, output_channel: shown)
  end

  # The shown channel's whole text, for the Output hook.
  defp push_output(socket) do
    channel = socket.assigns.output_channel
    text = if channel, do: Bee.Output.get(socket.assigns.root, channel), else: ""
    push_event(socket, "output:set", %{channel: channel, text: text})
  end

  # What the editor underlines in `path`.
  defp push_language_diagnostics(socket, path) do
    diagnostics =
      for d <- Bee.Diagnostics.for_file(socket.assigns.root, path),
          do: Map.take(d, [:from, :to, :severity, :message, :source, :code])

    push_event(socket, "cm:language_diagnostics", %{path: path, diagnostics: diagnostics})
  end

  ## Webview panels (Bee.Webviews)

  # The workspace's panels there are already (another window's, or this
  # one's before it was loaded again).
  defp load_webviews(socket) do
    host = socket.host_uri && socket.host_uri.host
    origin = if is_binary(host), do: BeeWeb.WebviewServer.origin(host)
    socket = assign(socket, webviews: %{}, webview_origin: origin)

    if connected?(socket),
      do:
        Enum.reduce(Bee.Webviews.list(socket.assigns.root), socket, &show_webview(&2, &1, false)),
      else: socket
  end

  defp show_webview(socket, panel, activate?) do
    socket
    |> update(:webviews, &Map.put(&1, panel.id, panel))
    |> change(&Workbench.open_webview(&1, panel.id, panel.title, activate?))
  end

  # Tells the extensions which of their panels is shown now.
  defp sync_webviews(socket, before) do
    wb = workbench(socket)

    if before.active != wb.active do
      for %{kind: :webview, webview: id, path: path} <- wb.tabs,
          path in [before.active, wb.active] do
        active? = path == wb.active
        Bee.Extensions.Host.webview(socket.assigns.root, id, {:state, active?, active?})
      end
    end

    socket
  end

  # Which language features there are for `path`, for its editor.
  defp push_language_features(socket, path) do
    features = Bee.Languages.Features.for_file(socket.assigns.root, path)
    push_event(socket, "cm:language_features", %{path: path, features: features})
  end

  defp save_file(socket, path, text) do
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
        put_flash(socket, :error, message)
    end
  end

  ## Formatting (an extension's formatter)

  @format_timeout 3_000

  # The settings as they are for the file: its language's on top
  # ("[elixir]": {…}, Bee.Settings.for_language/2).
  defp file_settings(socket, path) do
    language = Workbench.language(workbench(socket), path)
    Bee.Settings.for_language(socket.assigns.root, language)
  end

  defp formatter?(socket, path, feature),
    do: Map.has_key?(Bee.Languages.Features.for_file(socket.assigns.root, path), feature)

  # Asks the file's formatter for its edits: of the whole text, or of the
  # selection's lines. They are applied when they come (formatted/3), if
  # the text is still the one asked about; `save?`: the file is saved then.
  defp format(socket, path, what, save?) do
    root = socket.assigns.root
    text = Bee.API.text(path)
    feature = if what == :selection, do: "rangeFormatting", else: "formatting"

    if is_binary(text) and formatter?(socket, path, feature) do
      ref = make_ref()
      settings = file_settings(socket, path)

      params =
        Map.merge(
          %{
            options: %{tabSize: settings["editor.tabSize"] || 2, insertSpaces: true},
            formatter: settings["editor.defaultFormatter"]
          },
          if(what == :selection, do: %{range: selected_range(socket, path, text)}, else: %{})
        )

      Bee.Languages.Features.request(root, feature, path, params, {self(), ref})
      if save?, do: Process.send_after(self(), {:format_timeout, ref}, @format_timeout)
      format = %{path: path, hash: :erlang.phash2(text), save?: save?}
      update(socket, :formats, &Map.put(&1, ref, format))
    else
      change(socket, &Workbench.set_status(&1, "No formatter for this file"))
    end
  end

  # The first selection of the file's editor as positions (the cursor's
  # place when there is none).
  defp selected_range(socket, path, text) do
    {from, to} =
      case socket.assigns.selection do
        {^path, [{from, to} | _]} -> {min(from, to), max(from, to)}
        _ -> {0, 0}
      end

    %{
      from: Bee.Extensions.Host.bytes_to_position(text, from),
      to: Bee.Extensions.Host.bytes_to_position(text, to)
    }
  end

  defp formatted(socket, ref, reply) do
    {%{path: path, hash: hash, save?: save?}, formats} = Map.pop(socket.assigns.formats, ref)
    socket = assign(socket, formats: formats)
    text = Bee.API.text(path)

    socket =
      case reply do
        {:ok, %{"edits" => [_ | _] = edits}} when is_binary(text) ->
          if :erlang.phash2(text) == hash do
            edits =
              for %{"from" => from, "to" => to, "text" => insert} <- edits do
                {Bee.Extensions.Host.position_to_bytes(text, from),
                 Bee.Extensions.Host.position_to_bytes(text, to), insert}
              end

            case Bee.API.edit(path, edits) do
              :ok -> socket
              _ -> put_flash(socket, :error, "The formatter's changes couldn't be applied")
            end
          else
            # Typed in since: its changes are for another text.
            socket
          end

        {:error, message} ->
          put_flash(socket, :error, "Formatting failed: #{message}")

        _ ->
          socket
      end

    if save? and is_binary(Bee.API.text(path)),
      do: save_file(socket, path, Bee.API.text(path)),
      else: socket
  end

  ## Quick Fix (code actions)

  # What can be done there: picked from in the palette, the preferred first.
  defp code_action_step(
         socket,
         :list,
         {:ok, %{"session" => session, "actions" => [_ | _] = actions}}
       ) do
    ref = make_ref()
    actions = Enum.sort_by(actions, &(not &1["preferred"]))

    items =
      for {action, index} <- Enum.with_index(actions) do
        %{
          label: action["title"],
          description:
            cond do
              action["disabled"] -> "can't be done: #{action["disabled"]}"
              action["preferred"] -> "preferred"
              true -> ""
            end,
          value: index
        }
      end

    socket
    |> update(:code_actions, &Map.put(&1, ref, {:pick, session, actions}))
    |> plugin_request({:ask, ref, self(), :pick, %{placeholder: "Quick Fix…", items: items}})
  end

  defp code_action_step(socket, :list, {:error, message}),
    do: put_flash(socket, :error, "Quick Fix: #{message}")

  defp code_action_step(socket, :list, _none),
    do: change(socket, &Workbench.set_status(&1, "No code actions available"))

  defp code_action_step(socket, {:pick, session, actions}, index) when is_integer(index) do
    case Enum.at(actions, index) do
      %{"disabled" => reason, "title" => title} when is_binary(reason) ->
        put_flash(socket, :error, "#{title}: #{reason}")

      %{"index" => action, "title" => title} ->
        ref = make_ref()
        params = %{session: session, index: action}

        Bee.Languages.Features.request(
          socket.assigns.root,
          "codeActionApply",
          nil,
          params,
          {self(), ref}
        )

        update(socket, :code_actions, &Map.put(&1, ref, {:apply, title}))

      nil ->
        socket
    end
  end

  # (Dismissed.)
  defp code_action_step(socket, {:pick, _session, _actions}, _nothing), do: socket

  defp code_action_step(socket, {:apply, title}, {:ok, %{"error" => message}}),
    do: put_flash(socket, :error, "#{title}: #{message}")

  defp code_action_step(socket, {:apply, title}, {:error, message}),
    do: put_flash(socket, :error, "#{title}: #{message}")

  defp code_action_step(socket, {:apply, _title}, _done), do: socket

  ## Problems (the panel's section)

  # Every problem there is, as the Problems section lists them: Bee's own
  # (settings, keybindings, plugins: no place), JSON validation's and the
  # extensions' diagnostics. `%{path, severity, message, line, column, source}`,
  # by file, errors first in each.
  @doc false
  def problem_entries(assigns) do
    own =
      for %{path: path, message: message} <-
            assigns.settings_errors ++ assigns.keybinding_errors ++ assigns.plugin_errors do
        %{path: path, severity: :error, message: message, line: nil, column: nil, source: "Bee"}
      end

    json =
      for {path, diagnostics} <- assigns[:diagnostics] || %{}, d <- diagnostics do
        %{
          path: path,
          severity: if(d[:severity] in [:warning, "warning"], do: :warning, else: :error),
          message: d.message,
          line: d.line,
          column: nil,
          source: "JSON"
        }
      end

    Enum.sort_by(own ++ json ++ assigns.language_problems, fn p ->
      {p.path, Enum.find_index([:error, :warning, :info], &(&1 == p.severity)), p.line || 0}
    end)
  end

  defp problem_column(socket, index) do
    with %{column: column} <- Enum.at(problem_entries(socket.assigns), index), do: column
  end

  ## Rename Symbol

  # What is renamed is known: asks for its new name, in the palette.
  defp rename_step(socket, {:prepare, path, position}, {:ok, %{"placeholder" => old}})
       when is_binary(old) do
    ref = make_ref()

    socket
    |> update(:renames, &Map.put(&1, ref, {:name, path, position, old}))
    |> plugin_request(
      {:ask, ref, self(), :input,
       %{prompt: "Rename Symbol: a new name for #{old}", placeholder: old, value: old}}
    )
  end

  defp rename_step(socket, {:prepare, _path, _position}, {:ok, %{"error" => message}}),
    do: put_flash(socket, :error, to_string(message))

  defp rename_step(socket, {:prepare, _path, _position}, {:error, message}),
    do: put_flash(socket, :error, "Rename Symbol: #{message}")

  defp rename_step(socket, {:prepare, _path, _position}, _none),
    do: change(socket, &Workbench.set_status(&1, "Nothing to rename here"))

  # The new name: renamed, in every file it is in.
  defp rename_step(socket, {:name, path, position, old}, name) when is_binary(name) do
    name = String.trim(name)

    if name in ["", old] do
      socket
    else
      ref = make_ref()
      params = %{position: position, newName: name}
      Bee.Languages.Features.request(socket.assigns.root, "rename", path, params, {self(), ref})
      update(socket, :renames, &Map.put(&1, ref, {:apply, old, name}))
    end
  end

  # (Dismissed.)
  defp rename_step(socket, {:name, _path, _position, _old}, _nothing), do: socket

  defp rename_step(socket, {:apply, old, name}, {:ok, %{"applied" => true} = done}) do
    places = "#{done["edits"]} #{if done["edits"] == 1, do: "place", else: "places"}"
    files = "#{done["files"]} #{if done["files"] == 1, do: "file", else: "files"}"
    change(socket, &Workbench.set_status(&1, "Renamed #{old} to #{name}: #{places} in #{files}"))
  end

  defp rename_step(socket, {:apply, _old, _name}, {:ok, %{"error" => message}}),
    do: put_flash(socket, :error, "Rename Symbol: #{message}")

  defp rename_step(socket, {:apply, _old, _name}, {:error, message}),
    do: put_flash(socket, :error, "Rename Symbol: #{message}")

  defp rename_step(socket, {:apply, old, _name}, _other),
    do: put_flash(socket, :error, "Rename Symbol: #{old} couldn't be renamed")

  ## References (the panel's section)

  # Every place a symbol is (`[%{"path", "from", "to"}]`), by file, each
  # with its line's text around the place: `%{count, files: [%{path, rows:
  # [%{index, line, before, match, after}]}]}`; `index` among all places.
  defp show_references(socket, [_ | _] = places) do
    root = socket.assigns.root

    files =
      places
      |> Enum.with_index()
      |> Enum.group_by(fn {place, _} -> place["path"] end)
      |> Enum.sort_by(fn {path, _} -> display_path(root, path) end)
      |> Enum.map(fn {path, entries} ->
        lines = path |> place_text() |> String.split("\n")
        %{path: path, rows: Enum.map(entries, &reference_row(&1, lines))}
      end)

    socket
    |> assign(references: %{count: length(places), files: files, places: places})
    |> change(&Workbench.show_panel(&1, "references"))
  end

  defp show_references(socket, _none),
    do: change(socket, &Workbench.set_status(&1, "No references found"))

  defp reference_row({%{"from" => from, "to" => to} = _place, index}, lines) do
    text = String.trim_trailing(Enum.at(lines, from["line"], ""), "\r")
    start = Bee.Extensions.Host.to_bytes(text, from["character"])

    stop =
      if to["line"] == from["line"],
        do: max(start, Bee.Extensions.Host.to_bytes(text, to["character"])),
        else: byte_size(text)

    before = binary_part(text, 0, start)

    %{
      index: index,
      line: from["line"] + 1,
      # (Its indentation says nothing here.)
      before: String.trim_leading(before),
      match: binary_part(text, start, stop - start),
      after: binary_part(text, stop, byte_size(text) - stop)
    }
  end

  defp reference_places(%{places: places}), do: places
  defp reference_places(_none), do: []

  ## Go to Symbol (Quick Open's @ and # modes)

  # Asks for what the query's mode lists, once per file (@) or query (#):
  # the answers come as {:language_reply, ref, …} (symbols_reply/3).
  defp sync_symbols(socket, data, {:symbols, _query}) do
    path = Workbench.active_file(workbench(socket))

    if data.symbols_ref == nil and data.symbols == nil and path != nil do
      ref = make_ref()

      Bee.Languages.Features.request(
        socket.assigns.root,
        "documentSymbol",
        path,
        %{},
        {self(), ref}
      )

      %{data | symbols_ref: ref, symbols_path: path}
    else
      data
    end
  end

  defp sync_symbols(socket, data, {:workspace_symbols, query}) do
    if query != data.workspace_sent do
      ref = make_ref()
      params = %{query: query}

      Bee.Languages.Features.request(
        socket.assigns.root,
        "workspaceSymbol",
        nil,
        params,
        {self(), ref}
      )

      %{data | workspace_ref: ref, workspace_sent: query}
    else
      data
    end
  end

  defp sync_symbols(_socket, data, _mode), do: data

  defp symbols_reply?(%{symbols_ref: ref}, ref) when ref != nil, do: true
  defp symbols_reply?(%{workspace_ref: ref}, ref) when ref != nil, do: true
  defp symbols_reply?(_data, _ref), do: false

  defp symbols_reply(%{assigns: %{quick_open: data}} = socket, ref, reply) do
    symbols =
      case reply do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    data =
      if data.symbols_ref == ref,
        do: %{data | symbols_ref: nil, symbols: symbols},
        else: %{data | workspace_ref: nil, workspace_symbols: symbols}

    assign(socket, quick_open: data)
  end

  # The file's symbols matching the query, in file order, nested ones
  # indented; the workspace's, as its extensions found them for the query.
  defp symbol_items(%{quick_open: %{symbols: symbols, symbols_path: path}}, {:symbols, query})
       when is_list(symbols) do
    query = String.downcase(String.trim(query))

    for %{"name" => name} = symbol <- symbols, fuzzy_match?(String.downcase(name), query) do
      %{
        kind: :symbol,
        label: String.duplicate("  ", if(query == "", do: symbol["depth"] || 0, else: 0)) <> name,
        description:
          Enum.join(Enum.reject([symbol["kind"], symbol["detail"]], &(&1 in [nil, ""])), " · "),
        section: "line #{symbol["from"]["line"] + 1}",
        place: %{"path" => path, "from" => symbol["from"]}
      }
    end
  end

  defp symbol_items(
         %{quick_open: %{workspace_symbols: symbols}} = assigns,
         {:workspace_symbols, _}
       )
       when is_list(symbols) do
    for %{"name" => name, "path" => path} = symbol <- symbols do
      %{
        kind: :symbol,
        label: name,
        description:
          Enum.join(Enum.reject([symbol["kind"], symbol["container"]], &(&1 in [nil, ""])), " · "),
        section: "#{display_path(assigns.root, path)}:#{symbol["from"]["line"] + 1}",
        place: %{"path" => path, "from" => symbol["from"]}
      }
    end
  end

  defp symbol_items(_assigns, _mode), do: []

  @goto_names %{
    "definition" => "definition",
    "typeDefinition" => "type definition",
    "declaration" => "declaration",
    "implementation" => "implementation"
  }

  # Where a symbol is defined (`[%{"path", "from", "to"}]`): there, or
  # picked among them in the palette.
  defp go_to(socket, "references", {:ok, places}) when is_list(places),
    do: show_references(socket, places)

  defp go_to(socket, "references", {:error, message}),
    do: put_flash(socket, :error, "Find All References: #{message}")

  defp go_to(socket, "references", _none), do: show_references(socket, [])

  defp go_to(socket, _feature, {:ok, [place]}), do: open_place(socket, place)

  defp go_to(socket, feature, {:ok, [_ | _] = places}) do
    root = socket.assigns.root
    ref = make_ref()

    items =
      for {%{"path" => path, "from" => from}, index} <- Enum.with_index(places) do
        %{
          label: "#{display_path(root, path)}:#{from["line"] + 1}",
          description: place_line(path, from["line"]),
          value: index
        }
      end

    socket
    |> update(:language_gotos, &Map.put(&1, ref, places))
    |> plugin_request(
      {:ask, ref, self(), :pick, %{placeholder: "Go to #{@goto_names[feature]}", items: items}}
    )
  end

  defp go_to(socket, feature, {:error, message}),
    do: put_flash(socket, :error, "Go to #{@goto_names[feature]}: #{message}")

  defp go_to(socket, feature, _none),
    do: change(socket, &Workbench.set_status(&1, "No #{@goto_names[feature]} found"))

  defp open_place(socket, %{"path" => path, "from" => from}) do
    at = Bee.Extensions.Host.position_to_bytes(place_text(path), from)
    plugin_request(socket, {:open_file, path, %{from: at, to: at}})
  end

  # A file's text as its editor has it (unsaved, if open).
  defp place_text(path) do
    case Bee.API.text(path) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp place_line(path, line) do
    path |> place_text() |> String.split("\n") |> Enum.at(line, "") |> String.trim()
  end

  defp diagnostic_problems(assigns) do
    for {path, diagnostics} <- Enum.sort(assigns[:diagnostics] || %{}),
        d <- diagnostics,
        do: %{path: path, message: "line #{d.line}: #{d.message}"}
  end

  ## JSON validation (Bee.JSONValidation)
  #
  # A JSON file's diagnostics – syntax, and its schemas' errors – are found
  # in a task, one at a time per file: text arriving meanwhile waits for
  # it (`json_jobs`: path => nil, or the text to validate next). They go to
  # the editor (cm:diagnostics, with the size of the text they're for) and
  # to the problems.

  defp validate_json(socket, path, text) do
    lang = Workbench.language(workbench(socket), path)

    cond do
      not Bee.JSONValidation.language?(lang) ->
        socket

      Map.has_key?(socket.assigns.json_jobs, path) ->
        update(socket, :json_jobs, &Map.put(&1, path, text))

      true ->
        window = self()

        Task.Supervisor.start_child(Bee.JSONValidation.TaskSup, fn ->
          diagnostics =
            try do
              Bee.JSONValidation.validate(path, text)
            rescue
              e ->
                require Logger
                Logger.error("validating #{path}: #{Exception.message(e)}")
                []
            end

          send(window, {:json_diagnostics, path, byte_size(text), diagnostics})
        end)

        update(socket, :json_jobs, &Map.put(&1, path, nil))
    end
  end

  # Schemas changed: every open JSON file again.
  defp validate_open_json(socket) do
    Enum.reduce(socket.assigns.tabs, socket, fn
      %{kind: :file, path: path}, socket ->
        case Buffer.get(path) do
          %{text: text} -> validate_json(socket, path, text)
          _ -> socket
        end

      _tab, socket ->
        socket
    end)
  catch
    :exit, _ -> socket
  end

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

        wb =
          if is_list(layout["activity"]),
            do: Workbench.reorder_activity(wb, layout["activity"]),
            else: wb

        if is_list(layout["panelSections"]),
          do: Workbench.reorder_panel(wb, layout["panelSections"]),
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

  @doc false
  # `when` keys of a tab's right-click menu (editor/title/context).
  def tab_menu_context(%{kind: :file, path: path}) do
    %{
      "resourceScheme" => "file",
      "resourcePath" => path,
      "resourceFilename" => Path.basename(path),
      "resourceExtname" => Path.extname(path)
    }
  end

  def tab_menu_context(_tab), do: %{"resourceScheme" => "extension"}

  # A tab's name: the file's, or "Extension: <plugin>".
  defp tab_label(%{kind: :file, path: path}, _details), do: Path.basename(path)

  defp tab_label(%{kind: :live, title: title}, _details), do: title
  defp tab_label(%{kind: :webview, title: title}, _details), do: title

  defp tab_label(%{kind: :extension, name: name}, details),
    do: "Extension: " <> ((details[name] && details[name].display_name) || name)

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
        @item.command && "cursor-pointer hover:bg-statusbar-fg/15"
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
  defp window_title(label, root), do: "#{label} — #{Path.basename(root)}"

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

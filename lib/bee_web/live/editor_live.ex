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

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Workspace.subscribe()
      Buffer.subscribe()
      Settings.subscribe()
      Keybindings.subscribe()
      CommandRegistry.subscribe()
      Plugins.subscribe()
      Bee.API.subscribe_window()
      Bee.UI.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: Path.basename(Workspace.root()), term_seq: %{}, selection: nil)
     |> assign(view_inputs: %{}, collapsed: MapSet.new())
     |> load_views()
     |> assign(status_items: Bee.UI.status_items())
     |> put_workbench(Workbench.new(Workspace.root()))
     |> load_settings(Settings.all(), Settings.errors())
     |> assign(keybindings: Keybindings.all(), keybinding_errors: Keybindings.errors())
     |> load_commands()
     |> load_plugins()}
  end

  ## Commands

  # `args`: optional JSON array (view items, buttons with arguments).
  @impl true
  def handle_event("run_command", %{"command" => id} = params, socket) do
    {:noreply,
     socket
     |> change(&(&1 |> Workbench.close_menu() |> Workbench.close_palette()))
     |> run_command(id, decode_args(params["args"]))}
  end

  ## Sidebar views

  # Activity bar: show a container's views (or hide the sidebar, VS Code style).
  def handle_event("show_view", %{"container" => id}, socket) do
    socket = change(socket, &Workbench.show_view(&1, id))
    if socket.assigns.sidebar_open, do: views_shown(socket)
    {:noreply, socket}
  end

  def handle_event("toggle_view_item", %{"view" => view, "item" => item}, socket) do
    key = {view, item}

    collapsed =
      if MapSet.member?(socket.assigns.collapsed, key),
        do: MapSet.delete(socket.assigns.collapsed, key),
        else: MapSet.put(socket.assigns.collapsed, key)

    {:noreply, assign(socket, collapsed: collapsed)}
  end

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
      if path in Settings.paths(), do: Settings.reload()
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
    case Workspace.resolve(rel) do
      {:ok, abs} -> {:noreply, change(socket, &Workbench.open_editor(&1, abs))}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Path outside workspace")}
    end
  end

  def handle_info({:fs_changed, path}, socket) do
    send_update(BeeWeb.Workbench.FileTree, id: "explorer", fs_changed: path)
    {:noreply, socket}
  end

  def handle_info({:settings_changed, settings, errors}, socket) do
    old = socket.assigns.settings

    if settings["files.exclude"] != old["files.exclude"],
      do: send_update(BeeWeb.Workbench.FileTree, id: "explorer", refresh: true)

    socket = load_settings(socket, settings, errors)

    if settings["files.associations"] != old["files.associations"],
      do: {:noreply, redetect_languages(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:keybindings_changed, bindings, errors}, socket),
    do: {:noreply, load_keybindings(socket, bindings, errors)}

  def handle_info({:ui_changed, {:view, id}}, socket),
    do: {:noreply, update(socket, :view_contents, &Map.put(&1, id, Bee.UI.view(id)))}

  def handle_info({:ui_changed, :status_items}, socket),
    do: {:noreply, assign(socket, status_items: Bee.UI.status_items())}

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
    {:noreply, socket}
  end

  def handle_info(:plugins_changed, socket), do: {:noreply, load_plugins(socket)}

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
    socket |> put_workbench(wb) |> run_effects(effects)
  end

  @doc false
  def run_effects(socket, effects), do: Enum.reduce(effects, socket, &run_effect/2)

  defp run_effect({:push, event, payload}, socket), do: push_event(socket, event, payload)

  defp run_effect({:open_file, path}, socket) do
    case Buffer.open(path) do
      {:ok, buffer} ->
        lang = Languages.detect(path, first_line: Languages.first_line(buffer.text))

        socket
        |> change(&Workbench.editor_opened(&1, path, Buffer.dirty?(buffer), lang))
        |> push_event("cm:open", %{
          path: path,
          text: buffer.text,
          lang: lang,
          mode: Languages.mode(lang)
        })

      {:error, reason} ->
        message = "Cannot open #{display_path(socket.assigns.root, path)}: #{inspect(reason)}"
        put_flash(socket, :error, message)
    end
  end

  defp run_effect({:close_buffer, path}, socket) do
    Buffer.close(path)
    socket
  end

  defp run_effect(:new_terminal, socket) do
    id = System.unique_integer([:positive])
    shell = Terminal.default_shell()
    Phoenix.PubSub.subscribe(Bee.PubSub, Terminal.topic(id))

    case Terminal.start(id: id, owner: self(), shell: shell) do
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

  defp run_effect({:flash, kind, message}, socket), do: put_flash(socket, kind, message)

  ## Command execution

  # `args` reach plugin and client commands; Bee's own server commands
  # don't take any.
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
            change(socket, fn wb -> apply_handler(command.handler, wb) end)
        end
    end
  end

  defp apply_handler({module, fun}, wb), do: apply(module, fun, [wb])

  ## Plugins

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
      view_contents: Map.new(views, &{&1.id, Bee.UI.view(&1.id)})
    )
  end

  # The shown container's plugin views need their plugin running.
  defp views_shown(socket) do
    for view <- socket.assigns.views,
        view.container == socket.assigns.sidebar_view,
        do: Plugins.view_shown(view.id)

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
          %{items: items} -> item_contexts(items)
          _ -> []
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
    for container <- assigns.containers do
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
      plugins: Plugins.list(),
      plugin_errors: Plugins.errors(),
      browser_plugins: Plugins.browser_modules()
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
  def context(assigns), do: assigns |> workbench_from() |> Workbench.context(assigns.settings)

  ## Settings / keybindings → assigns

  defp load_settings(socket, settings, errors) do
    assign(socket,
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
    |> Enum.map(fn {item, i} -> Map.merge(item, %{id: nil, key: i, shortcut: nil}) end)
    |> Enum.filter(&fuzzy_match?(String.downcase(&1.label), query))
  end

  defp palette_items(assigns) do
    ctx = context(assigns)
    query = String.downcase(assigns.palette.query)
    hidden = hidden_from_palette(ctx)

    assigns.commands
    |> Enum.filter(&(CommandRegistry.enabled?(&1, ctx) and &1.id not in hidden))
    |> Enum.map(
      &%{
        id: &1.id,
        label: CommandRegistry.label(&1),
        shortcut: Keybindings.label(&1.id, assigns.keybindings)
      }
    )
    |> Enum.filter(&fuzzy_match?(String.downcase(&1.label), query))
    # Contiguous matches ("term" in "Terminal") before scattered ones.
    |> Enum.sort_by(&{not String.contains?(String.downcase(&1.label), query), &1.label})
  end

  # Commands whose "commandPalette" menu entry has a `when` that is false
  # (e.g. commands that need arguments from a view item).
  defp hidden_from_palette(ctx) do
    for %{command: id, when_ast: when_ast} <- CommandRegistry.menu("commandPalette"),
        not Bee.Commands.When.eval(when_ast, ctx),
        do: id
  end

  defp palette_choose(socket, %{id: id}) when is_binary(id),
    do: socket |> change(&Workbench.close_palette/1) |> run_command(id)

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

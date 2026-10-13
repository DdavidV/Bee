defmodule BeeWeb.EditorLive.Effects do
  @moduledoc """
  Performs the effects `Bee.Workbench` functions and command handlers ask
  for (see `Bee.Workbench`): buffers, files, terminals, searches, plugins,
  settings, browser events.
  """

  use BeeWeb, :verified_routes

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Plugins
  alias Bee.Settings
  alias Bee.Terminal
  alias Bee.Workbench
  alias Bee.Editor.Buffer
  alias Bee.Workspace.Files
  alias Bee.Plugins.OpenVsx
  alias Bee.Workbench.Search
  alias BeeWeb.EditorLive.{Config, Editors, Extensions, Formatting, Notifications, Terminals}

  def run_effects(socket, effects), do: Enum.reduce(effects, socket, &run_effect/2)

  def run_effect({:push, event, payload}, socket), do: push_event(socket, event, payload)

  def run_effect({:open_file, path}, socket), do: Editors.open_buffer(socket, path)

  def run_effect({:open_file, path, :preview}, socket),
    do: Editors.open_buffer(socket, path, nil, true)

  def run_effect({:open_file, path, :replace}, socket),
    do: Editors.open_buffer(socket, path, nil, :replace)

  def run_effect({:format, path, what}, socket), do: Formatting.format(socket, path, what, false)

  def run_effect({:webview_closed, id}, socket) do
    Bee.Extensions.Host.webview(socket.assigns.root, id, :closed)
    socket
  end

  def run_effect({:diff_closed, id}, socket) do
    Bee.Extensions.Host.diff(socket.assigns.root, id, :closed)
    update(socket, :diffs, &Map.delete(&1, id))
  end

  def run_effect({:explorer_edit, edit}, socket) do
    send_update(BeeWeb.Workbench.FileTree, id: "explorer", edit: edit)
    socket
  end

  def run_effect({:delete_file, path}, socket) do
    case Files.delete(socket.assigns.root, path) do
      {:ok, path} -> socket |> Editors.files_deleted(path) |> Editors.files_changed()
      {:error, message} -> Notifications.notify(socket, :error, message)
    end
  end

  def run_effect({:paste_files, op, paths, dir}, socket) do
    case Files.paste(socket.assigns.root, paths, dir, op) do
      {:ok, pairs} ->
        socket = Editors.files_changed(socket)
        if op == :cut, do: Editors.files_moved(socket, pairs), else: socket

      {:error, message} ->
        socket |> Editors.files_changed() |> Notifications.notify(:error, message)
    end
  end

  def run_effect({:close_buffer, path}, socket) do
    Buffer.close(path)
    update(socket, :diagnostics, &Map.delete(&1, path))
  end

  def run_effect(:new_terminal, socket) do
    case Terminals.start(socket, %{}) do
      {:ok, id, name} ->
        change(socket, &Workbench.terminal_started(&1, id, name))

      {:error, reason} ->
        Notifications.notify(socket, :error, "Could not start terminal: #{inspect(reason)}")
    end
  end

  def run_effect(:start_console, socket) do
    id = System.unique_integer([:positive])
    Phoenix.PubSub.subscribe(Bee.PubSub, Terminal.topic(id))

    case Bee.Console.start(id: id, owner: self(), root: socket.assigns.root) do
      {:ok, _pid} ->
        change(socket, &Workbench.console_started(&1, id))

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Bee.PubSub, Terminal.topic(id))

        Notifications.notify(
          socket,
          :error,
          "Could not start the Bee Console: #{inspect(reason)}"
        )
    end
  end

  def run_effect(:clear_output, socket) do
    if channel = socket.assigns.output_channel,
      do: Bee.Output.clear(socket.assigns.root, channel)

    socket
  end

  def run_effect({:clear_console, id}, socket) do
    Terminal.input(id, <<12>>)
    socket
  end

  # A panel section is shown: its plugins' views need them running.
  def run_effect({:panel_shown, container}, socket) do
    for view <- socket.assigns.views,
        view.container == container,
        do: Plugins.view_shown(view.id, socket.assigns.root)

    socket
  end

  def run_effect({:stop_terminal, id}, socket) do
    Terminal.stop(id)
    run_effect({:forget_terminal, id}, socket)
  end

  def run_effect({:forget_terminal, id}, socket) do
    Phoenix.PubSub.unsubscribe(Bee.PubSub, Terminal.topic(id))
    Terminals.put_term_seq(socket, Map.delete(Terminals.term_seq(socket), id))
  end

  # The xterm views were unmounted; they re-attach via term_ready.
  def run_effect(:panel_hidden, socket), do: Terminals.put_term_seq(socket, %{})

  def run_effect({:exec_client, command}, socket),
    do: run_effect({:exec_client, command, []}, socket)

  def run_effect({:exec_client, command, args}, socket),
    do: push_event(socket, "bee:exec", %{command: command, args: args})

  def run_effect({:run_plugin_command, %{handler: {:plugin, name}, id: id}, args}, socket) do
    case Plugins.execute(name, id, %{plugin_context(socket.assigns) | args: args}) do
      :ok -> socket
      {:error, message} -> Notifications.notify(socket, :error, message)
    end
  end

  # A command of a VS Code extension's code, run by the workspace's
  # extension host. Files (a right-click menu's arguments, the editor
  # buttons' file) go as `{"$uri": path}`: the extension gets a vscode.Uri.
  def run_effect(
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
      {:error, message} -> Notifications.notify(socket, :error, message)
    end
  end

  def run_effect(:reload_plugins, socket) do
    Plugins.reload()
    socket |> Extensions.load_plugins() |> Notifications.notify(:info, "Plugins reloaded")
  end

  # Applied at once (the change notice comes later): a picked color theme
  # replaces the previewed one without showing the old one in between.
  def run_effect({:update_setting, key, value}, socket) do
    case Settings.update(:user, key, fn _ -> value end) do
      :ok ->
        root = socket.assigns.root
        Config.load_settings(socket, Settings.all(root), Settings.errors(root))

      {:error, message} ->
        Notifications.notify(socket, :error, message)
    end
  end

  # Another folder: this window shows it (a new LiveView, `?folder=`), or a
  # new browser window does. Not while this one has unsaved changes – its
  # editors would be dropped.
  def run_effect({:open_folder, path, where}, socket) do
    root = Path.expand(path, socket.assigns.root)
    dirty = for %{dirty: true, path: p} <- open_tabs(socket), do: Path.basename(p)
    url = ~p"/?#{[folder: root]}"

    cond do
      not File.dir?(root) ->
        Notifications.notify(socket, :error, "#{root} is not a folder")

      where == :new_window ->
        push_event(socket, "bee:open_window", %{url: url})

      root == socket.assigns.root ->
        socket

      dirty != [] ->
        Notifications.notify(socket, :error, "Save or close #{Enum.join(dirty, ", ")} first")

      true ->
        push_navigate(socket, to: url)
    end
  end

  # The desktop app's native dialog (assets/js/app.js); the pick comes
  # back as bee.openFolder [where, path].
  def run_effect({:pick_folder, where, title}, socket),
    do:
      push_event(socket, "bee:pick_folder", %{
        where: where,
        title: title,
        start: socket.assigns.root
      })

  def run_effect({:uninstall_plugin, name}, socket) do
    case Plugins.uninstall(name) do
      :ok ->
        socket |> Extensions.load_plugins() |> Notifications.notify(:info, "Uninstalled #{name}")

      {:error, message} ->
        Notifications.notify(socket, :error, message)
    end
  end

  def run_effect({:set_plugin_enabled, name, enabled?}, socket) do
    case Plugins.set_enabled(name, enabled?) do
      :ok -> socket
      {:error, message} -> Notifications.notify(socket, :error, message)
    end
  end

  def run_effect({:notify, severity, message}, socket),
    do: Notifications.notify(socket, severity, message)

  # The list of notifications (the status bar's bell): shown, nothing pops up.
  def run_effect({:notifications, :toggle}, socket),
    do:
      run_effect(
        {:notifications, if(socket.assigns.notifications_open, do: :hide, else: :show)},
        socket
      )

  def run_effect({:notifications, :show}, socket),
    do: assign(socket, notifications_open: true, toasts: [])

  def run_effect({:notifications, :hide}, socket), do: assign(socket, notifications_open: false)
  def run_effect({:notifications, :hide_toasts}, socket), do: assign(socket, toasts: [])

  def run_effect({:notifications, :clear}, socket),
    do: assign(socket, notifications: [], toasts: [], notifications_open: false)

  def run_effect({:marketplace_search, ref, query, offset}, socket) do
    window = self()

    Task.Supervisor.start_child(Bee.Plugins.OpenVsx.TaskSup, fn ->
      send(window, {:marketplace_results, ref, offset, OpenVsx.search(query, offset: offset)})
    end)

    socket
  end

  def run_effect({:install_extension, id}, socket) do
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

  def run_effect({:start_search, opts}, socket) do
    case Bee.Search.start(Map.put(opts, :root, socket.assigns.root), self()) do
      {:ok, handle} -> change(socket, &Search.started(&1, handle))
      {:error, message} -> change(socket, &Search.failed(&1, message))
    end
  end

  def run_effect({:cancel_search, handle}, socket) do
    Bee.Search.cancel(handle)
    socket
  end

  def run_effect({:replace, paths, opts, replacement, only}, socket) do
    case Bee.Search.replace(paths, Map.put(opts, :root, socket.assigns.root), replacement, only) do
      {:ok, count} ->
        socket
        |> Notifications.notify(
          :info,
          "Replaced #{count} #{if count == 1, do: "occurrence", else: "occurrences"}"
        )
        |> change(&Search.refresh/1)

      {:error, message} ->
        Notifications.notify(socket, :error, message)
    end
  end

  # Find / Replace in Files: the selected text (one line) becomes the query.
  def run_effect({:find_in_files, replace?}, socket) do
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

  # Text of the active editor's first selection, if any.
  defp selected_text(assigns) do
    with %{active_editor: active, selections: [{from, to} | _]} when to > from <-
           plugin_context(assigns),
         text when is_binary(text) <- Bee.API.text(active),
         true <- to <= byte_size(text) do
      binary_part(text, from, to - from)
    else
      _ -> nil
    end
  end
end

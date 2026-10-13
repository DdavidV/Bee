defmodule BeeWeb.EditorLive.PluginAPI do
  @moduledoc """
  What plugins ask of a window: the requests of `Bee.API`
  (`{:bee_api, request}` messages), the questions of the extension host
  (`{:ask, …}`, asked in the palette), `bee.request()` and
  `bee.showMessage()` of browser plugins, and the Bee Console's `window()`.
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Plugins
  alias Bee.Workbench
  alias BeeWeb.EditorLive.{Commands, Notifications, Output}

  ## Events

  # bee.request() of a browser plugin: answered later with plugin:reply.
  def handle_event("plugin_request", %{"plugin" => plugin, "ref" => ref} = params, socket) do
    ctx = plugin_context(socket.assigns)

    case Plugins.request(plugin, params["method"], params["params"], ctx, ref) do
      :ok ->
        {:halt, socket}

      {:error, message} ->
        {:halt, push_event(socket, "plugin:reply", %{ref: ref, error: message})}
    end
  end

  # bee.showMessage() of a browser plugin.
  def handle_event("plugin_message", %{"plugin" => plugin, "text" => text} = params, socket) do
    level =
      case params["level"] do
        "error" -> :error
        "warning" -> :warning
        _ -> :info
      end

    {:halt, Notifications.notify(socket, level, "#{plugin}: #{text}")}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

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
         groups:
           for group <- Workbench.groups(workbench_from(a)) do
             %{id: group.id, active: group.active, tabs: Enum.map(group.tabs, & &1.path)}
           end,
         sidebar: if(a.sidebar_open, do: a.sidebar_view),
         panel: a.panel_open && Enum.map(a.terminals, & &1.name),
         palette: a.palette && Map.take(a.palette, [:mode, :query]),
         pid: self()
       }}
    )

    {:halt, socket}
  end

  # Requests from plugins (Bee.API).
  def handle_info({:bee_api, request}, socket), do: {:halt, plugin_request(socket, request)}

  def handle_info(_message, socket), do: {:cont, socket}

  # What a plugin may ask of a window (Bee.API).
  def plugin_request(socket, {:show_message, level, text}),
    do: Notifications.notify(socket, level, text)

  def plugin_request(socket, {:set_status, text}),
    do: change(socket, &Workbench.set_status(&1, text))

  def plugin_request(socket, {:open_file, path, reveal}) do
    if File.regular?(path) do
      socket = change(socket, &Workbench.open_editor(&1, path))
      # After cm:open / cm:activate, so the editor has the file.
      if reveal && Workbench.open?(workbench(socket), path),
        do: push_event(socket, "cm:reveal", Map.put(reveal, :path, path)),
        else: socket
    else
      Notifications.notify(socket, :error, "Cannot open #{path}: no such file")
    end
  end

  def plugin_request(socket, {:open_file_with, path, editor}) do
    if File.regular?(path),
      do: change(socket, &Bee.Workbench.Actions.open_with(&1, [path, editor])),
      else: Notifications.notify(socket, :error, "Cannot open #{path}: no such file")
  end

  def plugin_request(socket, {:execute_command, id}), do: Commands.run_command(socket, id)

  def plugin_request(socket, {:execute_command, id, args}),
    do: Commands.run_command(socket, id, args)

  def plugin_request(socket, {:set_view_input, view, value}) do
    socket
    |> update(:view_inputs, &Map.put(&1, view, value))
    # The box may have focus, where LiveView leaves its value alone.
    |> push_event("view:input", %{view: view, value: value})
  end

  # A question of the extension host's (Bee.Extensions.Host): asked in the
  # palette, answered with `{:bee_answer, ref, value}` (see palette_answer/3).
  def plugin_request(socket, {:ask, ref, pid, :pick, spec}),
    do: change(socket, &Workbench.open_quick_pick(&1, Map.put(spec, :reply, {pid, ref})))

  def plugin_request(socket, {:ask, ref, pid, :input, spec}),
    do: change(socket, &Workbench.open_input_box(&1, Map.put(spec, :reply, {pid, ref})))

  # Answered in another window.
  def plugin_request(%{assigns: %{palette: %{reply: {_pid, ref}}}} = socket, {:ask_done, ref}),
    do: change(socket, &Workbench.close_palette/1)

  # An extension shows one of its output channels (channel.show()).
  def plugin_request(socket, {:show_output, channel}) do
    socket
    |> assign(output_channel: channel)
    |> Output.load_output_channels()
    |> change(&Workbench.show_panel(&1, "output"))
    |> Output.push_output()
  end

  # A terminal of an extension's (window.createTerminal): this window runs
  # it, unless another one of the workspace does already. It is listed
  # with the user's, and shown when the extension shows it.
  def plugin_request(socket, {:create_terminal, host, id, spec}) do
    if Bee.Extensions.Host.claim_terminal(host, id) do
      case BeeWeb.EditorLive.Terminals.start(socket, spec) do
        {:ok, term, name} ->
          Bee.Extensions.Host.terminal_started(host, id, term)
          change(socket, &Workbench.terminal_added(&1, term, name))

        {:error, reason} ->
          Bee.Extensions.Host.terminal_started(host, id, nil)
          Notifications.notify(socket, :error, "Could not start terminal: #{inspect(reason)}")
      end
    else
      socket
    end
  end

  def plugin_request(socket, {:show_terminal, term}),
    do: change(socket, &Workbench.show_terminal(&1, term))

  def plugin_request(socket, {:kill_terminal, term}),
    do: change(socket, &Workbench.kill_terminal(&1, term))

  # Two documents an extension compares (vscode.diff): a tab with the
  # lines that differ. Closed by the extension (window.tabGroups.close),
  # in the window that has it.
  def plugin_request(socket, {:open_diff, %{id: id, title: title} = diff}) do
    socket
    |> update(:diffs, &Map.put(&1, id, diff))
    |> change(&Workbench.open_diff(&1, id, title))
  end

  def plugin_request(socket, {:close_diff, id}) do
    if is_map_key(socket.assigns.diffs, id),
      do: change(socket, &Workbench.close_editor(&1, "diff:" <> id)),
      else: socket
  end

  # A views container of an extension's is to be shown ("<view>.focus").
  def plugin_request(socket, {:show_container, id}),
    do: change(socket, &Workbench.show_container(&1, id))

  # An address for the user's browser (env.openExternal of an extension).
  def plugin_request(socket, {:open_external, url}),
    do: push_event(socket, "open-external", %{url: url})

  def plugin_request(socket, {:open_live_editor, spec}),
    do: change(socket, &Workbench.open_live_editor(&1, spec))

  def plugin_request(socket, {:input_box, spec}),
    do: change(socket, &Workbench.open_input_box(&1, spec))

  def plugin_request(socket, {:quick_pick, spec}),
    do: change(socket, &Workbench.open_quick_pick(&1, spec))

  def plugin_request(socket, {:post_message, plugin, data}),
    do: push_event(socket, "plugin:message", %{plugin: plugin, data: data})

  def plugin_request(socket, {:reply, ref, {:ok, result}}),
    do: push_event(socket, "plugin:reply", %{ref: ref, result: result})

  def plugin_request(socket, {:reply, ref, {:error, message}}),
    do: push_event(socket, "plugin:reply", %{ref: ref, error: message})

  def plugin_request(socket, _unknown), do: socket
end

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

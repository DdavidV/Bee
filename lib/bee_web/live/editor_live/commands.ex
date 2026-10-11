defmodule BeeWeb.EditorLive.Commands do
  @moduledoc """
  Running commands, and the menus that run them.

  Every user action (menus, palette, keybindings, buttons) is a
  `run_command` event with a `Bee.Commands.Registry` id. `run_command/4`
  runs it where it lives: Bee's server commands run their
  `use Bee.Commands.Command` handler here, plugin server commands are
  handed to `Bee.Plugins` (the plugin answers with `{:bee_api, request}`
  messages, see `BeeWeb.EditorLive.PluginAPI`), client ones are sent to the
  browser as `bee:exec`, and those of a VS Code extension's code run in the
  workspace's extension host (`Bee.Extensions.Host`).

  The menu bar's menus and the right-click menus (the ContextMenus hook)
  open and close here; `BeeWeb.EditorLive.Menus` builds their items.
  """

  import BeeWeb.EditorLive.Window

  alias Bee.Workbench
  alias Bee.Commands.Registry, as: CommandRegistry
  alias BeeWeb.EditorLive.{Effects, Notifications}

  ## Events

  # `args`: optional JSON array (view items, buttons with arguments).
  def handle_event("run_command", %{"command" => id} = params, socket) do
    {:halt,
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

  def handle_event("open_context_menu", %{"menu" => menu, "x" => x, "y" => y} = params, socket)
      when is_binary(menu) and is_number(x) and is_number(y) do
    args = if is_list(params["args"]), do: params["args"], else: []
    context = if is_map(params["context"]), do: params["context"], else: %{}
    # A tab's or an editor's menu: its group is the one its commands act on.
    group = if is_integer(context["editorGroup"]), do: context["editorGroup"]

    {:halt,
     socket
     |> then(&if(group, do: change(&1, fn wb -> Workbench.focus_group(wb, group) end), else: &1))
     |> change(&Workbench.open_context_menu(&1, menu, round(x), round(y), args, context))}
  end

  def handle_event("close_context_menu", _params, socket),
    do: {:halt, change(socket, &Workbench.close_context_menu/1)}

  def handle_event("toggle_menu", %{"menu" => menu}, socket),
    do: {:halt, change(socket, &Workbench.toggle_menu(&1, menu))}

  def handle_event("close_menu", _params, socket),
    do: {:halt, change(socket, &Workbench.close_menu/1)}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  # `args` reach plugin and client commands, and Bee's own server commands
  # whose handler takes them.
  def run_command(socket, id, args \\ [], resources? \\ false) do
    case Enum.find(socket.assigns.commands, &(&1.id == id)) do
      nil ->
        # One a VS Code extension registered without declaring it.
        case Bee.Extensions.Host.command(socket.assigns.root, id) do
          nil ->
            Notifications.notify(socket, :error, "Command '#{id}' not found")

          name ->
            command = %{id: id, handler: {:extension, name}}
            Effects.run_effect({:run_extension_command, command, args, resources?}, socket)
        end

      command ->
        cond do
          not CommandRegistry.enabled?(command, context(socket.assigns)) ->
            socket

          command.runtime == :client ->
            Effects.run_effect({:exec_client, id, args}, socket)

          match?({:plugin, _}, command.handler) ->
            Effects.run_effect({:run_plugin_command, command, args}, socket)

          match?({:extension, _}, command.handler) ->
            Effects.run_effect({:run_extension_command, command, args, resources?}, socket)

          true ->
            change(socket, &CommandRegistry.run_handler(command.handler, &1, args))
        end
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
end

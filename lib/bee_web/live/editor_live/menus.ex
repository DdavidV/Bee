defmodule BeeWeb.EditorLive.Menus do
  @moduledoc """
  The items of the window's menus, from the commands and menus contributed
  (`Bee.Commands.Registry`): the menu bar, the icon menus (toolbars) and
  the open right-click menu. An item is shown when its `when` holds in the
  window's context (`BeeWeb.EditorLive.Window.context/1`).
  """

  import BeeWeb.EditorLive.Window

  alias Bee.Commands.Registry, as: CommandRegistry
  alias Bee.Commands.Keybindings

  def menubar(assigns) do
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
end

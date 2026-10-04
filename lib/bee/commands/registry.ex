defmodule Bee.Commands.Registry do
  @moduledoc """
  The commands, keybindings and menus contributed to Bee: a
  `Bee.Contributions.Point` for the `commands`, `keybindings`, `menubar` and
  `menus` sections of manifests.

  Normalized shapes:

    * command – `%{id, title, category, runtime: :server | :client, source,
      enablement, toggled, enablement_ast, toggled_ast, handler}`, where
      `handler` is `{module, fun}` for Bee's own server commands (a
      `use Bee.Commands.Command` function taking the workbench),
      `{:plugin, name}` for a plugin's (run by `Bee.Plugins`) and `nil` for
      client commands
    * keybinding – `%{key, mac, command, when, source}`
    * menu – `%{id, label, items: [%{command, when_ast} | :separator]}`, items
      ordered by their `"group@order"`, with a separator between groups

  Bee's own server commands must each have exactly one handler, and every
  handler a declared command. A plugin's server commands need a `server`
  part (its handlers are checked when it activates), its client commands a
  `browser` part. Command ids are unique across sources.
  """
  @behaviour Bee.Contributions.Point

  alias Bee.Contributions

  @doc "Subscribes to `{:contributions_changed, keys}` (see `Bee.Contributions`)."
  def subscribe, do: Contributions.subscribe()

  def commands, do: Enum.flat_map(Contributions.entries(:commands), &elem(&1, 1).commands)

  def command(id), do: Enum.find(commands(), &(&1.id == id))

  @doc "Default keybindings, in contribution order (later ones win)."
  def keybindings, do: Enum.flat_map(Contributions.entries(:commands), &elem(&1, 1).keybindings)

  @doc "Menu bar menus with their items, across all sources."
  def menus do
    contributions = Enum.map(Contributions.entries(:commands), &elem(&1, 1))
    items = Enum.flat_map(contributions, & &1.menu_items)

    for %{id: id, label: label} <- Enum.flat_map(contributions, & &1.menubar) do
      %{id: id, label: label, items: menu_items(items, "menubar/" <> id)}
    end
  end

  @doc "`Category: Title`, as shown in the palette."
  def label(%{category: nil, title: title}), do: title
  def label(%{category: category, title: title}), do: "#{category}: #{title}"

  def enabled?(%{enablement_ast: ast}, context), do: Bee.Commands.When.eval(ast, context)
  def toggled?(%{toggled_ast: nil}, _context), do: nil
  def toggled?(%{toggled_ast: ast}, context), do: Bee.Commands.When.eval(ast, context)

  ## Normalization

  @impl Bee.Contributions.Point
  def key, do: :commands

  @impl Bee.Contributions.Point
  def normalize!(manifest, source, opts) do
    contributes = manifest["contributes"]
    handler_table = handler_table!(Keyword.get(opts, :handlers, []))

    commands =
      for c <- Map.get(contributes, "commands", []) do
        runtime = String.to_existing_atom(c["runtime"])

        %{
          id: c["command"],
          title: c["title"],
          category: c["category"],
          runtime: runtime,
          enablement: c["enablement"],
          toggled: c["toggled"],
          enablement_ast: Bee.Commands.When.parse!(c["enablement"]),
          toggled_ast: c["toggled"] && Bee.Commands.When.parse!(c["toggled"]),
          source: source,
          handler: handler(source, runtime, handler_table[c["command"]])
        }
      end

    check_handlers!(commands, handler_table, source, manifest)

    keybindings =
      for k <- Map.get(contributes, "keybindings", []) do
        for key <- [k["key"], k["mac"]],
            key,
            do: Bee.Commands.Keys.parse(key) |> ok!("key #{inspect(key)}")

        Bee.Commands.When.parse!(k["when"])
        %{key: k["key"], mac: k["mac"], command: k["command"], when: k["when"], source: source}
      end

    menubar = for m <- Map.get(contributes, "menubar", []), do: %{id: m["id"], label: m["label"]}

    menu_items =
      for {menu, items} <- Map.get(contributes, "menus", %{}),
          item <- items do
        {group, order} = parse_group(item["group"])

        %{
          menu: menu,
          command: item["command"],
          group: group,
          order: order,
          when_ast: Bee.Commands.When.parse!(item["when"])
        }
      end

    if commands == [] and keybindings == [] and menubar == [] and menu_items == [] do
      nil
    else
      %{commands: commands, keybindings: keybindings, menubar: menubar, menu_items: menu_items}
    end
  end

  @impl Bee.Contributions.Point
  def conflicts(%{commands: commands}, others) do
    taken = MapSet.new(for other <- others, c <- other.commands, do: c.id)
    for %{id: id} <- commands, id in taken, do: "command #{inspect(id)} is already defined"
  end

  defp handler({:plugin, name}, :server, _), do: {:plugin, name}
  defp handler(_source, _runtime, handler), do: handler

  defp handler_table!(modules) do
    Enum.reduce(modules, %{}, fn module, acc ->
      Map.merge(
        acc,
        Map.new(module.__commands__(), fn {id, fun} -> {id, {module, fun}} end),
        fn id, _, _ ->
          raise ArgumentError, "command #{inspect(id)} has more than one handler"
        end
      )
    end)
  end

  defp check_handlers!(commands, handler_table, {:plugin, name}, manifest) do
    if handler_table != %{},
      do: raise(ArgumentError, "plugin handlers are found in its server module, not passed in")

    for %{runtime: :server, id: id} <- commands,
        manifest["server"] == nil,
        do:
          raise(ArgumentError, "server command #{inspect(id)} needs a \"server\" part in #{name}")

    for %{runtime: :client, id: id} <- commands,
        manifest["browser"] == nil,
        do:
          raise(
            ArgumentError,
            "client command #{inspect(id)} needs a \"browser\" part in #{name}"
          )

    :ok
  end

  defp check_handlers!(commands, handler_table, _source, _manifest) do
    for %{runtime: :server, id: id, handler: nil} <- commands,
        do:
          raise(
            ArgumentError,
            "server command #{inspect(id)} has no `use Bee.Commands.Command` handler"
          )

    for %{runtime: :client, id: id, handler: {_, _}} <- commands,
        do: raise(ArgumentError, "client command #{inspect(id)} must not have a server handler")

    declared = MapSet.new(commands, & &1.id)

    for {id, _} <- handler_table,
        not MapSet.member?(declared, id),
        do: raise(ArgumentError, "handler for undeclared command #{inspect(id)}")
  end

  defp ok!({:ok, value}, _what), do: value
  defp ok!({:error, reason}, what), do: raise(ArgumentError, "invalid #{what}: #{reason}")

  # "1_save@2" -> {"1_save", 2}; ungrouped items go last.
  defp parse_group(nil), do: {"~", 0}

  defp parse_group(group) do
    case String.split(group, "@", parts: 2) do
      [name, order] -> {name, String.to_integer(order)}
      [name] -> {name, 0}
    end
  end

  defp menu_items(items, menu) do
    items
    |> Enum.filter(&(&1.menu == menu))
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_group, items} ->
      items |> Enum.sort_by(& &1.order) |> Enum.map(&Map.take(&1, [:command, :when_ast]))
    end)
    |> Enum.intersperse([:separator])
    |> List.flatten()
  end
end

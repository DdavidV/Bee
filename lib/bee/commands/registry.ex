defmodule Bee.Commands.Registry do
  @moduledoc """
  The commands, keybindings and menus contributed to Bee: a
  `Bee.Contributions.Point` for the `commands`, `keybindings`, `menubar`,
  `menus` and `submenus` sections of manifests.

  Normalized shapes:

    * command – `%{id, title, category, icon, runtime: :server | :client |
      :extension, source, enablement, toggled, enablement_ast, toggled_ast,
      handler}`, where `handler` is `{module, fun}` for Bee's own server
      commands (a `use Bee.Commands.Command` function taking the workbench),
      `{:plugin, name}` for a plugin's (run by `Bee.Plugins`),
      `{:extension, name}` for one the code of a VS Code extension
      registers (run by the extension host) and `nil` for client commands.
      `icon` is a name (`BeeWeb.Icons`) or `%{light: url, dark: url}`
    * keybinding – `%{key, mac, linux, win, command, when, args, source}`
    * menu – `%{id, label, items: [%{command, when_ast} | :separator]}`, items
      ordered by their `"group@order"`, with a separator between groups
    * submenu – `%{id, label, source}`: a menu shown as an item of another
      one (an item with `submenu` instead of `command`)

  Bee's own server commands must each have exactly one handler, and every
  handler a declared command. A plugin's server commands need a `server`
  part (its handlers are checked when it activates), its client commands a
  `browser` part, its extension commands an `extension` part. Command and
  submenu ids are unique across sources.
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

  @doc """
  Items of any menu (`"editor/title"`, `"view/title"`, a submenu's id, …)
  across sources: `[%{command, group, when_ast}]` – or `submenu` in place
  of `command` – ordered by group, then order.
  """
  def menu(id) do
    Contributions.entries(:commands)
    |> Enum.flat_map(&elem(&1, 1).menu_items)
    |> Enum.filter(&(&1.menu == id))
    |> Enum.sort_by(&{&1.group, &1.order})
    |> Enum.map(&Map.take(&1, [:command, :submenu, :group, :when_ast]))
  end

  @doc "The submenus, by id: `%{id => %{id, label, source}}`."
  def submenus do
    for {_source, data} <- Contributions.entries(:commands),
        submenu <- data.submenus,
        into: %{},
        do: {submenu.id, submenu}
  end

  @doc "`Category: Title`, as shown in the palette."
  def label(%{category: nil, title: title}), do: title
  def label(%{category: category, title: title}), do: "#{category}: #{title}"

  @doc """
  Runs one of Bee's own server command handlers on `workbench`, passing
  `args` when the handler takes them (see `Bee.Commands.Command`).
  """
  def run_handler({module, fun}, workbench, args) do
    if function_exported?(module, fun, 2),
      do: apply(module, fun, [workbench, args]),
      else: apply(module, fun, [workbench])
  end

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
          icon: icon(c["icon"], source),
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
        for key <- [k["key"], k["mac"], k["linux"], k["win"]],
            key,
            do: Bee.Commands.Keys.parse(key) |> ok!("key #{inspect(key)}")

        Bee.Commands.When.parse!(k["when"])

        %{
          key: k["key"],
          mac: k["mac"],
          linux: k["linux"],
          win: k["win"],
          command: k["command"],
          when: k["when"],
          args: k["args"],
          source: source
        }
      end

    menubar = for m <- Map.get(contributes, "menubar", []), do: %{id: m["id"], label: m["label"]}

    menu_items =
      for {menu, items} <- Map.get(contributes, "menus", %{}),
          item <- items do
        {group, order} = parse_group(item["group"])

        %{
          menu: menu,
          command: item["command"],
          submenu: item["submenu"],
          group: group,
          order: order,
          when_ast: Bee.Commands.When.parse!(item["when"])
        }
      end

    submenus =
      for m <- Map.get(contributes, "submenus", []),
          do: %{id: m["id"], label: m["label"], source: source}

    if commands == [] and keybindings == [] and menubar == [] and menu_items == [] and
         submenus == [] do
      nil
    else
      %{
        commands: commands,
        keybindings: keybindings,
        menubar: menubar,
        menu_items: menu_items,
        submenus: submenus
      }
    end
  end

  @impl Bee.Contributions.Point
  def conflicts(%{commands: commands, submenus: submenus}, others) do
    taken = MapSet.new(for other <- others, c <- other.commands, do: c.id)
    taken_menus = MapSet.new(for other <- others, m <- other.submenus, do: m.id)

    for(%{id: id} <- commands, id in taken, do: "command #{inspect(id)} is already defined") ++
      for %{id: id} <- submenus,
          id in taken_menus,
          do: "submenu #{inspect(id)} is already defined"
  end

  # A plugin's images are served from its folder (Bee.Plugins.asset_path/2).
  defp icon(%{"light" => light, "dark" => dark}, {:plugin, name}),
    do: %{light: asset_url(name, light), dark: asset_url(name, dark)}

  defp icon(icon, _source) when is_binary(icon), do: icon
  defp icon(_icon, _source), do: nil

  defp asset_url(name, rel) do
    path = rel |> Path.expand("/") |> String.trim_leading("/")
    "/plugins/#{URI.encode(name)}/#{URI.encode(path)}"
  end

  defp handler({:plugin, name}, :server, _), do: {:plugin, name}
  defp handler({:plugin, name}, :extension, _), do: {:extension, name}
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

    for %{runtime: :extension, id: id} <- commands,
        manifest["extension"] == nil,
        do:
          raise(
            ArgumentError,
            "extension command #{inspect(id)} needs an \"extension\" part in #{name}"
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

    for %{runtime: :extension, id: id} <- commands,
        do: raise(ArgumentError, "extension command #{inspect(id)} must come from a plugin")

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
    |> Enum.filter(&(&1.menu == menu and &1.command != nil))
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_group, items} ->
      items |> Enum.sort_by(& &1.order) |> Enum.map(&Map.take(&1, [:command, :when_ast]))
    end)
    |> Enum.intersperse([:separator])
    |> List.flatten()
  end
end

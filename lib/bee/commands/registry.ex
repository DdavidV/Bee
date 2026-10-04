defmodule Bee.Commands.Registry do
  @moduledoc """
  Registry of contributions, VS Code style. A source (`:builtin` for Bee
  itself, later a plugin) registers a contributions manifest – JSON in the
  format of `priv/schemas/contributions.schema.json`, Bee's own is
  `priv/contributions/bee.json` – plus the modules implementing its server
  commands (`use Bee.Commands.Command`).

  Normalized shapes:

    * command – `%{id, title, category, runtime: :server | :client,
      enablement, toggled, enablement_ast, toggled_ast, handler: {module, fun} | nil}`
    * keybinding – `%{key, mac, command, when, source}`
    * menu – `%{id, label, items: [%{command, when_ast} | :separator]}`, items
      ordered by their `"group@order"`, with a separator between groups

  Registering checks that every server command has exactly one handler and
  every handler a declared command; for `:builtin` a mismatch stops boot.

  Reads go straight to ETS. Changes broadcast `:commands_changed` on the
  `"commands"` topic.
  """
  use GenServer

  @table __MODULE__
  @topic "commands"

  # Bee's own manifest, embedded and schema-checked at compile time (see
  # Bee.Priv); a mistake in bee.json fails `mix compile`. The handler
  # cross-check needs the handler modules, so it runs at boot (init/1).
  @builtin_manifest_file "contributions/bee.json"
  @external_resource Bee.Priv.path(@builtin_manifest_file)
  @builtin_manifest Bee.Priv.read_json!(@builtin_manifest_file)

  case Bee.JSON.Schema.validate("contributions", "#", @builtin_manifest) do
    :ok ->
      :ok

    {:error, messages} ->
      raise CompileError,
        file: Bee.Priv.path(@builtin_manifest_file),
        description: "invalid contributions manifest: " <> Enum.join(messages, "; ")
  end

  @builtin_handlers [Bee.Workbench.Actions]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, @topic)

  @doc """
  Registers (or replaces) the contributions of `source`. `manifest` is the
  decoded JSON; `handlers` the `use Bee.Commands.Command` modules. Raises
  `ArgumentError` for an invalid manifest.
  """
  def register(source, manifest, handlers \\ []),
    do: GenServer.call(__MODULE__, {:register, source, normalize!(manifest, handlers, source)})

  def unregister(source), do: GenServer.call(__MODULE__, {:unregister, source})

  def commands, do: Enum.flat_map(contributions(), & &1.commands)

  def command(id), do: Enum.find(commands(), &(&1.id == id))

  @doc "Default keybindings, in contribution order (later ones win)."
  def keybindings, do: Enum.flat_map(contributions(), & &1.keybindings)

  @doc "Menu bar menus with their items, across all sources."
  def menus do
    contributions = contributions()
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

  @doc false
  def normalize!(manifest, handlers, source) do
    case Bee.JSON.Schema.validate("contributions", "#", manifest) do
      :ok ->
        :ok

      {:error, messages} ->
        raise ArgumentError, "invalid contributions manifest: " <> Enum.join(messages, "; ")
    end

    contributes = manifest["contributes"]
    handler_table = handler_table!(handlers)

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
          handler: handler_table[c["command"]]
        }
      end

    check_handlers!(commands, handler_table)

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

    %{commands: commands, keybindings: keybindings, menubar: menubar, menu_items: menu_items}
  end

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

  defp check_handlers!(commands, handler_table) do
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

  # :builtin first, then other sources in registration order.
  defp contributions do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {source, seq, _} -> {source != :builtin, seq} end)
    |> Enum.map(&elem(&1, 2))
  end

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    builtin = normalize!(@builtin_manifest, @builtin_handlers, :builtin)
    # Synchronously, so processes started after us see the built-ins.
    {:ok, put(0, :builtin, builtin)}
  end

  @impl true
  def handle_call({:register, source, contributions}, _from, seq),
    do: {:reply, :ok, put(seq, source, contributions)}

  def handle_call({:unregister, source}, _from, seq) do
    :ets.delete(@table, source)
    Phoenix.PubSub.broadcast(Bee.PubSub, @topic, :commands_changed)
    {:reply, :ok, seq}
  end

  defp put(seq, source, contributions) do
    :ets.insert(@table, {source, seq, contributions})
    Phoenix.PubSub.broadcast(Bee.PubSub, @topic, :commands_changed)
    seq + 1
  end
end

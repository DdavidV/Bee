defmodule Bee.Contributions do
  @moduledoc """
  Everything contributed to Bee, by source, VS Code style.

  A source registers a manifest (`priv/schemas/manifest.schema.json`): Bee's
  own ones in `priv/contributions/` as `{:builtin, name}`, plugins as
  `{:plugin, name}` (`Bee.Plugins`). Registering validates the manifest,
  lets every contribution point (`Bee.Contributions.Point`) normalize its
  part and checks for clashes with other sources – all or nothing.

  Points:

    * `Bee.Commands.Registry` – commands, keybindings, menubar, menus
    * `Bee.Languages` – languages, grammars
    * `Bee.Settings.Configuration` – configuration (settings)
    * `Bee.Views` – viewsContainers, views
    * `Bee.IconThemes` – iconThemes (plugins only)

  Reads go straight to ETS. Changes broadcast `{:contributions_changed, keys}`
  on the `"contributions"` topic, `keys` being the point keys affected.
  """
  use GenServer

  @table __MODULE__
  @topic "contributions"

  @points [
    Bee.Commands.Registry,
    Bee.Languages,
    Bee.Settings.Configuration,
    Bee.Views,
    Bee.IconThemes,
    Bee.ColorThemes
  ]

  # Bee's own manifests, embedded and schema-checked at compile time (see
  # Bee.Priv): a mistake fails `mix compile`. Point checks that need other
  # modules (command handlers) run at boot.
  @builtin ~w(bee languages)
  # The modules implementing a built-in manifest's server commands.
  @builtin_handlers %{"bee" => [Bee.Workbench.Actions]}

  @builtin_manifests (for name <- @builtin do
                        file = "contributions/#{name}.json"
                        @external_resource Bee.Priv.path(file)
                        manifest = Bee.Priv.read_json!(file)

                        case Bee.JSON.Schema.validate("manifest", "#", manifest) do
                          :ok ->
                            :ok

                          {:error, messages} ->
                            raise CompileError,
                              file: Bee.Priv.path(file),
                              description: "invalid manifest: " <> Enum.join(messages, "; ")
                        end

                        {name, manifest}
                      end)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, @topic)

  @doc """
  Registers (or replaces) what `source` contributes. `opts` are passed to the
  points (`handlers:` – the `use Bee.Commands.Command` modules of built-in
  server commands; `dir:` – a plugin's folder, which its files are relative to). Returns `:ok` or `{:error, message}`.
  """
  def register(source, manifest, opts \\ []) do
    with {:ok, data} <- normalize(source, manifest, opts),
         do: GenServer.call(__MODULE__, {:register, source, data})
  end

  def unregister(source), do: GenServer.call(__MODULE__, {:unregister, source})

  @doc "`[{source, data}]` for the point `key`, built-ins first, then in registration order."
  def entries(key) do
    for {source, _seq, data} <- sorted(), value = Map.get(data, key), do: {source, value}
  end

  def sources, do: Enum.map(sorted(), &elem(&1, 0))

  @doc "Validates and normalizes a manifest without registering it."
  def normalize(source, manifest, opts \\ []) do
    case Bee.JSON.Schema.validate("manifest", "#", manifest) do
      :ok ->
        {:ok, Map.new(@points, &{&1.key(), &1.normalize!(manifest, source, opts)})}

      {:error, messages} ->
        {:error, "invalid manifest: " <> Enum.join(messages, "; ")}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp sorted do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {source, seq, _} -> {not match?({:builtin, _}, source), seq} end)
  end

  defp conflicts(source, data) do
    others = for {other, _seq, d} <- :ets.tab2list(@table), other != source, do: d

    for point <- @points,
        function_exported?(point, :conflicts, 2),
        new = data[point.key()],
        message <- point.conflicts(new, Enum.flat_map(others, &List.wrap(&1[point.key()]))),
        do: message
  end

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    # conflicts/1 checks function_exported?/3, which needs them loaded.
    Enum.each(@points, &Code.ensure_loaded!/1)

    # Synchronously, so processes started after us see the built-ins.
    seq =
      Enum.reduce(@builtin_manifests, 0, fn {name, manifest}, seq ->
        source = {:builtin, name}

        case normalize(source, manifest, handlers: Map.get(@builtin_handlers, name, [])) do
          {:ok, data} -> put(seq, source, data)
          {:error, message} -> raise "priv/contributions/#{name}.json: #{message}"
        end
      end)

    {:ok, seq}
  end

  @impl true
  def handle_call({:register, source, data}, _from, seq) do
    case conflicts(source, data) do
      [] -> {:reply, :ok, put(seq, source, data)}
      messages -> {:reply, {:error, Enum.join(messages, "; ")}, seq}
    end
  end

  def handle_call({:unregister, source}, _from, seq) do
    case :ets.lookup(@table, source) do
      [{^source, _, old}] ->
        :ets.delete(@table, source)
        broadcast(changed(old, %{}))

      [] ->
        :ok
    end

    {:reply, :ok, seq}
  end

  defp put(seq, source, data) do
    old =
      case :ets.lookup(@table, source) do
        [{^source, _, old}] -> old
        [] -> %{}
      end

    :ets.insert(@table, {source, seq, data})
    broadcast(changed(old, data))
    seq + 1
  end

  defp changed(old, new) do
    for point <- @points,
        key = point.key(),
        old[key] != nil or new[key] != nil,
        do: key
  end

  defp broadcast([]), do: :ok

  defp broadcast(keys),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:contributions_changed, keys})
end

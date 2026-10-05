defmodule Bee.UI do
  @moduledoc """
  What plugins put on screen, as data: the content of their views and their
  status bar items. Plugins set them through `Bee.API`; every window renders
  them. Kept in ETS (reads don't go through the process); changes broadcast
  `{:ui_changed, {:view, id}}` or `{:ui_changed, :status_items}` on the
  `"ui"` topic.

  ## View content

      %{
        items: [item],          # a tree
        message: "…",           # text above the items (e.g. when there are none)
        buttons: [%{label: "Initialize Repository", command: "git.init"}],
        input: %{placeholder: "Message", command: "git.commit", action: "Commit"},
        badge: 3                # number on the activity bar icon
      }

  An item:

      %{
        id: "src/a.ex",                        # unique within the view (required)
        label: "a.ex",                         # (required)
        description: "src",                    # dimmed, after the label
        tooltip: "…",
        icon: "document",                      # a Heroicons outline name
        resource: "/abs/src/a.ex",             # the file it stands for: without
                                               # `icon`, the file icon theme's icon
        decoration: %{text: "M", color: "modified"},
        context: "change",                     # `viewItem` in menu `when` clauses
        command: %{command: "git.open", arguments: ["src/a.ex"]},  # on click
        arguments: ["src/a.ex"],               # for its inline buttons (default [id])
        children: [item],
        expanded: true                         # initially (default true)
      }

  Decoration colors: `"modified"`, `"added"`, `"deleted"`, `"untracked"`,
  `"conflict"`, `"ignored"`. Keys are atoms (also from Erlang). An input's
  command gets the text as its last argument.

  ## Status bar items

      %{text: "main", icon: "share", tooltip: "Checkout…", command: "git.checkout",
        alignment: :left, priority: 0}

  Higher priority goes further left.
  """
  use GenServer

  @table __MODULE__
  @topic "ui"
  @max_items 5_000
  @colors ~w(modified added deleted untracked conflict ignored)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, @topic)

  ## Views

  @doc "Content of view `id`, normalized, or nil."
  def view(id) do
    case :ets.lookup(@table, {:view, id}) do
      [{_, _owner, content}] -> content
      [] -> nil
    end
  end

  @doc "Sets view `id`'s content (see the moduledoc); `owner` is the plugin. Raises on bad content."
  def put_view(owner, id, content),
    do: GenServer.call(__MODULE__, {:put, {:view, id}, owner, normalize_view!(content)})

  ## Status bar items

  @doc "Status bar items, `[%{id, owner, text, icon, tooltip, command, alignment, priority}]`, in display order."
  def status_items do
    for({{:status, _, _}, _owner, item} <- :ets.tab2list(@table), do: item)
    |> Enum.sort_by(&{-&1.priority, &1.owner, &1.id})
  end

  def put_status_item(owner, id, item),
    do:
      GenServer.call(
        __MODULE__,
        {:put, {:status, owner, id}, owner, normalize_status_item!(owner, id, item)}
      )

  def delete_status_item(owner, id),
    do: GenServer.call(__MODULE__, {:delete, {:status, owner, id}})

  ## File decorations

  @doc "All plugins' file decorations, `%{abs_path => decoration}` (see `Bee.UI.Decorations`)."
  def decorations do
    for {{:decorations, _owner}, _owner2, decorations} <- :ets.tab2list(@table),
        reduce: %{},
        do: (acc -> Map.merge(acc, decorations))
  end

  @doc "Replaces `owner`'s file decorations. Raises on bad data."
  def put_decorations(owner, decorations) do
    decorations = Bee.UI.Decorations.normalize!(decorations)
    GenServer.call(__MODULE__, {:put, {:decorations, owner}, owner, decorations})
  end

  ## Context keys

  @doc """
  Context keys set by plugins (VS Code's `setContext`), merged into every
  window's `when` context: `%{key => value}`.
  """
  def context do
    for {{:context, _owner, key}, _owner2, value} <- :ets.tab2list(@table),
        into: %{},
        do: {key, value}
  end

  @doc "Sets context key `key` (JSON-like value) for `owner`; `nil` removes it."
  def put_context(owner, key, nil),
    do: GenServer.call(__MODULE__, {:delete, {:context, owner, key}})

  def put_context(owner, key, value),
    do: GenServer.call(__MODULE__, {:put, {:context, owner, key}, owner, value})

  @doc "Removes everything `owner` put on screen (it was unloaded)."
  def forget(owner), do: GenServer.call(__MODULE__, {:forget, owner})

  ## Normalization

  @doc false
  def normalize_view!(content) when is_map(content) do
    items = Enum.map(list!(content, :items), &item!/1)
    if count(items) > @max_items, do: raise(ArgumentError, "more than #{@max_items} items")

    %{
      items: items,
      message: string(content, :message),
      buttons:
        for b <- list!(content, :buttons) do
          %{label: string!(b, :label), command: string!(b, :command), arguments: args(b)}
        end,
      input:
        case get(content, :input) do
          nil ->
            nil

          input ->
            %{
              placeholder: string(input, :placeholder) || "",
              command: string!(input, :command),
              action: string(input, :action),
              arguments: args(input)
            }
        end,
      badge:
        case get(content, :badge) do
          n when is_integer(n) and n > 0 -> n
          _ -> nil
        end
    }
  end

  def normalize_view!(other),
    do: raise(ArgumentError, "view content must be a map, got: #{inspect(other)}")

  defp item!(item) when is_map(item) do
    id = string!(item, :id)

    %{
      id: id,
      label: string!(item, :label),
      description: string(item, :description),
      tooltip: string(item, :tooltip),
      icon: string(item, :icon),
      resource: string(item, :resource),
      decoration:
        case get(item, :decoration) do
          nil -> nil
          d -> %{text: string(d, :text) || "", color: color(string(d, :color))}
        end,
      context: string(item, :context),
      command:
        case get(item, :command) do
          nil -> nil
          c -> %{command: string!(c, :command), arguments: args(c)}
        end,
      arguments: if(get(item, :arguments), do: args(item), else: [id]),
      children: Enum.map(list!(item, :children), &item!/1),
      expanded: get(item, :expanded) != false
    }
  end

  defp item!(other), do: raise(ArgumentError, "a view item must be a map, got: #{inspect(other)}")

  defp normalize_status_item!(owner, id, item) when is_map(item) do
    %{
      id: id,
      owner: owner,
      text: string(item, :text) || "",
      icon: string(item, :icon),
      tooltip: string(item, :tooltip),
      command: string(item, :command),
      arguments: args(item),
      alignment: if(get(item, :alignment) in [:right, "right"], do: :right, else: :left),
      priority: if(is_integer(get(item, :priority)), do: get(item, :priority), else: 0)
    }
  end

  defp normalize_status_item!(_owner, _id, other),
    do: raise(ArgumentError, "a status bar item must be a map, got: #{inspect(other)}")

  defp count(items), do: Enum.reduce(items, 0, &(&2 + 1 + count(&1.children)))

  defp color(c) when c in @colors, do: c
  defp color(_), do: nil

  # Atom keys (Elixir and Erlang maps); string keys work too.
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp string(map, key) do
    case get(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) or is_number(value) -> to_string(value)
      value when is_list(value) -> List.to_string(value)
      other -> raise ArgumentError, "#{key} must be a string, got: #{inspect(other)}"
    end
  end

  defp string!(map, key) when is_map(map) do
    string(map, key) || raise(ArgumentError, "#{key} is required in #{inspect(map)}")
  end

  defp list!(map, key) do
    case get(map, key) do
      nil -> []
      list when is_list(list) -> list
      other -> raise ArgumentError, "#{key} must be a list, got: #{inspect(other)}"
    end
  end

  # Command arguments travel to the browser and back as JSON.
  defp args(map) do
    args = list!(map, :arguments)

    case Jason.encode(args) do
      {:ok, _} -> args
      {:error, _} -> raise ArgumentError, "arguments must be JSON-encodable: #{inspect(args)}"
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, key, owner, value}, _from, state) do
    :ets.insert(@table, {key, owner, value})
    broadcast(key)
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :ets.delete(@table, key)
    broadcast(key)
    {:reply, :ok, state}
  end

  def handle_call({:forget, owner}, _from, state) do
    for {key, ^owner, _} <- :ets.tab2list(@table) do
      :ets.delete(@table, key)
      broadcast(key)
    end

    {:reply, :ok, state}
  end

  defp broadcast({:view, id}),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:ui_changed, {:view, id}})

  defp broadcast({:status, _, _}),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:ui_changed, :status_items})

  defp broadcast({:decorations, _}),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:ui_changed, :decorations})

  defp broadcast({:context, _, _}),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:ui_changed, :context})
end

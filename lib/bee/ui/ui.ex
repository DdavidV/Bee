defmodule Bee.UI do
  @moduledoc """
  What plugins put on screen, as data: the content of their views, their
  status bar items, file decorations and context keys. Plugins set them
  through `Bee.API`. Each workspace has its own (a plugin runs once per
  workspace, see `Bee.Plugins`), rendered by the windows showing it.

  Kept in ETS (reads don't go through the process); changes broadcast
  `{:ui_changed, {:view, id} | :status_items | :decorations | :context}` on
  the workspace's topic (`subscribe/1`).

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
  @max_items 5_000
  @colors ~w(modified added deleted untracked conflict ignored)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Changes for the windows of workspace `root`."
  def subscribe(root), do: Phoenix.PubSub.subscribe(Bee.PubSub, topic(root))

  defp topic(root), do: "ui:" <> root

  ## Views

  @doc "Content of view `id` in workspace `root`, normalized, or nil."
  def view(root, id) do
    case :ets.lookup(@table, {:view, root, id}) do
      [{_, _owner, content}] -> content
      [] -> nil
    end
  end

  @doc """
  Sets view `id`'s content (see the moduledoc) in workspace `root`; `owner`
  is the plugin. Raises on bad content.
  """
  def put_view(root, owner, id, content) when is_binary(root),
    do: GenServer.call(__MODULE__, {:put, {:view, root, id}, owner, normalize_view!(content)})

  ## Status bar items

  @doc """
  Status bar items of workspace `root`, `[%{id, owner, text, icon, tooltip,
  command, alignment, priority}]`, in display order.
  """
  def status_items(root) do
    :ets.match(@table, {{:status, root, :_, :_}, :_, :"$1"})
    |> Enum.map(&hd/1)
    |> Enum.sort_by(&{-&1.priority, &1.owner, &1.id})
  end

  def put_status_item(root, owner, id, item) when is_binary(root),
    do:
      GenServer.call(
        __MODULE__,
        {:put, {:status, root, owner, id}, owner, normalize_status_item!(owner, id, item)}
      )

  def delete_status_item(root, owner, id) when is_binary(root),
    do: GenServer.call(__MODULE__, {:delete, {:status, root, owner, id}})

  ## File decorations

  @doc "All plugins' file decorations in workspace `root`, `%{abs_path => decoration}` (see `Bee.UI.Decorations`)."
  def decorations(root) do
    :ets.match(@table, {{:decorations, root, :_}, :_, :"$1"})
    |> Enum.reduce(%{}, fn [decorations], acc -> Map.merge(acc, decorations) end)
  end

  @doc "Replaces `owner`'s file decorations in workspace `root`. Raises on bad data."
  def put_decorations(root, owner, decorations) when is_binary(root) do
    decorations = Bee.UI.Decorations.normalize!(decorations)
    GenServer.call(__MODULE__, {:put, {:decorations, root, owner}, owner, decorations})
  end

  ## Context keys

  @doc """
  Context keys set by plugins (VS Code's `setContext`) in workspace `root`,
  merged into its windows' `when` context: `%{key => value}`.
  """
  def context(root) do
    :ets.match(@table, {{:context, root, :_, :"$1"}, :_, :"$2"})
    |> Map.new(fn [key, value] -> {key, value} end)
  end

  @doc "Sets context key `key` (JSON-like value) for `owner` in workspace `root`; `nil` removes it."
  def put_context(root, owner, key, nil) when is_binary(root),
    do: GenServer.call(__MODULE__, {:delete, {:context, root, owner, key}})

  def put_context(root, owner, key, value) when is_binary(root),
    do: GenServer.call(__MODULE__, {:put, {:context, root, owner, key}, owner, value})

  ## Forgetting

  @doc "Removes everything `owner` put on screen, in every workspace (it was unloaded)."
  def forget(owner), do: GenServer.call(__MODULE__, {:forget, fn _root, o -> o == owner end})

  @doc "Removes everything plugins put on screen in workspace `root` (it was closed)."
  def forget_workspace(root),
    do: GenServer.call(__MODULE__, {:forget, fn r, _owner -> r == root end})

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

  def handle_call({:forget, match?}, _from, state) do
    for {key, owner, _} <- :ets.tab2list(@table), match?.(elem(key, 1), owner) do
      :ets.delete(@table, key)
      broadcast(key)
    end

    {:reply, :ok, state}
  end

  # Every key has the workspace's root second.
  defp broadcast(key),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, topic(elem(key, 1)), {:ui_changed, change(key)})

  defp change({:view, _root, id}), do: {:view, id}
  defp change({:status, _root, _owner, _id}), do: :status_items
  defp change({:decorations, _root, _owner}), do: :decorations
  defp change({:context, _root, _owner, _key}), do: :context
end

defmodule Bee.Diagnostics do
  @moduledoc """
  The problems language extensions find in files (VS Code's diagnostics):
  errors, warnings and hints with their place, for the editor to underline
  and the window to count.

  Kept per workspace, file and owner – an extension's diagnostic collection
  (`Bee.Extensions.Host` files them as its extensions set them) – in ETS;
  a file's are those of all its owners. A change broadcasts
  `{:diagnostics_changed, path}` on the workspace's topic (`subscribe/1`).

  A diagnostic:

      %{
        from: %{line: 3, character: 2},   # zero-based; characters are UTF-16
        to: %{line: 3, character: 9},     # units, as editors count them
        severity: :error | :warning | :info | :hint,
        message: "undefined function foo/0",
        source: "Elixir" | nil,           # who found it
        code: "E123" | nil,
        owner: "elixir-ls/…"
      }
  """
  use GenServer

  @table __MODULE__
  @severities %{"error" => :error, "warning" => :warning, "info" => :info, "hint" => :hint}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Changes of workspace `root`'s diagnostics: `{:diagnostics_changed, path}`."
  def subscribe(root), do: Phoenix.PubSub.subscribe(Bee.PubSub, topic(root))

  defp topic(root), do: "diagnostics:" <> root

  @doc """
  Sets `owner`'s diagnostics of file `path` in workspace `root` (none: `[]`).
  They are maps as in the moduledoc, with atom or string keys (as an
  extension sent them); what isn't one is left out.
  """
  def put(root, owner, path, diagnostics) when is_binary(root) and is_binary(path) do
    case diagnostics |> List.wrap() |> Enum.flat_map(&normalize(&1, owner)) do
      [] -> :ets.delete(@table, {root, path, owner})
      list -> :ets.insert(@table, {{root, path, owner}, list})
    end

    changed(root, path)
  end

  @doc "Removes the diagnostics of every owner starting with `prefix` in workspace `root`."
  def clear(root, prefix \\ "") do
    for {{^root, path, owner} = key, _} <- :ets.match_object(@table, {{root, :_, :_}, :_}),
        String.starts_with?(owner, prefix) do
      :ets.delete(@table, key)
      changed(root, path)
    end

    :ok
  end

  @doc "The diagnostics of file `path` in workspace `root`, in file order."
  def for_file(root, path) do
    @table
    |> :ets.match_object({{root, path, :_}, :_})
    |> Enum.flat_map(&elem(&1, 1))
    |> sort()
  end

  @doc "Every file's diagnostics in workspace `root`: `%{path => [diagnostic]}`."
  def all(root) do
    @table
    |> :ets.match_object({{root, :_, :_}, :_})
    |> Enum.group_by(fn {{_root, path, _owner}, _} -> path end, &elem(&1, 1))
    |> Map.new(fn {path, lists} -> {path, sort(List.flatten(lists))} end)
  end

  @doc "How many there are in workspace `root`, by severity: `%{error: 2, warning: 5}`."
  def counts(root) do
    root |> all() |> Map.values() |> List.flatten() |> Enum.frequencies_by(& &1.severity)
  end

  defp sort(list), do: Enum.sort_by(list, &{&1.from.line, &1.from.character, &1.to.line})

  defp changed(root, path),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, topic(root), {:diagnostics_changed, path})

  defp normalize(%{} = d, owner) do
    with %{line: _, character: _} = from <- position(get(d, :from)),
         %{line: _, character: _} = to <- position(get(d, :to)),
         message when is_binary(message) <- get(d, :message) do
      severity = get(d, :severity)

      [
        %{
          from: from,
          to: to,
          severity:
            if(is_atom(severity) and severity in Map.values(@severities),
              do: severity,
              else: Map.get(@severities, severity, :error)
            ),
          message: message,
          source: string(get(d, :source)),
          code: string(get(d, :code)),
          owner: owner
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize(_other, _owner), do: []

  defp position(%{} = p) do
    with line when is_integer(line) and line >= 0 <- get(p, :line),
         character when is_integer(character) and character >= 0 <- get(p, :character) do
      %{line: line, character: character}
    else
      _ -> nil
    end
  end

  defp position(_other), do: nil

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  ## Server: owns the table.

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end

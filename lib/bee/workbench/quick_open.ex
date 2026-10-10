defmodule Bee.Workbench.QuickOpen do
  @moduledoc """
  Quick Open (VS Code's Ctrl+P), the title bar's search box: what its query
  means, and the file search behind it.

    * `""` – the recently opened files (`Bee.Workspace.RecentFiles`), after
      the ways to go elsewhere (`modes/0`: `>` for commands)
    * `>…` – commands (the command palette)
    * `@…` – the symbols of the shown file, `#…` – those of the workspace,
      as its language extensions know them (`Bee.Languages.Features`)
    * anything else – files of the workspace, by name
  """

  @doc """
  The query's mode: `{:commands, rest}`, `{:symbols, rest}`,
  `{:workspace_symbols, rest}`, `:recent` or `{:files, query}`.
  """
  def mode(">" <> rest), do: {:commands, String.trim(rest)}
  def mode("@" <> rest), do: {:symbols, rest}
  def mode("#" <> rest), do: {:workspace_symbols, String.trim(rest)}
  def mode(query), do: if(String.trim(query) == "", do: :recent, else: {:files, query})

  @doc "Other modes, by prefix, offered while the query is empty."
  def modes do
    [
      %{prefix: ">", label: "Show and Run Commands"},
      %{prefix: "@", label: "Go to Symbol in Editor"},
      %{prefix: "#", label: "Go to Symbol in Workspace"}
    ]
  end

  @typedoc "A file prepared for searching: its path and name lowercased once."
  @type entry :: {lower_path :: String.t(), lower_name :: String.t(), path :: String.t()}

  @doc "Prepares a relative path for `match/2`."
  def entry(rel) do
    lower = String.downcase(rel)
    {lower, Path.basename(lower), rel}
  end

  @doc "The query as it is matched: lowercase, without spaces."
  def normalize(query), do: query |> String.downcase() |> String.replace(" ", "")

  @doc """
  Every entry that matches `query` (normalized), with its score:
  `[{score, entry}]`, unsorted.
  """
  def match(entries, query),
    do: for(e <- entries, score = score(e, query), score != nil, do: {score, e})

  @doc """
  `match/2` among the matches of a shorter query that `query` starts with:
  only those can match it, so typing on searches fewer and fewer files.
  """
  def narrow(matches, query), do: match(for({_score, e} <- matches, do: e), query)

  @doc "The `limit` best of `matches`, best first: their paths."
  def top(matches, limit \\ 50) do
    # Best score first, sorting only as many groups as it takes: a short
    # query matches nearly everything.
    matches
    |> Enum.group_by(&elem(&1, 0), fn {_score, {_, _, rel}} -> rel end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce_while([], fn {_score, rels}, acc ->
      acc = acc ++ Enum.take(Enum.sort_by(rels, &{byte_size(&1), &1}), limit - length(acc))
      if length(acc) >= limit, do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  @doc """
  The best matches of `query` among `files` (relative paths), at most
  `limit`, best first. Every query character must appear in order; a match
  in the file's name beats one in its folders, a whole word beats scattered
  letters, and shorter paths win ties. Spaces are ignored.
  """
  def search(files, query, limit \\ 50) do
    files |> Enum.map(&entry/1) |> match(normalize(query)) |> top(limit)
  end

  defp score(_entry, ""), do: 0

  defp score({path, name, _rel}, q) do
    cond do
      name == q -> 6
      String.starts_with?(name, q) -> 5
      :binary.match(name, q) != :nomatch -> 4
      subsequence?(name, q) -> 3
      :binary.match(path, q) != :nomatch -> 2
      subsequence?(path, q) -> 1
      true -> nil
    end
  end

  @doc "Every character of `q` appears in `text`, in order."
  def subsequence?(text, q), do: subsequence?(text, q, 0)

  defp subsequence?(_text, "", _from), do: true

  defp subsequence?(text, <<c::utf8, rest::binary>>, from) do
    case :binary.match(text, <<c::utf8>>, scope: {from, byte_size(text) - from}) do
      {at, len} -> subsequence?(text, rest, at + len)
      :nomatch -> false
    end
  end
end

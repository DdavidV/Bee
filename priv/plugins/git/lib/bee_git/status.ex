defmodule BeeGit.Status do
  @moduledoc """
  Parses `git status --porcelain=v1 -z --branch --untracked-files=all
  --ignored=matching`.

  Returns `%{branch, upstream, ahead, behind, entries}`; an entry is
  `%{path, from, group, letter, color, label}` where `group` is `:conflict`,
  `:staged`, `:change` (a file can be both staged and changed) or
  `:ignored` (a path ending in "/" is a whole ignored folder), `path`
  relative to the repository and `from` the old path of a rename.
  """

  @spec parse(String.t()) :: map()
  def parse(output) do
    {header, records} =
      case String.split(output, <<0>>, trim: true) do
        ["## " <> header | rest] -> {header, rest}
        rest -> {"", rest}
      end

    Map.put(branch(header), :entries, entries(records, []))
  end

  # "main...origin/main [ahead 1, behind 2]", "No commits yet on main",
  # "HEAD (no branch)"
  defp branch(header) do
    {name_part, counts} =
      case Regex.run(~r/^(.*?)(?: \[(.*)\])?$/, header) do
        [_, name, counts] -> {name, counts}
        [_, name] -> {name, ""}
      end

    {branch, upstream} =
      case name_part do
        "No commits yet on " <> name -> {name, nil}
        "Initial commit on " <> name -> {name, nil}
        "HEAD (no branch)" -> {"HEAD", nil}
        other -> parse_upstream(other)
      end

    %{
      branch: branch,
      upstream: upstream,
      ahead: count(counts, "ahead"),
      behind: count(counts, "behind")
    }
  end

  defp parse_upstream(name) do
    case String.split(name, "...", parts: 2) do
      [branch, upstream] -> {branch, upstream}
      [branch] -> {branch, nil}
    end
  end

  defp count(counts, word) do
    case Regex.run(~r/#{word} (\d+)/, counts) do
      [_, n] -> String.to_integer(n)
      nil -> 0
    end
  end

  defp entries([], acc), do: Enum.reverse(acc)

  defp entries([<<x, y, " ", path::binary>> | rest], acc) do
    # Renames and copies are followed by their old path.
    {from, rest} =
      if x in [?R, ?C] or y in [?R, ?C],
        do: {hd(rest), tl(rest)},
        else: {nil, rest}

    entries(rest, Enum.reverse(classify(<<x>>, <<y>>, path, from), acc))
  end

  defp entries([_other | rest], acc), do: entries(rest, acc)

  @conflicts [{"D", "D"}, {"A", "A"}, {"U", "U"}, {"A", "U"}, {"U", "D"}, {"U", "A"}, {"D", "U"}]

  defp classify(x, y, path, from) do
    cond do
      {x, y} in @conflicts ->
        [entry(path, from, :conflict, "!", "conflict", "Conflict")]

      {x, y} == {"?", "?"} ->
        [entry(path, from, :change, "U", "untracked", "Untracked")]

      {x, y} == {"!", "!"} ->
        [entry(path, from, :ignored, nil, "ignored", "Ignored")]

      true ->
        staged = if x != " ", do: [entry(path, from, :staged, x, color(x), label(x))], else: []
        changed = if y != " ", do: [entry(path, from, :change, y, color(y), label(y))], else: []
        staged ++ changed
    end
  end

  defp entry(path, from, group, letter, color, label),
    do: %{path: path, from: from, group: group, letter: letter, color: color, label: label}

  defp color("A"), do: "added"
  defp color("D"), do: "deleted"
  defp color(_), do: "modified"

  defp label("M"), do: "Modified"
  defp label("A"), do: "Index Added"
  defp label("D"), do: "Deleted"
  defp label("R"), do: "Renamed"
  defp label("C"), do: "Copied"
  defp label("T"), do: "Type Changed"
  defp label(other), do: other
end

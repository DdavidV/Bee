defmodule Bee.Diff do
  @moduledoc """
  The difference of two texts by line, for showing: the changed lines with
  some of the lines around them, like a unified diff.
  """

  @type row ::
          {:eq | :del | :ins, old :: pos_integer() | nil, new :: pos_integer() | nil, String.t()}
          | :gap

  @doc """
  The rows of `original` → `modified`: `{:eq, old, new, text}` (a line of
  both, with its number in each), `{:del, old, nil, text}`, `{:ins, nil,
  new, text}`, and `:gap` where unchanged lines were left out – all but
  `context` of them around each change. No rows: the texts are the same.
  """
  @spec rows(String.t(), String.t(), non_neg_integer()) :: [row]
  def rows(original, modified, context \\ 3) do
    {rows, _old, _new} =
      lines(original)
      |> List.myers_difference(lines(modified))
      |> Enum.reduce({[], 1, 1}, fn
        {:eq, lines}, {rows, old, new} ->
          numbered = for {line, i} <- Enum.with_index(lines), do: {:eq, old + i, new + i, line}
          {[numbered | rows], old + length(lines), new + length(lines)}

        {:del, lines}, {rows, old, new} ->
          numbered = for {line, i} <- Enum.with_index(lines), do: {:del, old + i, nil, line}
          {[numbered | rows], old + length(lines), new}

        {:ins, lines}, {rows, old, new} ->
          numbered = for {line, i} <- Enum.with_index(lines), do: {:ins, nil, new + i, line}
          {[numbered | rows], old, new + length(lines)}
      end)

    rows = rows |> Enum.reverse() |> List.flatten()
    if Enum.all?(rows, &(elem(&1, 0) == :eq)), do: [], else: trim(rows, context)
  end

  # (A final line break isn't a line of its own.)
  defp lines(""), do: []

  defp lines(text) do
    text |> String.replace("\r\n", "\n") |> String.replace_suffix("\n", "") |> String.split("\n")
  end

  # The unchanged lines further than `context` from a change: a gap.
  defp trim(rows, context) do
    near =
      for {row, index} <- Enum.with_index(rows),
          elem(row, 0) != :eq,
          kept <- (index - context)..(index + context),
          into: MapSet.new(),
          do: kept

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} -> if MapSet.member?(near, index), do: row, else: :gap end)
    |> Enum.dedup()
    |> Enum.drop_while(&(&1 == :gap))
  end
end

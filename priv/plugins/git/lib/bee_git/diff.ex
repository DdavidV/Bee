defmodule BeeGit.Diff do
  @moduledoc """
  Parses a `-U0` diff into what the editor needs:

    * the change gutter: `added: [[from, to]]`, `modified: [[from, to]]`,
      `deleted: [line]` – 1-based lines of the new text; a deletion is marked
      on the line after which lines went away (0 for the top)
    * the change peek (clicking a marker): `hunks: [%{old_start, old_count,
      new_start, new_count, old_lines}]`, `old_lines` being the original text
      the hunk replaces

  `apply_hunk/3` applies one hunk to the original text (to stage it).
  """

  def parse(output) do
    hunks = hunks(output)

    Enum.reduce(hunks, %{added: [], modified: [], deleted: [], hunks: hunks}, fn h, acc ->
      cond do
        h.new_count == 0 ->
          %{acc | deleted: acc.deleted ++ [h.new_start]}

        h.old_count == 0 ->
          %{acc | added: acc.added ++ [[h.new_start, h.new_start + h.new_count - 1]]}

        true ->
          %{acc | modified: acc.modified ++ [[h.new_start, h.new_start + h.new_count - 1]]}
      end
    end)
  end

  defp hunks(output) do
    output
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/, line) do
        [_ | captures] ->
          [old_start, old_count, new_start, new_count] =
            Enum.take(captures ++ ["", "", "", ""], 4)

          hunk = %{
            old_start: String.to_integer(old_start),
            old_count: count(old_count),
            new_start: String.to_integer(new_start),
            new_count: count(new_count),
            old_lines: []
          }

          [hunk | acc]

        nil ->
          case {line, acc} do
            {"-" <> text, [hunk | rest]} -> [%{hunk | old_lines: hunk.old_lines ++ [text]} | rest]
            _ -> acc
          end
      end
    end)
    |> Enum.reverse()
  end

  defp count(""), do: 1
  defp count(n), do: String.to_integer(n)

  @doc """
  `original` with one hunk replaced by `lines`: its `old_count` lines from
  `old_start` (with no old lines, `lines` go after `old_start`). Returns
  `{:ok, text}`, or `{:error, :outdated}` when `original` no longer has the
  hunk's `old_lines` there.
  """
  def apply_hunk(original, hunk, lines) do
    old = String.split(original, "\n")

    {before, rest} =
      if hunk.old_count == 0,
        do: Enum.split(old, hunk.old_start),
        else: Enum.split(old, hunk.old_start - 1)

    if Enum.take(rest, hunk.old_count) == hunk.old_lines,
      do: {:ok, Enum.join(before ++ lines ++ Enum.drop(rest, hunk.old_count), "\n")},
      else: {:error, :outdated}
  end
end

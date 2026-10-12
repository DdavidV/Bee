defmodule Bee.Editor.Positions do
  @moduledoc """
  Places in a text as the browser's editor and extensions count them: a
  zero-based line and a character in it, in UTF-16 units (`%{"line" => 3,
  "character" => 7}`, as they come in JSON) – and as Bee counts them, in
  UTF-8 bytes.

  An editor says what was typed by position (`Bee.Editor.Buffer.change/3`),
  so that neither side has to go through the whole text to say where:
  finding a line is a search for line breaks, and only the one line is
  looked at character by character.

  Lines end with `\\n`, a `\\r` before it being part of the break, as in the
  browser's editor. A `\\r` on its own is a line break there but not here:
  positions can't be trusted in a text that has one (`line_breaks_agree?/1`).
  """

  @type position :: %{required(String.t()) => non_neg_integer()}

  @doc "Whether lines are the same here and in the browser's editor: no `\\r` without its `\\n`."
  def line_breaks_agree?(text) do
    case :binary.match(text, "\r") do
      :nomatch -> true
      _ -> not Regex.match?(~r/\r(?!\n)/, text)
    end
  end

  @doc """
  The byte offsets of `positions` in `text`, in their order: `{:ok,
  [offset], line}`, or `:error` when one isn't a place in the text (a line
  it doesn't have, a character past the line's end or inside a character).

  `line` is where the first of their lines starts, `{line, offset}`. Given
  again as `known` for the next positions in a text that is the same up
  to there, they are found from it, not from the start of the text: what
  is typed is mostly on the line typed in before, however far down.
  """
  @spec to_bytes(binary(), [position], {non_neg_integer(), non_neg_integer()}) ::
          {:ok, [non_neg_integer()], {non_neg_integer(), non_neg_integer()}} | :error
  def to_bytes(text, positions, known \\ {0, 0})

  def to_bytes(_text, [], known), do: {:ok, [], known}

  def to_bytes(text, positions, {known_line, _} = known) do
    # One pass over the text, for the positions in file order.
    sorted =
      positions
      |> Enum.with_index()
      |> Enum.sort_by(fn {position, _} -> {position["line"], position["character"]} end)

    {line, start} =
      case sorted do
        [{%{"line" => first}, _} | _] when is_integer(first) and first >= known_line -> known
        _ -> {0, 0}
      end

    sorted
    |> Enum.reduce_while({line, start, nil, []}, fn {position, index},
                                                    {line, start, first, found} ->
      with %{"line" => to, "character" => character}
           when is_integer(to) and is_integer(character) and to >= line and character >= 0 <-
             position,
           start when is_integer(start) <- line_start(text, start, to - line),
           column when is_integer(column) <- column(text, start, character) do
        {:cont, {to, start, first || {to, start}, [{index, start + column} | found]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error ->
        :error

      {_line, _start, first, found} ->
        {:ok, found |> Enum.sort() |> Enum.map(&elem(&1, 1)), first}
    end
  end

  # Where the line `lines` after the one starting at `offset` starts, or
  # nil when the text ends before.
  defp line_start(_text, offset, 0), do: offset

  defp line_start(text, offset, lines) do
    case :binary.match(text, "\n", scope: {offset, byte_size(text) - offset}) do
      {at, 1} -> line_start(text, at + 1, lines - 1)
      :nomatch -> nil
    end
  end

  # The bytes of the first `character` UTF-16 units of the line at `start`,
  # or nil when it has fewer.
  defp column(_text, _start, 0), do: 0

  defp column(text, start, character) do
    stop =
      case :binary.match(text, "\n", scope: {start, byte_size(text) - start}) do
        {at, 1} -> at
        :nomatch -> byte_size(text)
      end

    # (The break's \r isn't in the line.)
    stop = if stop > start and :binary.at(text, stop - 1) == ?\r, do: stop - 1, else: stop
    units(binary_part(text, start, stop - start), character, 0)
  end

  defp units(_line, 0, bytes), do: bytes

  defp units(<<c::utf8, rest::binary>>, n, bytes) when c > 0xFFFF and n >= 2,
    do: units(rest, n - 2, bytes + 4)

  defp units(<<c::utf8, rest::binary>>, n, bytes) when c <= 0xFFFF,
    do: units(rest, n - 1, bytes + byte_size(<<c::utf8>>))

  defp units(_line, _n, _bytes), do: nil
end

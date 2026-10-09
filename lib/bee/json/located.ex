defmodule Bee.JSON.Located do
  @moduledoc """
  Parses JSON (with comments and trailing commas, like `Bee.JSON.JSONC`)
  and records where every value is, so problems found in the decoded data –
  JSON Schema errors – can be shown at the right place in the text.

  `parse/1` gives `{:ok, value, locations}`: `locations` maps each value's
  path (a list of keys, array indices as strings, `[]` for the root) to
  `%{from, to}` (byte offsets of the value) plus `key_from`/`key_to` (its
  key's) for object members. `{:error, message, offset}` for invalid JSON.
  """

  @type location :: %{
          required(:from) => non_neg_integer(),
          required(:to) => non_neg_integer(),
          optional(:key_from) => non_neg_integer(),
          optional(:key_to) => non_neg_integer()
        }

  @spec parse(String.t()) ::
          {:ok, term(), %{[String.t()] => location}} | {:error, String.t(), non_neg_integer()}
  def parse(text) do
    {value, i, locs} = value(text, ws(text, 0), [], %{})
    i = ws(text, i)

    if i < byte_size(text),
      do: {:error, "Unexpected text after the end", i},
      else: {:ok, value, locs}
  catch
    {:json_error, message, offset} -> {:error, message, offset}
  end

  defp fail(message, offset), do: throw({:json_error, message, offset})

  defp at(text, i) when i < byte_size(text), do: :binary.at(text, i)
  defp at(_text, _i), do: nil

  # Whitespace and comments.
  defp ws(text, i) do
    case at(text, i) do
      c when c in [?\s, ?\t, ?\n, ?\r] ->
        ws(text, i + 1)

      ?/ ->
        case at(text, i + 1) do
          ?/ ->
            case :binary.match(text, "\n", scope: {i, byte_size(text) - i}) do
              {nl, _} -> ws(text, nl + 1)
              :nomatch -> byte_size(text)
            end

          ?* ->
            case :binary.match(text, "*/", scope: {i + 2, byte_size(text) - i - 2}) do
              {end_, _} -> ws(text, end_ + 2)
              :nomatch -> fail("Unterminated comment", i)
            end

          _ ->
            i
        end

      _ ->
        i
    end
  end

  defp value(text, i, path, locs) do
    {value, to, locs} =
      case at(text, i) do
        ?{ -> object(text, ws(text, i + 1), path, %{}, locs, i)
        ?[ -> array(text, ws(text, i + 1), path, [], 0, locs, i)
        ?" -> string(text, i, locs)
        c when c == ?- or c in ?0..?9 -> number(text, i, locs)
        nil -> fail("Value expected", i)
        _ -> literal(text, i, locs)
      end

    {value, to, Map.update(locs, path, %{from: i, to: to}, &Map.merge(&1, %{from: i, to: to}))}
  end

  defp object(text, i, path, acc, locs, start) do
    case at(text, i) do
      ?} ->
        {acc, i + 1, locs}

      ?" ->
        {key, key_to, locs} = string(text, i, locs)
        member = path ++ [key]
        locs = Map.put(locs, member, %{key_from: i, key_to: key_to})
        i = ws(text, key_to)
        if at(text, i) != ?:, do: fail("Colon expected", i)
        {value, i, locs} = value(text, ws(text, i + 1), member, locs)
        acc = Map.put(acc, key, value)
        i = ws(text, i)

        case at(text, i) do
          ?, -> object(text, ws(text, i + 1), path, acc, locs, start)
          ?} -> {acc, i + 1, locs}
          _ -> fail("Comma or } expected", i)
        end

      nil ->
        fail("Unterminated object", start)

      _ ->
        fail("Property name expected (in double quotes)", i)
    end
  end

  defp array(text, i, path, acc, n, locs, start) do
    case at(text, i) do
      ?] ->
        {Enum.reverse(acc), i + 1, locs}

      nil ->
        fail("Unterminated array", start)

      _ ->
        {value, i, locs} = value(text, i, path ++ [Integer.to_string(n)], locs)
        i = ws(text, i)

        case at(text, i) do
          ?, -> array(text, ws(text, i + 1), path, [value | acc], n + 1, locs, start)
          ?] -> {Enum.reverse([value | acc]), i + 1, locs}
          _ -> fail("Comma or ] expected", i)
        end
    end
  end

  defp string(text, i, locs) do
    to = string_end(text, i + 1)

    case Jason.decode(binary_part(text, i, to - i)) do
      {:ok, s} -> {s, to, locs}
      {:error, _} -> fail("Invalid string", i)
    end
  end

  defp string_end(text, i) do
    case at(text, i) do
      ?" -> i + 1
      ?\\ -> string_end(text, i + 2)
      ?\n -> fail("Unterminated string", i)
      nil -> fail("Unterminated string", i)
      _ -> string_end(text, i + 1)
    end
  end

  defp number(text, i, locs) do
    [match] =
      Regex.run(
        ~r/-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/,
        binary_part(text, i, min(byte_size(text) - i, 400))
      )

    if match in ["", "-"], do: fail("Invalid number", i)
    {Jason.decode!(match), i + byte_size(match), locs}
  end

  defp literal(text, i, locs) do
    rest = binary_part(text, i, min(byte_size(text) - i, 5))

    cond do
      String.starts_with?(rest, "true") -> {true, i + 4, locs}
      String.starts_with?(rest, "false") -> {false, i + 5, locs}
      String.starts_with?(rest, "null") -> {nil, i + 4, locs}
      true -> fail("Value expected", i)
    end
  end
end

defmodule Bee.JSON.JSONC do
  @moduledoc """
  "JSON with comments", as used by VS Code's settings and keybindings files:
  `//` and `/* */` comments and trailing commas are allowed.

  Comments are blanked out (newlines kept) and trailing commas removed before
  handing the text to Jason, so error positions still point at the right
  line and column of the original text.
  """

  @spec decode(String.t()) :: {:ok, term()} | {:error, String.t()}
  def decode(text) do
    text = text |> strip_comments() |> strip_trailing_commas()

    case Jason.decode(text) do
      {:ok, value} ->
        {:ok, value}

      {:error, %Jason.DecodeError{position: pos, data: data} = error} ->
        {line, col} = line_col(data, pos)
        {:error, "#{Exception.message(error)} (line #{line}, column #{col})"}
    end
  end

  @doc """
  Sets the top-level `key` of the object in `text` to `value` (encoded as
  JSON), keeping everything else – comments, order, formatting – as it
  is. A key that isn't there yet is added after the last one, or at the
  end of an object that has none (e.g. one with only comments).
  """
  @spec put(String.t(), String.t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def put(text, key, value) do
    with {:ok, %{}} <- decode(text) do
      # Offsets in the stripped text are those of the original.
      code = text |> strip_comments() |> strip_trailing_commas()
      {members, close} = members(code)
      json = Jason.encode!(value)

      case {List.keyfind(Enum.reverse(members), key, 0), members} do
        {{_key, _key_start, from, to}, _} ->
          {:ok, splice(text, from, to, json)}

        {nil, []} ->
          before = if close > 0 and :binary.at(text, close - 1) == ?\n, do: "", else: "\n"
          {:ok, splice(text, close, close, "#{before}  #{Jason.encode!(key)}: #{json}\n")}

        {nil, _} ->
          {_key, key_start, _from, to} = List.last(members)
          entry = "#{indent(text, key_start)}#{Jason.encode!(key)}: #{json}"
          {:ok, splice(text, to, to, ",\n" <> entry)}
      end
    else
      {:ok, _not_an_object} -> {:error, "must contain a JSON object"}
      error -> error
    end
  end

  defp splice(text, from, to, insert),
    do: binary_part(text, 0, from) <> insert <> binary_part(text, to, byte_size(text) - to)

  # The whitespace the line holding `offset` starts with.
  defp indent(text, offset) do
    line_start =
      case :binary.matches(binary_part(text, 0, offset), "\n") do
        [] -> 0
        matches -> elem(List.last(matches), 0) + 1
      end

    [indent] = Regex.run(~r/^[ \t]*/, binary_part(text, line_start, offset - line_start))
    indent
  end

  # The top-level members of valid, comment-free JSON: [{key, key_start,
  # value_start, value_end}], and the offset of the closing brace.
  defp members(code) do
    i = skip_ws(code, 0)
    ?{ = :binary.at(code, i)
    do_members(code, skip_ws(code, i + 1), [])
  end

  defp do_members(code, i, acc) do
    case :binary.at(code, i) do
      ?} ->
        {Enum.reverse(acc), i}

      ?, ->
        do_members(code, skip_ws(code, i + 1), acc)

      ?" ->
        key_end = string_end(code, i + 1)
        key = Jason.decode!(binary_part(code, i, key_end - i))
        colon = skip_ws(code, key_end)
        from = skip_ws(code, colon + 1)
        to = value_end(code, from)
        do_members(code, skip_ws(code, to), [{key, i, from, to} | acc])
    end
  end

  defp skip_ws(code, i) do
    if i < byte_size(code) and :binary.at(code, i) in ~c" \t\r\n",
      do: skip_ws(code, i + 1),
      else: i
  end

  # `i` is just past the opening quote; returns the offset past the closing one.
  defp string_end(code, i) do
    case :binary.at(code, i) do
      ?\\ -> string_end(code, i + 2)
      ?" -> i + 1
      _ -> string_end(code, i + 1)
    end
  end

  defp value_end(code, i) do
    case :binary.at(code, i) do
      ?" -> string_end(code, i + 1)
      c when c in [?{, ?[] -> nested_end(code, i + 1, 1)
      _ -> scalar_end(code, i)
    end
  end

  defp nested_end(_code, i, 0), do: i

  defp nested_end(code, i, depth) do
    case :binary.at(code, i) do
      ?" -> nested_end(code, string_end(code, i + 1), depth)
      c when c in [?{, ?[] -> nested_end(code, i + 1, depth + 1)
      c when c in [?}, ?]] -> nested_end(code, i + 1, depth - 1)
      _ -> nested_end(code, i + 1, depth)
    end
  end

  defp scalar_end(code, i) do
    if i < byte_size(code) and :binary.at(code, i) not in ~c",}] \t\r\n",
      do: scalar_end(code, i + 1),
      else: i
  end

  # Comments become spaces (keeping newlines) so offsets don't move.
  defp strip_comments(text), do: text |> do_strip(:code, []) |> IO.iodata_to_binary()

  defp do_strip(<<>>, _mode, acc), do: Enum.reverse(acc)

  defp do_strip(<<"\"", rest::binary>>, :code, acc), do: do_strip(rest, :string, ["\"" | acc])

  defp do_strip(<<"//", rest::binary>>, :code, acc),
    do: do_strip(rest, :line_comment, ["  " | acc])

  defp do_strip(<<"/*", rest::binary>>, :code, acc),
    do: do_strip(rest, :block_comment, ["  " | acc])

  defp do_strip(<<"\\", c::utf8, rest::binary>>, :string, acc),
    do: do_strip(rest, :string, [<<c::utf8>>, "\\" | acc])

  defp do_strip(<<"\"", rest::binary>>, :string, acc), do: do_strip(rest, :code, ["\"" | acc])

  defp do_strip(<<"\n", rest::binary>>, :line_comment, acc),
    do: do_strip(rest, :code, ["\n" | acc])

  defp do_strip(<<"*/", rest::binary>>, :block_comment, acc),
    do: do_strip(rest, :code, ["  " | acc])

  defp do_strip(<<"\n", rest::binary>>, mode, acc) when mode == :block_comment,
    do: do_strip(rest, mode, ["\n" | acc])

  defp do_strip(<<c::utf8, rest::binary>>, mode, acc)
       when mode in [:line_comment, :block_comment],
       do: do_strip(rest, mode, [String.duplicate(" ", byte_size(<<c::utf8>>)) | acc])

  defp do_strip(<<c::utf8, rest::binary>>, mode, acc),
    do: do_strip(rest, mode, [<<c::utf8>> | acc])

  # A comma followed (after whitespace) by } or ] is replaced by a space.
  defp strip_trailing_commas(text), do: text |> do_commas(:code, []) |> IO.iodata_to_binary()

  defp do_commas(<<>>, _mode, acc), do: Enum.reverse(acc)
  defp do_commas(<<"\"", rest::binary>>, :code, acc), do: do_commas(rest, :string, ["\"" | acc])

  defp do_commas(<<"\\", c::utf8, rest::binary>>, :string, acc),
    do: do_commas(rest, :string, [<<c::utf8>>, "\\" | acc])

  defp do_commas(<<"\"", rest::binary>>, :string, acc), do: do_commas(rest, :code, ["\"" | acc])

  defp do_commas(<<",", rest::binary>>, :code, acc) do
    case String.trim_leading(rest) do
      <<c, _::binary>> when c in [?}, ?]] -> do_commas(rest, :code, [" " | acc])
      _ -> do_commas(rest, :code, [?, | acc])
    end
  end

  defp do_commas(<<c::utf8, rest::binary>>, mode, acc),
    do: do_commas(rest, mode, [<<c::utf8>> | acc])

  defp line_col(data, pos) do
    before = binary_part(data, 0, min(pos, byte_size(data)))
    lines = String.split(before, "\n")
    {length(lines), String.length(List.last(lines)) + 1}
  end
end

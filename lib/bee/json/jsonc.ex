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

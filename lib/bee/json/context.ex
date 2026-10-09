defmodule Bee.JSON.Context do
  @moduledoc """
  Where a position is in JSON text that is being edited – so usually not
  valid JSON (`{"na`, a missing comma) – for completion and hover:

      %{kind: :key | :value, path: [String.t()], from: offset, to: offset,
        token: String.t() | nil, keys: %{path => [key]}}

  `kind`/`path`: a key of the object at `path`, or the value at `path`
  (array indices as strings). `from`-`to`: the key or value the position
  is in (what a completion replaces), or the position itself between
  tokens. `token`: that key's or value's text, decoded for strings.
  `keys`: every object's keys, by its path, in the whole text.

  Byte offsets. Comments are skipped; anything unexpected is passed over.
  """

  @doc "The context of byte offset `offset` in `text`."
  def at(text, offset) do
    offset = offset |> max(0) |> min(byte_size(text))
    state = %{stack: [%{type: :root, path: [], expect: :value}], keys: %{}, found: nil}
    state = scan(text, 0, offset, state)
    state = if state.found, do: state, else: found(state, offset, offset, nil)

    Map.put(
      state.found,
      :keys,
      Map.new(state.keys, fn {path, keys} -> {path, Enum.reverse(keys)} end)
    )
  end

  defp scan(text, i, _offset, state) when i >= byte_size(text), do: state

  defp scan(text, i, offset, state) do
    case :binary.at(text, i) do
      c when c in [?\s, ?\t, ?\n, ?\r] ->
        scan(text, i + 1, offset, state)

      ?/ ->
        scan(text, comment_end(text, i), offset, state)

      ?" ->
        to = string_end(text, i + 1)
        state = before(state, i, offset)

        state =
          if state.found == nil and offset > i and offset <= to,
            do: found(state, i, to, decode(text, i, to), :string),
            else: state

        scan(text, to, offset, string(state, decode(text, i, to)))

      c when c in [?{, ?[] ->
        state = before(state, i, offset)
        scan(text, i + 1, offset, open(state, if(c == ?{, do: :object, else: :array)))

      c when c in [?}, ?]] ->
        state = before(state, i, offset)
        scan(text, i + 1, offset, close(state))

      ?: ->
        state = before(state, i, offset)
        scan(text, i + 1, offset, update_top(state, &%{&1 | expect: :value}))

      ?, ->
        state = before(state, i, offset)
        scan(text, i + 1, offset, comma(state))

      _ ->
        to = scalar_end(text, i)
        state = before(state, i, offset)
        token = binary_part(text, i, to - i)

        state =
          if state.found == nil and offset > i and offset <= to,
            do: found(state, i, to, token),
            else: state

        scan(text, to, offset, value_done(state))
    end
  end

  # The position is before the token at `i` (between tokens): found here.
  defp before(%{found: nil} = state, i, offset) when offset <= i,
    do: found(state, offset, offset, nil)

  defp before(state, _i, _offset), do: state

  # A string where a comma was due starts the next member: a key.
  defp found(state, from, to, token, token_kind \\ nil)

  defp found(%{stack: [top | _]} = state, from, to, token, token_kind) do
    {kind, path} =
      case top do
        %{type: :object, expect: e} when e in [:key, :colon] -> {:key, top.path}
        %{type: :object, expect: :after} when token_kind == :string -> {:key, top.path}
        %{type: :object, key: key} when is_binary(key) -> {:value, top.path ++ [key]}
        %{type: :object} -> {:key, top.path}
        %{type: :array, index: n} -> {:value, top.path ++ [Integer.to_string(n)]}
        %{type: :root} -> {:value, []}
      end

    %{state | found: %{kind: kind, path: path, from: from, to: to, token: token}}
  end

  # The path a value starting now gets.
  defp value_path(%{type: :object, path: path, key: key}) when is_binary(key), do: path ++ [key]
  defp value_path(%{type: :array, path: path, index: n}), do: path ++ [Integer.to_string(n)]
  defp value_path(%{path: path}), do: path

  defp open(%{stack: [top | rest]} = state, type) do
    frame =
      case type do
        :object -> %{type: :object, path: value_path(top), expect: :key, key: nil}
        :array -> %{type: :array, path: value_path(top), expect: :value, index: 0}
      end

    %{state | stack: [frame, %{top | expect: :after} | rest]}
  end

  defp close(%{stack: [_top, parent | rest]} = state), do: %{state | stack: [parent | rest]}
  defp close(state), do: state

  defp comma(state) do
    update_top(state, fn
      %{type: :object} = top -> %{top | expect: :key, key: nil}
      %{type: :array} = top -> %{top | expect: :value, index: top.index + 1}
      top -> top
    end)
  end

  # A string: an object's key, or a value.
  defp string(%{stack: [%{type: :object, expect: e} = top | rest]} = state, key)
       when e in [:key, :after] do
    keys = Map.update(state.keys, top.path, [key], &[key | &1])
    %{state | stack: [%{top | expect: :colon, key: key} | rest], keys: keys}
  end

  defp string(state, _value), do: value_done(state)

  defp value_done(state), do: update_top(state, &%{&1 | expect: :after})

  defp update_top(%{stack: [top | rest]} = state, fun), do: %{state | stack: [fun.(top) | rest]}

  defp comment_end(text, i) do
    case binary_part(text, i, min(2, byte_size(text) - i)) do
      "//" ->
        case :binary.match(text, "\n", scope: {i, byte_size(text) - i}) do
          {nl, _} -> nl
          :nomatch -> byte_size(text)
        end

      "/*" ->
        case :binary.match(text, "*/", scope: {i + 2, byte_size(text) - i - 2}) do
          {e, _} -> e + 2
          :nomatch -> byte_size(text)
        end

      _ ->
        i + 1
    end
  end

  # After the closing quote; an unterminated string ends at its line's end.
  defp string_end(text, i) when i >= byte_size(text), do: i

  defp string_end(text, i) do
    case :binary.at(text, i) do
      ?" -> i + 1
      ?\\ -> string_end(text, min(i + 2, byte_size(text)))
      ?\n -> i
      _ -> string_end(text, i + 1)
    end
  end

  defp scalar_end(text, i) when i >= byte_size(text), do: i

  defp scalar_end(text, i) do
    if :binary.at(text, i) in ~c" \t\r\n{}[]:,\"/", do: i, else: scalar_end(text, i + 1)
  end

  defp decode(text, from, to) do
    raw = binary_part(text, from, to - from)

    case Jason.decode(raw) do
      {:ok, s} when is_binary(s) -> s
      _ -> raw |> String.trim_leading("\"") |> String.trim_trailing("\"")
    end
  end
end

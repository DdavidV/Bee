defmodule Bee.Commands.When do
  @moduledoc """
  VS Code `when` clauses: parsed here, evaluated here (menus) and in the
  browser (keybindings, `assets/js/commands/when.js`), which share the AST below.

  ## Grammar (precedence from loosest to tightest)

      expr       := and ("||" and)*
      and        := unary ("&&" unary)*
      unary      := "!" unary | primary
      primary    := "(" expr ")" | "true" | "false" | comparison
      comparison := key
                  | key ("==" | "===" | "!=" | "!==") value
                  | key ("<" | "<=" | ">" | ">=") value
                  | key "=~" /regex/flags
                  | key "in" key | key "not in" key

  Values are unquoted words or 'single quoted' strings; `true`/`false`
  compare as booleans.

  ## AST (JSON-friendly)

      ["true"] | ["false"] | ["key", k] | ["not", e] | ["and", e, e, ...] | ["or", e, e, ...]
      ["eq" | "ne" | "lt" | "le" | "gt" | "ge", k, value]
      ["regex", k, source, flags] | ["in", k, container_key] | ["notin", k, container_key]

  ## Semantics (as in VS Code)

    * a bare key is true when its value is truthy (not nil/false/0/"")
    * `==`/`!=` compare loosely: `2 == '2'`, and `true` only equals `true`
    * `<` etc. compare numbers; non-numbers make the comparison false
    * `=~` matches the value as a string; a missing key never matches
    * `a in b` – b's value is a list containing a's value, or a map with that key
  """

  @type ast :: list()

  @spec parse(String.t() | nil) :: {:ok, ast} | {:error, String.t()}
  def parse(nil), do: {:ok, ["true"]}

  def parse(source) when is_binary(source) do
    if String.trim(source) == "" do
      {:ok, ["true"]}
    else
      with {:ok, tokens} <- tokenize(source, []),
           {:ok, ast, []} <- parse_or(tokens) do
        {:ok, ast}
      else
        {:ok, _ast, [token | _]} ->
          {:error, "unexpected #{describe(token)} in #{inspect(source)}"}

        {:error, reason} ->
          {:error, "#{reason} in #{inspect(source)}"}
      end
    end
  end

  def parse!(source) do
    case parse(source) do
      {:ok, ast} -> ast
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  ## Tokenizer

  @word ~r/^[^\s()!=<>&|'~,]+/u

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in ~c" \t\n\r", do: tokenize(rest, acc)
  defp tokenize("&&" <> rest, acc), do: tokenize(rest, [:and | acc])
  defp tokenize("||" <> rest, acc), do: tokenize(rest, [:or | acc])
  defp tokenize("===" <> rest, acc), do: tokenize(rest, [{:op, "eq"} | acc])
  defp tokenize("!==" <> rest, acc), do: tokenize(rest, [{:op, "ne"} | acc])
  defp tokenize("==" <> rest, acc), do: tokenize(rest, [{:op, "eq"} | acc])
  defp tokenize("!=" <> rest, acc), do: tokenize(rest, [{:op, "ne"} | acc])
  defp tokenize("<=" <> rest, acc), do: tokenize(rest, [{:op, "le"} | acc])
  defp tokenize(">=" <> rest, acc), do: tokenize(rest, [{:op, "ge"} | acc])
  defp tokenize("<" <> rest, acc), do: tokenize(rest, [{:op, "lt"} | acc])
  defp tokenize(">" <> rest, acc), do: tokenize(rest, [{:op, "gt"} | acc])
  defp tokenize("!" <> rest, acc), do: tokenize(rest, [:not | acc])
  defp tokenize("(" <> rest, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [:rparen | acc])

  defp tokenize("=~" <> rest, acc) do
    case read_regex(String.trim_leading(rest)) do
      {:ok, source, flags, rest} -> tokenize(rest, [{:regex, source, flags} | acc])
      :error -> {:error, "expected /regex/ after =~"}
    end
  end

  defp tokenize("'" <> rest, acc) do
    case String.split(rest, "'", parts: 2) do
      [string, rest] -> tokenize(rest, [{:string, string} | acc])
      [_] -> {:error, "unterminated string"}
    end
  end

  defp tokenize(source, acc) do
    case Regex.run(@word, source) do
      [word] ->
        rest = binary_part(source, byte_size(word), byte_size(source) - byte_size(word))

        token =
          case word do
            "true" -> true
            "false" -> false
            "in" -> :in
            "not" -> :not_word
            _ -> {:word, word}
          end

        tokenize(rest, [token | acc])

      nil ->
        {:error, "unexpected #{inspect(String.first(source))}"}
    end
  end

  defp read_regex("/" <> rest), do: read_regex_body(rest, "")
  defp read_regex(_), do: :error

  defp read_regex_body(<<"\\/", rest::binary>>, acc), do: read_regex_body(rest, acc <> "\\/")
  defp read_regex_body(<<"\\\\", rest::binary>>, acc), do: read_regex_body(rest, acc <> "\\\\")

  defp read_regex_body(<<"/", rest::binary>>, acc) do
    [flags] = Regex.run(~r/^[a-z]*/, rest)
    {:ok, acc, flags, binary_part(rest, byte_size(flags), byte_size(rest) - byte_size(flags))}
  end

  defp read_regex_body(<<c::utf8, rest::binary>>, acc),
    do: read_regex_body(rest, acc <> <<c::utf8>>)

  defp read_regex_body(<<>>, _acc), do: :error

  ## Parser

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens), do: parse_or_rest(rest, [left])
  end

  defp parse_or_rest([:or | tokens], acc) do
    with {:ok, right, rest} <- parse_and(tokens), do: parse_or_rest(rest, [right | acc])
  end

  defp parse_or_rest(rest, [single]), do: {:ok, single, rest}
  defp parse_or_rest(rest, acc), do: {:ok, ["or" | Enum.reverse(acc)], rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_unary(tokens), do: parse_and_rest(rest, [left])
  end

  defp parse_and_rest([:and | tokens], acc) do
    with {:ok, right, rest} <- parse_unary(tokens), do: parse_and_rest(rest, [right | acc])
  end

  defp parse_and_rest(rest, [single]), do: {:ok, single, rest}
  defp parse_and_rest(rest, acc), do: {:ok, ["and" | Enum.reverse(acc)], rest}

  defp parse_unary([:not | tokens]) do
    with {:ok, expr, rest} <- parse_unary(tokens), do: {:ok, ["not", expr], rest}
  end

  defp parse_unary(tokens), do: parse_primary(tokens)

  defp parse_primary([:lparen | tokens]) do
    case parse_or(tokens) do
      {:ok, expr, [:rparen | rest]} -> {:ok, expr, rest}
      {:ok, _expr, _} -> {:error, "missing )"}
      error -> error
    end
  end

  defp parse_primary([true | rest]), do: {:ok, ["true"], rest}
  defp parse_primary([false | rest]), do: {:ok, ["false"], rest}

  defp parse_primary([{:word, key}, {:op, op} | rest]) do
    case rest do
      [value | rest] when is_boolean(value) -> {:ok, [op, key, value], rest}
      [{:word, value} | rest] -> {:ok, [op, key, value], rest}
      [{:string, value} | rest] -> {:ok, [op, key, value], rest}
      _ -> {:error, "expected a value after #{key}"}
    end
  end

  defp parse_primary([{:word, key}, {:regex, source, flags} | rest]),
    do: {:ok, ["regex", key, source, flags], rest}

  defp parse_primary([{:word, key}, :in, {:word, container} | rest]),
    do: {:ok, ["in", key, container], rest}

  defp parse_primary([{:word, key}, :not_word, :in, {:word, container} | rest]),
    do: {:ok, ["notin", key, container], rest}

  defp parse_primary([{:word, key} | rest]), do: {:ok, ["key", key], rest}
  defp parse_primary([]), do: {:error, "unexpected end"}
  defp parse_primary([token | _]), do: {:error, "unexpected #{describe(token)}"}

  defp describe(:and), do: "&&"
  defp describe(:or), do: "||"
  defp describe(:not), do: "!"
  defp describe(:not_word), do: "not"
  defp describe(:in), do: "in"
  defp describe(:lparen), do: "("
  defp describe(:rparen), do: ")"
  defp describe({:op, op}), do: op
  defp describe({:word, w}), do: inspect(w)
  defp describe({:string, s}), do: "'#{s}'"
  defp describe({:regex, s, f}), do: "/#{s}/#{f}"
  defp describe(b) when is_boolean(b), do: to_string(b)

  ## Evaluation

  @doc "Evaluates an AST against a context map (string keys)."
  @spec eval(ast, map()) :: boolean()
  def eval(["true"], _ctx), do: true
  def eval(["false"], _ctx), do: false
  def eval(["key", key], ctx), do: truthy?(Map.get(ctx, key))
  def eval(["not", expr], ctx), do: not eval(expr, ctx)
  def eval(["and" | exprs], ctx), do: Enum.all?(exprs, &eval(&1, ctx))
  def eval(["or" | exprs], ctx), do: Enum.any?(exprs, &eval(&1, ctx))
  def eval(["eq", key, value], ctx), do: loose_eq?(Map.get(ctx, key), value)
  def eval(["ne", key, value], ctx), do: not loose_eq?(Map.get(ctx, key), value)

  def eval([op, key, value], ctx) when op in ~w(lt le gt ge) do
    with {:ok, a} <- number(Map.get(ctx, key)), {:ok, b} <- number(value) do
      case op do
        "lt" -> a < b
        "le" -> a <= b
        "gt" -> a > b
        "ge" -> a >= b
      end
    else
      _ -> false
    end
  end

  def eval(["regex", key, source, flags], ctx) do
    case {Map.get(ctx, key), regex(source, flags)} do
      {nil, _} -> false
      {_, nil} -> false
      {value, regex} -> Regex.match?(regex, to_string(value))
    end
  end

  def eval(["in", key, container], ctx), do: member?(Map.get(ctx, container), Map.get(ctx, key))
  def eval(["notin", key, container], ctx), do: not eval(["in", key, container], ctx)

  defp truthy?(v), do: v not in [nil, false, 0, "", 0.0]

  defp loose_eq?(a, b) when is_boolean(a) or is_boolean(b), do: a === b
  defp loose_eq?(nil, _), do: false
  defp loose_eq?(a, b), do: to_string(a) == to_string(b)

  defp number(n) when is_number(n), do: {:ok, n}

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp number(_), do: :error

  defp member?(list, value) when is_list(list), do: value in list
  defp member?(%{} = map, value), do: Map.has_key?(map, to_string(value))
  defp member?(_, _), do: false

  defp regex(source, flags) do
    opts = flags |> String.graphemes() |> Enum.flat_map(&regex_flag/1) |> Enum.join()

    case Regex.compile(source, opts) do
      {:ok, regex} -> regex
      {:error, _} -> nil
    end
  end

  # JS flags without an Elixir equivalent (g, y, d) don't affect a single test.
  defp regex_flag("i"), do: ["i"]
  defp regex_flag("m"), do: ["m"]
  defp regex_flag("s"), do: ["s"]
  defp regex_flag("u"), do: ["u"]
  defp regex_flag(_), do: []
end

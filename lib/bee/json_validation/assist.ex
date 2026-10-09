defmodule Bee.JSONValidation.Assist do
  @moduledoc """
  Completion and hover in a JSON file from its schemas (`Bee.JSONValidation`),
  like VS Code's: where the cursor is (`Bee.JSON.Context`, which copes with
  JSON being typed), then the sub-schemas for that place – following
  `$ref`, `allOf`/`anyOf`/`oneOf`, `if`/`then`/`else`, `dependencies` of
  keys the object has, `properties`/`patternProperties`/
  `additionalProperties` and `items`.

    * keys: the properties the object doesn't have yet, inserted with a
      value to fill in (a VS Code snippet: `"name": "$1"`)
    * values: `enum`, `const`, `default`, `true`/`false`, `null`, `{}`/`[]`
    * hover: a key's or value's title, description, type and allowed values

  Only schemas already loaded (validation loads them) are used: completion
  never waits for the network.
  """

  alias Bee.JSON.Context
  alias Bee.JSONValidation
  alias Bee.JSONValidation.Schemas
  alias ExJsonSchema.Schema.Ref

  @max_depth 32

  @type item :: %{
          label: String.t(),
          display: String.t(),
          detail: String.t() | nil,
          info: String.t() | nil,
          snippet: String.t()
        }

  @doc """
  Completions at byte `offset` of `text` (the file at `path`):
  `%{from, to, items: [item]}`, `from`-`to` being what an item replaces.
  """
  def complete(path, text, offset) do
    ctx = Context.at(text, offset)
    schemas = schemas_at(path, ctx.path, ctx.keys)

    items =
      case ctx.kind do
        :key -> key_items(schemas, Map.get(ctx.keys, ctx.path, []) -- [ctx.token])
        :value -> value_items(schemas)
      end

    %{from: ctx.from, to: ctx.to, items: Enum.uniq_by(items, & &1.label)}
  end

  @doc "What the schemas say about the key or value at byte `offset`: `%{from, to, text}` or nil."
  def hover(path, text, offset) do
    ctx = Context.at(text, offset)

    target =
      case ctx do
        %{token: nil} -> nil
        %{kind: :key, token: key} -> ctx.path ++ [key]
        %{kind: :value} -> ctx.path
      end

    with [_ | _] = target_path <- target,
         schemas when schemas != [] <- schemas_at(path, target_path, ctx.keys),
         text when text != "" <- describe(schemas) do
      %{from: ctx.from, to: ctx.to, text: text}
    else
      _ -> nil
    end
  end

  ## The schemas at a path

  # [{root, schema}] for the value at `path`, of every schema of the file.
  defp schemas_at(file, path, keys) do
    for url <- JSONValidation.schemas_for(file),
        {:ok, root} <- [Schemas.cached(url)],
        schema <- walk(root, expand(root, root.schema, Map.get(keys, [], []), 0), path, [], keys),
        do: {root, schema}
  end

  defp walk(_root, schemas, [], _done, _keys), do: schemas

  defp walk(root, schemas, [segment | rest], done, keys) do
    here = done ++ [segment]
    object_keys = Map.get(keys, here, [])

    children =
      for schema <- schemas,
          child <- child(schema, segment),
          expanded <- expand(root, child, object_keys, 0),
          do: expanded

    walk(root, children, rest, here, keys)
  end

  # The sub-schemas for member `segment` (a key, or an array index).
  defp child(schema, segment) do
    props =
      case schema["properties"] do
        %{^segment => s} -> [s]
        _ -> []
      end

    patterns =
      for {pattern, s} <- schema["patternProperties"] || %{},
          match?({:ok, _}, Regex.compile(pattern)),
          Regex.match?(Regex.compile!(pattern), segment),
          do: s

    additional =
      case schema["additionalProperties"] do
        %{} = s when props == [] and patterns == [] -> [s]
        _ -> []
      end

    items =
      case {schema["items"], Integer.parse(segment)} do
        {%{} = s, {_, ""}} -> [s]
        {list, {n, ""}} when is_list(list) -> Enum.slice(list, n, 1)
        _ -> []
      end

    props ++ patterns ++ additional ++ items
  end

  # A schema with the ones it brings in: $ref, allOf/anyOf/oneOf,
  # if/then/else, and the dependencies of `keys` the object has.
  defp expand(_root, _schema, _keys, depth) when depth > @max_depth, do: []
  defp expand(_root, schema, _keys, _depth) when not is_map(schema), do: []

  defp expand(root, %{"$ref" => ref} = schema, keys, depth) do
    case fragment(root, ref) do
      {:ok, target} -> expand(root, target, keys, depth + 1) ++ [Map.delete(schema, "$ref")]
      :error -> []
    end
  end

  defp expand(root, schema, keys, depth) do
    nested =
      List.wrap(schema["allOf"]) ++
        List.wrap(schema["anyOf"]) ++
        List.wrap(schema["oneOf"]) ++
        Enum.reject([schema["then"], schema["else"]], &is_nil/1) ++
        for {key, dep} <- schema["dependencies"] || %{}, key in keys, is_map(dep), do: dep

    [schema | Enum.flat_map(nested, &expand(root, &1, keys, depth + 1))]
  end

  defp fragment(root, %Ref{} = ref) do
    case ExJsonSchema.Schema.get_fragment(root, ref) do
      {:ok, schema} -> {:ok, schema}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp fragment(root, ref) when is_list(ref) do
    {:ok, ExJsonSchema.Schema.get_fragment!(root, ref)}
  rescue
    _ -> :error
  end

  defp fragment(_root, _ref), do: :error

  ## Completion items

  defp key_items(schemas, present) do
    for {root, schema} <- schemas,
        {name, prop} <- Enum.sort(schema["properties"] || %{}),
        name not in present do
      expanded = expand(root, prop, [], 0)

      %{
        label: Jason.encode!(name),
        display: name,
        detail: type_text(expanded),
        info: description(expanded),
        snippet: escape(Jason.encode!(name)) <> ": " <> value_snippet(expanded)
      }
    end
  end

  defp value_items(schemas) do
    schemas = for {root, schema} <- schemas, s <- expand(root, schema, [], 0), do: s
    types = schemas |> Enum.flat_map(&List.wrap(&1["type"])) |> Enum.uniq()

    values =
      Enum.flat_map(schemas, fn s ->
        List.wrap(s["enum"]) ++
          if(Map.has_key?(s, "const"), do: [s["const"]], else: []) ++
          if(Map.has_key?(s, "default"), do: [s["default"]], else: [])
      end) ++
        if("boolean" in types, do: [true, false], else: []) ++
        if("null" in types, do: [nil], else: [])

    literal =
      for value <- Enum.uniq(values) do
        json = Jason.encode!(value)
        %{label: json, display: json, detail: nil, info: nil, snippet: escape(json)}
      end

    containers =
      (if("object" in types, do: [{"{}", "{$1}"}], else: []) ++
         if("array" in types, do: [{"[]", "[$1]"}], else: []))
      |> Enum.map(fn {label, snippet} ->
        %{label: label, display: label, detail: nil, info: nil, snippet: snippet}
      end)

    literal ++ containers
  end

  # What a property's value starts as: its default, its only allowed
  # value, or something of its type to fill in.
  defp value_snippet(schemas) do
    enum = Enum.find_value(schemas, &(is_list(&1["enum"]) && &1["enum"]))

    cond do
      default = Enum.find(schemas, &Map.has_key?(&1, "default")) ->
        "${1:" <> escape_placeholder(Jason.encode!(default["default"])) <> "}"

      match?([_], enum) ->
        escape(Jason.encode!(hd(enum)))

      true ->
        case schemas |> Enum.flat_map(&List.wrap(&1["type"])) |> List.first() do
          "string" -> ~s("$1")
          t when t in ["integer", "number"] -> "${1:0}"
          "boolean" -> "${1:false}"
          "object" -> "{$1}"
          "array" -> "[$1]"
          "null" -> "null"
          _ -> "$1"
        end
    end
  end

  ## Hover

  defp describe(schemas) do
    schemas = for {root, schema} <- schemas, s <- expand(root, schema, [], 0), do: s
    title = Enum.find_value(schemas, &string(&1["title"]))
    text = description(schemas)
    type = type_text(schemas)
    enum = schemas |> Enum.flat_map(&List.wrap(&1["enum"])) |> Enum.uniq()

    [
      title,
      text,
      type && "Type: #{type}",
      enum != [] && "Allowed: " <> Enum.map_join(enum, ", ", &Jason.encode!/1)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.join("\n\n")
  end

  defp description(schemas),
    do:
      Enum.find_value(schemas, &(string(&1["markdownDescription"]) || string(&1["description"])))

  defp type_text(schemas) do
    case schemas
         |> Enum.flat_map(&List.wrap(&1["type"]))
         |> Enum.filter(&is_binary/1)
         |> Enum.uniq() do
      [] -> nil
      types -> Enum.join(types, " | ")
    end
  end

  defp string(s) when is_binary(s) and s != "", do: s
  defp string(_s), do: nil

  # Text in a VS Code snippet: $, } and \ are special.
  defp escape(text), do: String.replace(text, ~r/[$}\\]/, "\\\\\\0")
  defp escape_placeholder(text), do: escape(text)
end

defmodule Bee.JSON.Schema do
  @moduledoc """
  JSON Schemas shipped in `priv/schemas/` (draft 7), enforced with
  `ex_json_schema`.

  The schemas are read and resolved at compile time (see `Bee.Priv`): an
  invalid schema fails the build, and editing one recompiles this module.
  Validation errors are turned into short messages for the status bar:
  if/then/else failures report their underlying cause, enum failures list
  the allowed values, and nested errors name their JSON path.
  """

  alias ExJsonSchema.Validator.Error

  @names ~w(settings keybindings manifest)

  for name <- @names, do: @external_resource(Bee.Priv.path("schemas/#{name}.schema.json"))

  @schemas Map.new(@names, fn name ->
             {name,
              "schemas/#{name}.schema.json"
              |> Bee.Priv.read_json!()
              |> ExJsonSchema.Schema.resolve()}
           end)

  @doc "Resolved schema `priv/schemas/<name>.schema.json`."
  def load!(name) do
    case @schemas do
      %{^name => root} ->
        root

      _ ->
        raise ArgumentError, "unknown schema #{inspect(name)}, known: #{Enum.join(@names, ", ")}"
    end
  end

  @doc "The raw (decoded) schema map."
  def raw!(name), do: load!(name).schema

  @doc """
  Resolves a schema given as data (e.g. settings contributed by a plugin).
  Returns `{:ok, root}` or `{:error, message}` for an invalid schema.
  """
  def resolve(schema) do
    {:ok, ExJsonSchema.Schema.resolve(schema)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Validates `data` against the fragment at `ref` (e.g. `"#/properties/editor.fontSize"`)
  of schema `name` (or of a root from `resolve/1`). Returns `:ok` or
  `{:error, [message]}`.
  """
  def validate(%ExJsonSchema.Schema.Root{} = root, ref, data) do
    case ExJsonSchema.Validator.validate_fragment(root, ref, data, error_formatter: false) do
      :ok -> :ok
      {:error, errors} -> {:error, Enum.flat_map(errors, &format(&1, root, ref))}
    end
  end

  def validate(name, ref, data), do: validate(load!(name), ref, data)

  @doc "JSON pointer for a property name (escapes `~` and `/`)."
  def property_ref(key),
    do: "#/properties/" <> (key |> String.replace("~", "~0") |> String.replace("/", "~1"))

  # if/then/else: report why the chosen branch failed.
  defp format(%Error{error: %Error.IfThenElse{errors: inner}}, root, ref) when inner != [] do
    Enum.flat_map(inner, &format(&1, root, ref))
  end

  defp format(%Error{error: %Error.Enum{}, path: path}, root, ref) do
    allowed =
      case fragment(root, ref, path) do
        %{"enum" => values} ->
          ", expected one of " <> Enum.map_join(values, ", ", &Jason.encode!/1)

        _ ->
          ""
      end

    ["value is not allowed#{allowed}#{at(path)}"]
  end

  defp format(%Error{error: %Error.Required{missing: missing}, path: path}, _root, _ref) do
    ["missing #{Enum.map_join(missing, ", ", &~s("#{&1}"))}#{at(path)}"]
  end

  defp format(%Error{error: %Error.AdditionalProperties{}, path: path}, _root, _ref) do
    ["unknown property \"#{path |> String.split("/") |> List.last()}\""]
  end

  defp format(%Error{error: error, path: path}, _root, _ref), do: ["#{error}#{at(path)}"]

  defp at("#"), do: ""
  defp at("#/" <> path), do: " (at #{path})"

  # The sub-schema an error path points into (only for plain property nesting).
  defp fragment(root, ref, path) do
    schema = ExJsonSchema.Schema.get_fragment!(root, ref)

    path
    |> String.trim_leading("#")
    |> String.split("/", trim: true)
    |> Enum.reduce(schema, fn segment, sub_schema ->
      case sub_schema do
        %{"properties" => %{^segment => sub}} -> sub
        %{"additionalProperties" => %{} = sub} -> sub
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  end
end

defmodule Bee.Settings.Configuration do
  @moduledoc """
  Settings contributed by plugins: a `Bee.Contributions.Point` for the
  `configuration` section of manifests, VS Code style:

      "configuration": {
        "title": "Word Count",
        "properties": {
          "wordCount.includeNumbers": {
            "type": "boolean", "default": true, "description": "Count numbers as words."
          }
        }
      }

  Each property is a JSON Schema (draft 7); `Bee.Settings` validates values
  and takes defaults from it. Setting names are unique: a plugin can't
  redefine one of Bee's or another plugin's.
  """
  @behaviour Bee.Contributions.Point

  @doc "`[%{title, properties, root}]`, root being the resolved schema of the properties."
  def contributed, do: Enum.map(Bee.Contributions.entries(:configuration), &elem(&1, 1))

  @doc "The resolved schema that defines setting `key`, or nil."
  def root_for(key) do
    Enum.find_value(contributed(), &(Map.has_key?(&1.properties, key) && &1.root))
  end

  @impl Bee.Contributions.Point
  def key, do: :configuration

  @impl Bee.Contributions.Point
  def normalize!(manifest, _source, _opts) do
    case manifest["contributes"]["configuration"] do
      nil ->
        nil

      %{"properties" => properties} = configuration ->
        case Bee.JSON.Schema.resolve(%{"type" => "object", "properties" => properties}) do
          {:ok, root} ->
            %{title: configuration["title"], properties: properties, root: root}

          {:error, message} ->
            raise ArgumentError, "invalid configuration schema: #{message}"
        end
    end
  end

  @impl Bee.Contributions.Point
  def conflicts(%{properties: properties}, others) do
    taken =
      Enum.reduce(
        others,
        Map.keys(Bee.Settings.builtin_schema()),
        &(Map.keys(&1.properties) ++ &2)
      )

    for key <- Map.keys(properties),
        key in taken,
        do: "setting #{inspect(key)} is already defined"
  end
end

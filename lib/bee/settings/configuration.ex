defmodule Bee.Settings.Configuration do
  @moduledoc """
  Settings contributed by plugins: a `Bee.Contributions.Point` for the
  `configuration` and `configurationDefaults` sections of manifests, VS
  Code style:

      "configuration": {
        "title": "Word Count",
        "properties": {
          "wordCount.includeNumbers": {
            "type": "boolean", "default": true, "description": "Count numbers as words."
          }
        }
      },
      "configurationDefaults": {"editor.tabSize": 4}

  `configuration` is one section or a list of them (each with a `title`,
  shown in that `order`). Each property is a JSON Schema (draft 7);
  `Bee.Settings` validates values and takes defaults from it. Setting
  names are unique: a plugin can't redefine one of Bee's or another
  plugin's.

  `configurationDefaults` gives other defaults to settings, Bee's or other
  plugins' (`Bee.Settings.defaults/0`; a later plugin's win). Its language
  blocks (`"[python]": {…}`) are kept (`language_defaults/0`) but not
  applied yet.
  """
  @behaviour Bee.Contributions.Point

  @doc """
  `[%{sections, properties, root, defaults, language_defaults}]`, one per
  source: `sections` are its `[%{title, order, properties}]`, `properties`
  all of them, and `root` their resolved schema.
  """
  def contributed, do: Enum.map(Bee.Contributions.entries(:configuration), &elem(&1, 1))

  @doc "The resolved schema that defines setting `key`, or nil."
  def root_for(key) do
    Enum.find_value(contributed(), &(Map.has_key?(&1.properties, key) && &1.root))
  end

  @doc "The defaults plugins give to settings (`configurationDefaults`), later plugins' over earlier ones'."
  def defaults, do: Enum.reduce(contributed(), %{}, &Map.merge(&2, &1.defaults))

  @doc "Language blocks of `configurationDefaults`: `%{language_id => %{setting => value}}`."
  def language_defaults do
    Enum.reduce(contributed(), %{}, fn c, acc ->
      Map.merge(acc, c.language_defaults, fn _language, a, b -> Map.merge(a, b) end)
    end)
  end

  @impl Bee.Contributions.Point
  def key, do: :configuration

  @impl Bee.Contributions.Point
  def normalize!(manifest, _source, _opts) do
    sections =
      for %{"properties" => properties} = section <-
            List.wrap(manifest["contributes"]["configuration"]) do
        %{title: section["title"], order: section["order"], properties: properties}
      end
      |> Enum.sort_by(&(&1.order || 0))

    {language, plain} =
      (manifest["contributes"]["configurationDefaults"] || %{})
      |> Enum.split_with(fn {key, _value} -> String.starts_with?(key, "[") end)

    if sections == [] and language == [] and plain == [] do
      nil
    else
      properties = Enum.reduce(sections, %{}, &Map.merge(&2, &1.properties))

      case Bee.JSON.Schema.resolve(%{"type" => "object", "properties" => properties}) do
        {:ok, root} ->
          %{
            sections: sections,
            properties: properties,
            root: root,
            defaults: Map.new(plain),
            language_defaults:
              for({"[" <> languages, %{} = values} <- language, reduce: %{}) do
                acc ->
                  # "[javascript][typescript]"
                  languages
                  |> String.split(["[", "]"], trim: true)
                  |> Enum.reduce(
                    acc,
                    &Map.update(&2, &1, values, fn old -> Map.merge(old, values) end)
                  )
              end
          }

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

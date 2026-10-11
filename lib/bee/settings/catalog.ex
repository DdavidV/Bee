defmodule Bee.Settings.Catalog do
  @moduledoc """
  The settings as a settings page shows them (`BeeWeb.Workbench.SettingsEditor`):
  grouped, titled, and each with the control that fits its schema. All of
  it comes from the schemas – Bee's own (`priv/schemas/settings.schema.json`)
  and those plugins and extensions contribute (`Bee.Settings.Configuration`)
  – so a new setting shows up by being declared.

  A group: `%{id, title, source, settings}`; Bee's settings are grouped by
  the first part of their name ("editor.…": Editor), contributed ones by
  the sections their manifest gives them (its `title`, else the plugin's
  name). A setting:

      %{
        key: "editor.fontSize",
        title: "Font Size", prefix: "Editor",   # "Editor: Font Size"
        description: "…",
        default: 14,
        control: {:number, %{integer: true, min: 6, max: 72}}
      }

  Controls:

    * `:boolean` – on or off
    * `{:enum, [{value, label}]}` – one of some values (also a setting
      whose values are known otherwise: the color themes, the icon themes)
    * `{:number, %{integer, min, max}}`
    * `{:string, %{nullable}}` – text; `nullable`: empty is "none" (null)
    * `:list` – a list of texts
    * `{:map, :boolean}` / `{:map, :string}` – names (patterns) with a
      switch or a text each
    * `:json` – anything else: edited in the settings file
  """

  alias Bee.Contributions

  @type control ::
          :boolean
          | {:enum, [{term(), String.t()}]}
          | {:number, map()}
          | {:string, map()}
          | :list
          | {:map, :boolean | :string}
          | :json

  # Bee's own groups, in this order: {id, title, the names' first parts}.
  @builtin [
    {"editor", "Editor", ~w(editor)},
    {"workbench", "Workbench", ~w(workbench)},
    {"files", "Files", ~w(files)},
    {"search", "Search", ~w(search)},
    {"terminal", "Terminal", ~w(terminal)},
    {"plugins", "Plugins", ~w(plugins extensions)}
  ]

  @doc "Every group that has settings, Bee's first, then the plugins' in the order they registered."
  def groups do
    builtin = Bee.Settings.builtin_schema()

    own =
      for {id, title, parts} <- @builtin do
        keys = for {key, _spec} <- builtin, part(key) in parts, do: key
        %{id: id, title: title, source: :bee, settings: settings(builtin, keys)}
      end

    # (A part Bee's list doesn't name yet: still shown.)
    known = Enum.flat_map(@builtin, &elem(&1, 2))
    rest = for {key, _spec} <- builtin, part(key) not in known, do: key
    other = %{id: "other", title: "Other", source: :bee, settings: settings(builtin, rest)}

    Enum.reject(own ++ [other] ++ contributed(), &(&1.settings == []))
  end

  defp contributed do
    for {source, %{sections: sections}} <- Contributions.entries(:configuration),
        {section, index} <- Enum.with_index(sections) do
      name = source_name(source)

      %{
        id: "#{name}-#{index}",
        title: section.title || display_name(name),
        source: {:plugin, name},
        settings: settings(section.properties, Map.keys(section.properties))
      }
    end
  end

  defp source_name({_kind, name}), do: to_string(name)
  defp source_name(other), do: inspect(other)

  defp display_name(name) do
    case Bee.Plugins.get(name) do
      %{display_name: display} when is_binary(display) -> display
      _ -> name
    end
  rescue
    _ -> name
  end

  defp part(key), do: key |> String.split(".") |> hd()

  defp settings(schema, keys) do
    keys
    |> Enum.map(&setting(&1, schema[&1]))
    |> Enum.sort_by(&{&1.order, &1.key})
  end

  @doc "A setting of name `key` with JSON Schema `spec`, for the page."
  def setting(key, spec) when is_map(spec) do
    {prefix, title} = titles(key)

    %{
      key: key,
      prefix: prefix,
      title: title,
      description: describe(spec),
      default: spec["default"],
      order: if(is_number(spec["order"]), do: spec["order"], else: 1_000_000),
      deprecated: spec["deprecationMessage"] || spec["markdownDeprecationMessage"],
      control: control(key, spec)
    }
  end

  @doc "The setting named `key`, or nil."
  def get(key) do
    case Bee.Settings.schema()[key] do
      nil -> nil
      spec -> setting(key, spec)
    end
  end

  defp describe(spec) do
    (spec["description"] || spec["markdownDescription"] || "")
    |> to_string()
    |> String.trim()
  end

  # "editor.formatOnSave" → {"Editor", "Format On Save"}; deeper names keep
  # their middle parts: "git.blame.inline" → {"Git › Blame", "Inline"}.
  defp titles(key) do
    parts = key |> String.split(".") |> Enum.map(&words/1)

    case parts do
      [only] -> {"", only}
      parts -> {parts |> Enum.drop(-1) |> Enum.join(" › "), List.last(parts)}
    end
  end

  # "formatOnSave" → "Format On Save", "nodePath" → "Node Path".
  defp words(part) do
    part
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/[_-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", fn word ->
      {first, rest} = String.split_at(word, 1)
      String.upcase(first) <> rest
    end)
  end

  ## Controls

  @doc "The control for a setting, from its schema (see the moduledoc)."
  @spec control(String.t(), map()) :: control
  def control("workbench.colorTheme", _spec) do
    themes = Bee.ColorThemes.themes() |> Enum.sort_by(&{&1.base == :dark, &1.label})
    {:enum, Enum.map(themes, &{&1.id, &1.label})}
  end

  def control("workbench.iconTheme", _spec) do
    themes = Bee.IconThemes.themes() |> Enum.sort_by(& &1.label)
    {:enum, [{nil, "Bee's own icons"} | Enum.map(themes, &{&1.id, &1.label})]}
  end

  def control(_key, spec) do
    types = List.wrap(spec["type"])
    nullable? = "null" in types
    types = types -- ["null"]

    cond do
      is_list(spec["enum"]) and Enum.all?(spec["enum"], &scalar?/1) ->
        {:enum, enum(spec)}

      types == ["boolean"] ->
        :boolean

      types in [["integer"], ["number"]] ->
        {:number, %{integer: types == ["integer"], min: spec["minimum"], max: spec["maximum"]}}

      types == ["string"] ->
        {:string, %{nullable: nullable?}}

      types == ["array"] and strings?(spec["items"]) ->
        :list

      types == ["object"] and plain_map?(spec) ->
        {:map, map_kind(spec["additionalProperties"])}

      true ->
        :json
    end
  end

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  # (With VS Code's labels for the values, when the extension gives them.)
  defp enum(spec) do
    labels = spec["enumItemLabels"] || []

    spec["enum"]
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      label = Enum.at(labels, index)
      {value, if(is_binary(label) and label != "", do: label, else: enum_label(value))}
    end)
  end

  defp enum_label(nil), do: "null"
  defp enum_label(value), do: to_string(value)

  defp strings?(%{"type" => "string"} = items), do: not Map.has_key?(items, "enum")
  defp strings?(_items), do: false

  # An object of nothing but names with a boolean (files.exclude) or a
  # text (files.associations) each.
  defp plain_map?(spec) do
    map_kind(spec["additionalProperties"]) != nil and
      spec["properties"] in [nil, %{}] and spec["patternProperties"] in [nil, %{}]
  end

  defp map_kind(%{"type" => "boolean"}), do: :boolean

  defp map_kind(%{"type" => "string"} = spec),
    do: if(Map.has_key?(spec, "enum"), do: nil, else: :string)

  defp map_kind(_other), do: nil

  ## Searching

  @doc """
  The groups with only the settings `query` finds: every word of it in a
  setting's name, title, description or group, in any case. Groups left
  empty are dropped. An empty query: all of them.
  """
  def search(groups, query) do
    words = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    if words == [] do
      groups
    else
      groups
      |> Enum.map(fn group ->
        %{group | settings: Enum.filter(group.settings, &found?(&1, group, words))}
      end)
      |> Enum.reject(&(&1.settings == []))
    end
  end

  defp found?(setting, group, words) do
    text =
      String.downcase(
        Enum.join(
          [setting.key, setting.prefix, setting.title, setting.description, group.title],
          " "
        )
      )

    Enum.all?(words, &String.contains?(text, &1))
  end

  ## Values from the page

  @doc """
  What a control's input (a string, as forms send it) means for the
  setting: `{:ok, value}` or `{:error, message}`.
  """
  def parse(:boolean, input), do: {:ok, input in ["true", "on"]}

  def parse({:enum, options}, input) do
    case Enum.find(options, fn {value, _label} -> encode(value) == input end) do
      {value, _label} -> {:ok, value}
      nil -> {:error, "#{inspect(input)} isn't one of its values"}
    end
  end

  def parse({:number, %{integer: true}}, input) do
    case Integer.parse(String.trim(input)) do
      {number, ""} -> {:ok, number}
      _ -> {:error, "must be a whole number"}
    end
  end

  def parse({:number, _}, input) do
    case Float.parse(String.trim(input)) do
      {number, ""} -> {:ok, if(number == trunc(number), do: trunc(number), else: number)}
      _ -> {:error, "must be a number"}
    end
  end

  def parse({:string, %{nullable: true}}, ""), do: {:ok, nil}
  def parse({:string, _}, input), do: {:ok, input}
  def parse(_control, _input), do: {:error, "can't be set here"}

  @doc "A value as the page's inputs carry it (an enum's option, a number…)."
  def encode(nil), do: ""
  def encode(value) when is_binary(value), do: value
  def encode(value), do: Jason.encode!(value)
end

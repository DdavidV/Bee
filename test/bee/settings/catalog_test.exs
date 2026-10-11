defmodule Bee.Settings.CatalogTest do
  use ExUnit.Case, async: true

  alias Bee.Settings.Catalog

  test "Bee's settings are grouped by the first part of their name, every one of them" do
    groups = Catalog.groups()

    assert groups |> Enum.map(& &1.title) |> Enum.take(6) ==
             ~w(Editor Workbench Files Search Terminal Plugins)

    keys = for group <- groups, setting <- group.settings, do: setting.key
    assert Enum.sort(keys) == keys |> Enum.uniq() |> Enum.sort()
    for key <- Map.keys(Bee.Settings.builtin_schema()), do: assert(key in keys)

    plugins = Enum.find(groups, &(&1.id == "plugins"))
    assert "extensions.nodePath" in Enum.map(plugins.settings, & &1.key)
  end

  test "a setting's title is made of its name" do
    assert %{prefix: "Editor", title: "Format On Save"} = Catalog.get("editor.formatOnSave")

    assert %{prefix: "Workbench › Quick Open", title: "Recent Files"} =
             Catalog.get("workbench.quickOpen.recentFiles")

    assert %{prefix: "Terminal › Integrated", title: "Font Size", default: 13} =
             Catalog.get("terminal.integrated.fontSize")

    assert Catalog.get("no.such.setting") == nil
  end

  test "the control follows the schema" do
    control = &Catalog.control("x.y", &1)

    assert control.(%{"type" => "boolean"}) == :boolean
    assert control.(%{"type" => "string"}) == {:string, %{nullable: false}}
    assert control.(%{"type" => ["string", "null"]}) == {:string, %{nullable: true}}

    assert control.(%{"type" => "integer", "minimum" => 1, "maximum" => 9}) ==
             {:number, %{integer: true, min: 1, max: 9}}

    assert control.(%{"type" => "number"}) == {:number, %{integer: false, min: nil, max: nil}}

    assert control.(%{"type" => "string", "enum" => ["on", "off"]}) ==
             {:enum, [{"on", "on"}, {"off", "off"}]}

    assert control.(%{"enum" => [1, 2], "enumItemLabels" => ["One"]}) ==
             {:enum, [{1, "One"}, {2, "2"}]}

    assert control.(%{"type" => "array", "items" => %{"type" => "string"}}) == :list

    assert control.(%{"type" => "object", "additionalProperties" => %{"type" => "boolean"}}) ==
             {:map, :boolean}

    assert control.(%{"type" => "object", "additionalProperties" => %{"type" => "string"}}) ==
             {:map, :string}

    # Anything else is the settings file's.
    assert control.(%{"type" => "array", "items" => %{"type" => "object"}}) == :json
    assert control.(%{"type" => "object", "properties" => %{"a" => %{}}}) == :json
    assert control.(%{}) == :json
  end

  test "Bee's own: the themes are lists of the themes there are" do
    assert {:enum, themes} = Catalog.get("workbench.colorTheme").control
    assert {"dark", "Bee Dark"} in themes and {"light", "Bee Light"} in themes
    assert {:enum, [{nil, "Bee's own icons"} | _]} = Catalog.get("workbench.iconTheme").control
    assert Catalog.get("files.exclude").control == {:map, :boolean}
    assert Catalog.get("files.associations").control == {:map, :string}
    assert Catalog.get("plugins.disabled").control == :list
  end

  test "search: every word, in the name, the title, the description or the group" do
    groups = Catalog.groups()
    found = fn query -> for g <- Catalog.search(groups, query), s <- g.settings, do: s.key end

    assert found.("") |> length() == groups |> Enum.map(&length(&1.settings)) |> Enum.sum()

    assert found.("font size") |> Enum.sort() == [
             "editor.fontSize",
             "terminal.integrated.fontSize"
           ]

    assert found.("FONT terminal") == ["terminal.integrated.fontSize"]
    assert "files.exclude" in found.("glob")
    assert found.("editor.wordWrap") == ["editor.wordWrap"]
    assert found.("no such thing anywhere") == []
    # A group's name finds its settings.
    assert "files.associations" in found.("files")
  end

  test "what the page sends becomes the setting's value, or is refused" do
    assert Catalog.parse(:boolean, "true") == {:ok, true}
    assert Catalog.parse(:boolean, "false") == {:ok, false}
    assert Catalog.parse({:number, %{integer: true}}, " 12 ") == {:ok, 12}
    assert {:error, _} = Catalog.parse({:number, %{integer: true}}, "1.5")
    assert {:error, _} = Catalog.parse({:number, %{integer: true}}, "many")
    assert Catalog.parse({:number, %{integer: false}}, "1.5") == {:ok, 1.5}
    assert Catalog.parse({:number, %{integer: false}}, "2") == {:ok, 2}
    assert Catalog.parse({:string, %{nullable: true}}, "") == {:ok, nil}
    assert Catalog.parse({:string, %{nullable: false}}, "") == {:ok, ""}

    options = [{nil, "None"}, {"a", "A"}, {2, "Two"}, {true, "Yes"}]

    for {value, _} <- options,
        do: assert(Catalog.parse({:enum, options}, Catalog.encode(value)) == {:ok, value})

    assert {:error, _} = Catalog.parse({:enum, options}, "b")
  end
end

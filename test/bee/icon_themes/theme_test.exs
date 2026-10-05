defmodule Bee.IconThemes.ThemeTest do
  use ExUnit.Case, async: true

  alias Bee.IconThemes.Theme

  @json %{
    "iconDefinitions" => %{
      "_file" => %{"iconPath" => "file.svg"},
      "_folder" => %{"iconPath" => "folder.svg"},
      "_folder_open" => %{"iconPath" => "folder-open.svg"},
      "_root" => %{"iconPath" => "root.svg"},
      "_src" => %{"iconPath" => "src.svg"},
      "_src_open" => %{"iconPath" => "src-open.svg"},
      "_ts" => %{"iconPath" => "ts.svg"},
      "_test_ts" => %{"iconPath" => "test-ts.svg"},
      "_mix" => %{"iconPath" => "mix.svg"},
      "_elixir" => %{"iconPath" => "elixir.svg"},
      "_font" => %{"fontCharacter" => "\\E001"},
      "_light_ts" => %{"iconPath" => "ts-light.svg"},
      "_gone" => %{"iconPath" => "missing.svg"}
    },
    "file" => "_file",
    "folder" => "_folder",
    "folderExpanded" => "_folder_open",
    "rootFolder" => "_root",
    "folderNames" => %{"Src" => "_src"},
    "folderNamesExpanded" => %{"src" => "_src_open"},
    "fileExtensions" => %{"ts" => "_ts", "Test.TS" => "_test_ts", "md" => "_font", "x" => "_gone"},
    "fileNames" => %{"mix.exs" => "_mix"},
    "languageIds" => %{"elixir" => "_elixir"},
    "light" => %{"fileExtensions" => %{"ts" => "_light_ts"}},
    "hidesExplorerArrows" => true
  }

  # Icons become "url:<path>"; missing.svg doesn't exist.
  defp parse, do: Theme.parse(@json, &if(&1 == "missing.svg", do: nil, else: "url:" <> &1))

  test "files: name, then the longest extension, then the language, then the default" do
    %{dark: theme} = parse()
    assert Theme.file_icon(theme, "MIX.exs") == "url:mix.svg"
    assert Theme.file_icon(theme, "a.test.ts") == "url:test-ts.svg"
    assert Theme.file_icon(theme, "a.TS") == "url:ts.svg"
    assert Theme.file_icon(theme, "a.ex", "elixir") == "url:elixir.svg"
    assert Theme.file_icon(theme, "README") == "url:file.svg"
    assert theme.hides_explorer_arrows
  end

  test "font icons and missing files have no icon" do
    %{dark: theme} = parse()
    assert Theme.file_icon(theme, "a.md") == nil
    assert Theme.file_icon(theme, "a.x") == nil
  end

  test "the language is only needed when no name or extension matches" do
    %{dark: theme} = parse()
    assert Theme.needs_language?(theme, "a.ex")
    refute Theme.needs_language?(theme, "a.ts")
    refute Theme.needs_language?(theme, "mix.exs")
    refute Theme.needs_language?(%{theme | language_ids: %{}}, "a.ex")
  end

  test "folders: by name (open or closed), the defaults, the root" do
    %{dark: theme} = parse()
    assert Theme.folder_icon(theme, "SRC") == "url:src.svg"
    assert Theme.folder_icon(theme, "src", expanded: true) == "url:src-open.svg"
    assert Theme.folder_icon(theme, "lib") == "url:folder.svg"
    assert Theme.folder_icon(theme, "lib", expanded: true) == "url:folder-open.svg"
    assert Theme.folder_icon(theme, "bee", root: true) == "url:root.svg"
  end

  test "the light section overrides for light color themes" do
    %{dark: dark, light: light} = parse()
    assert Theme.file_icon(dark, "a.ts") == "url:ts.svg"
    assert Theme.file_icon(light, "a.ts") == "url:ts-light.svg"
    assert Theme.file_icon(light, "mix.exs") == "url:mix.svg"
  end

  test "an empty theme has no icons" do
    %{dark: theme} = Theme.parse(%{}, & &1)
    assert Theme.file_icon(theme, "a.ts") == nil
    assert Theme.folder_icon(theme, "src", expanded: true) == nil
  end
end

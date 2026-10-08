defmodule Bee.ColorThemesTest do
  # Plugins and contributions are global.
  use ExUnit.Case, async: false

  alias Bee.{ColorThemes, Plugins}
  alias Bee.ColorThemes.Theme

  @moduletag :capture_log

  setup do
    dir = Plugins.user_dir()
    File.rm_rf!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Plugins.reload()
    end)

    :ok
  end

  # A color theme plugin `name` in the user's plugins folder, its theme
  # including a base file.
  defp install_theme(name, themes, files) do
    dir = Path.join(Plugins.user_dir(), name)
    File.mkdir_p!(Path.join(dir, "themes"))

    File.write!(
      Path.join(dir, "plugin.json"),
      Jason.encode!(%{name: name, version: "1.0.0", contributes: %{themes: themes}})
    )

    for {rel, text} <- files, do: File.write!(Path.join(dir, rel), text)
    Plugins.reload()
    dir
  end

  defp purple(name \\ "purple") do
    install_theme(
      name,
      [%{id: "purple", label: "Purple", uiTheme: "vs-dark", path: "./themes/purple.json"}],
      [
        {"themes/base.json",
         ~s({"colors": {"editor.background": "#111111", "sideBar.background": "#222222"},
           "tokenColors": [{"scope": "comment", "settings": {"foreground": "#00ff00"}}]})},
        {"themes/purple.json",
         """
         // VS Code's format: comments, trailing commas, an include
         {
           "include": "./base.json",
           "colors": {
             "editor.background": "#2D1B4E",
             "statusBar.background": "#ff00ffcc",
             "titleBar.activeBackground": "red",
             "bad key}": "#ffffff",
             "panel.border": null,
           },
           "tokenColors": [{"scope": ["keyword"], "settings": {"foreground": "#ff79c6"}}],
         }
         """}
      ]
    )
  end

  test "Bee's own themes have no colors of their own" do
    ids = Enum.map(ColorThemes.themes(), & &1.id)
    assert ["dark", "light"] = Enum.take(ids, 2)

    assert %Theme{id: "light", base: :light, custom?: false, colors: colors} =
             ColorThemes.get("light")

    assert colors == %{}
    assert Theme.css(ColorThemes.get("light"), "#workbench") == ""
    assert Theme.terminal(ColorThemes.get("light")) == nil

    # Unknown: Bee's dark one.
    assert %Theme{id: "dark", base: :dark} = ColorThemes.get("no-such-theme")
    assert %Theme{id: "dark"} = ColorThemes.get(nil)
  end

  test "a plugin's theme: its colors over those it includes, over VS Code's defaults" do
    purple()

    assert %{id: "purple", label: "Purple", base: :dark, plugin: "purple"} =
             ColorThemes.theme("purple")

    theme = ColorThemes.get("purple")
    assert %Theme{custom?: true, base: :dark} = theme

    # Its own, lowercased; over the included file's.
    assert theme.colors["editor.background"] == "#2d1b4e"
    assert theme.colors["statusBar.background"] == "#ff00ffcc"
    assert theme.colors["sideBar.background"] == "#222222"
    # Not hex colors, or not a key: dropped, so the default applies.
    assert theme.colors["titleBar.activeBackground"] == "#3c3c3c"
    refute Map.has_key?(theme.colors, "bad key}")
    assert theme.colors["panel.border"] == "#80808059"
    # A default naming another key takes that key's color, the theme's.
    assert theme.colors["tab.activeBackground"] == "#2d1b4e"
    assert theme.colors["terminal.background"] == "#2d1b4e"

    # The included file's token rules first.
    assert [%{"scope" => "comment"}, %{"scope" => ["keyword"]}] = theme.token_colors

    css = Theme.css(theme, "#workbench")
    assert css =~ ~r/^#workbench\{.*\}$/
    assert css =~ "--vscode-editor-background:#2d1b4e;"
    assert css =~ "--vscode-statusBar-background:#ff00ffcc;"
    assert css =~ "--color-base-100:#2d1b4e;"
    assert css =~ "--color-base-200:#222222;"

    assert %{background: "#2d1b4e", red: "#cd3131", brightWhite: "#e5e5e5"} =
             Theme.terminal(theme)
  end

  test "a light theme gets the light defaults; the id is the label when there is none" do
    install_theme("paper", [%{label: "Paper", uiTheme: "vs", path: "./themes/paper.json"}], [
      {"themes/paper.json", ~s({"colors": {"editor.background": "#fdf6e3"}})}
    ])

    assert %Theme{id: "Paper", base: :light} = theme = ColorThemes.get("Paper")
    assert theme.colors["sideBar.background"] == "#f3f3f3"
    assert theme.colors["tab.activeBackground"] == "#fdf6e3"
  end

  test "a theme file that can't be read gives Bee's theme of its base" do
    install_theme(
      "broken",
      [%{id: "broken", label: "Broken", uiTheme: "vs", path: "./themes/b.json"}],
      [
        {"themes/b.json", ~s({"include": "../../elsewhere.json"})}
      ]
    )

    assert %Theme{id: "broken", base: :light, custom?: false} = ColorThemes.get("broken")

    File.write!(Path.join([Plugins.user_dir(), "broken", "themes/b.json"]), "{nope")
    assert %Theme{custom?: false} = ColorThemes.get("broken")
  end

  test "the cache follows changes to the theme's files" do
    dir = purple()
    assert ColorThemes.get("purple").colors["sideBar.background"] == "#222222"

    base = Path.join(dir, "themes/base.json")
    File.write!(base, ~s({"colors": {"sideBar.background": "#333333"}}))
    File.touch!(base, System.os_time(:second) + 5)

    assert ColorThemes.get("purple").colors["sideBar.background"] == "#333333"
  end

  test "a theme's path must be inside its plugin, and its id must be new" do
    install_theme("escape", [%{id: "x", label: "X", uiTheme: "vs", path: "../x.json"}], [])
    assert ColorThemes.theme("x") == nil

    assert Plugins.get("escape").errors |> Enum.map_join(& &1.message) =~
             "must be inside the plugin"

    install_theme("again", [%{id: "dark", label: "Mine", uiTheme: "vs-dark", path: "t.json"}], [])
    assert ColorThemes.theme("dark").plugin == nil

    assert Plugins.get("again").errors |> Enum.map_join(& &1.message) =~
             ~s(color theme "dark" is already defined)
  end
end

defmodule Bee.IconThemesTest do
  # Plugins and contributions are global.
  use ExUnit.Case, async: false

  alias Bee.{IconThemes, Plugins}
  alias Bee.IconThemes.Theme

  @moduletag :capture_log

  setup do
    dir = Plugins.user_dir()
    File.rm_rf!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Plugins.reload()
    end)

    %{dir: dir}
  end

  @doc false
  # An icon theme plugin `name` in the user's plugins folder.
  def install_theme(name, id, extra \\ %{}) do
    dir = Path.join(Plugins.user_dir(), name)
    File.mkdir_p!(Path.join(dir, "icons"))

    File.write!(
      Path.join(dir, "plugin.json"),
      Jason.encode!(%{
        name: name,
        version: "1.0.0",
        contributes: %{
          iconThemes: [Map.merge(%{id: id, label: "Icons #{id}", path: "./theme.json"}, extra)]
        }
      })
    )

    File.write!(
      Path.join(dir, "theme.json"),
      """
      // VS Code's format
      {
        "iconDefinitions": {
          "_file": {"iconPath": "./icons/file.svg"},
          "_elixir": {"iconPath": "./icons/elixir.svg"},
          "_outside": {"iconPath": "../../secret.svg"}
        },
        "file": "_file",
        "fileExtensions": {"ex": "_elixir", "zz": "_outside"},
      }
      """
    )

    for icon <- ~w(file elixir), do: File.write!(Path.join(dir, "icons/#{icon}.svg"), "<svg/>")
    Plugins.reload()
    dir
  end

  test "a plugin's icon theme is loaded and its icons may be served", %{dir: plugins} do
    dir = install_theme("my-icons", "my")
    File.write!(Path.join(plugins, "secret.svg"), "<svg/>")

    assert [%{id: "my", label: "Icons my", plugin: "my-icons"}] = IconThemes.themes()
    assert {:ok, theme} = IconThemes.load("my", :dark)
    assert Theme.file_icon(theme, "a.ex") =~ ~r"^/plugins/my-icons/icons/elixir.svg\?v=\d+$"
    # Outside the plugin's folder: dropped.
    assert Theme.file_icon(theme, "a.zz") == nil

    assert {:ok, _, :icon} = Plugins.asset_path("my-icons", "icons/elixir.svg")
    assert :error = Plugins.asset_path("my-icons", "theme.json")
    assert :error = Plugins.asset_path("my-icons", "../secret.svg")

    # Edited: read again.
    File.write!(Path.join(dir, "theme.json"), ~s({"iconDefinitions": {}}))
    File.touch!(Path.join(dir, "theme.json"), System.os_time(:second) + 5)
    assert {:ok, %Theme{icons: icons}} = IconThemes.load("my", :dark)
    assert icons == %{}
    assert :error = Plugins.asset_path("my-icons", "icons/elixir.svg")

    assert {:error, message} = IconThemes.load("nope", :dark)
    assert message =~ "no icon theme"
  end

  test "a theme's path must be inside its plugin, ids are unique" do
    install_theme("escape", "esc", %{path: "../theme.json"})
    assert Plugins.get("escape").status == :invalid
    assert IconThemes.themes() == []

    install_theme("first", "same")
    install_theme("second", "same")
    assert [%{plugin: "first"}] = IconThemes.themes()
    assert Plugins.get("second").status == :invalid
  end

  test "a disabled plugin's theme is gone" do
    install_theme("my-icons", "my")
    Bee.Contributions.unregister({:plugin, "my-icons"})
    assert IconThemes.themes() == []
    assert :error = Plugins.asset_path("my-icons", "icons/elixir.svg")
  end
end

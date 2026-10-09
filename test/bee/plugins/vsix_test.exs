defmodule Bee.Plugins.VsixTest do
  # Plugins are global.
  use ExUnit.Case, async: false

  alias Bee.Plugins
  alias Bee.Plugins.Vsix

  @moduletag :capture_log

  setup do
    File.rm_rf!(Plugins.user_dir())
    tmp = Path.join(System.tmp_dir!(), "bee_vsix_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      File.rm_rf!(Plugins.user_dir())
      Plugins.reload()
    end)

    %{tmp: tmp}
  end

  @package %{
    "name" => "Cool-Icons",
    "publisher" => "someone",
    "displayName" => "%displayName%",
    "description" => "Icons that are cool",
    "version" => "1.2.3",
    "contributes" => %{
      "iconThemes" => [%{"id" => "cool", "label" => "Cool Icons", "path" => "./theme.json"}],
      "commands" => [%{"command" => "cool.ignored", "title" => "Not for Bee"}]
    }
  }

  # A .vsix (zip) with `files` ({name, contents}) under extension/ by default.
  defp vsix(tmp, files, name \\ "cool.vsix") do
    path = Path.join(tmp, name)
    entries = for {file, data} <- files, do: {String.to_charlist(file), data}
    {:ok, _} = :zip.create(String.to_charlist(path), entries)
    path
  end

  defp theme_files(package \\ @package) do
    [
      {"[Content_Types].xml", "<Types/>"},
      {"extension/package.json", Jason.encode!(package)},
      {"extension/package.nls.json", ~s({"displayName": "Cool Icons Theme"})},
      {"extension/theme.json",
       ~s({"iconDefinitions": {"f": {"iconPath": "./icons/f.svg"}}, "file": "f"})},
      {"extension/icons/f.svg", "<svg/>"}
    ]
  end

  test "installs an icon theme extension as a plugin", %{tmp: tmp} do
    assert {:ok, "cool-icons"} = Vsix.install(vsix(tmp, theme_files()))

    dir = Path.join(Plugins.user_dir(), "cool-icons")
    assert File.read!(Path.join(dir, "icons/f.svg")) == "<svg/>"
    refute File.exists?(Path.join(dir, "[Content_Types].xml"))

    manifest = Jason.decode!(File.read!(Path.join(dir, "plugin.json")))

    assert manifest == %{
             "name" => "cool-icons",
             "displayName" => "Cool Icons Theme",
             "description" => "Icons that are cool",
             "version" => "1.2.3",
             "contributes" => %{
               "iconThemes" => [
                 %{"id" => "cool", "label" => "Cool Icons", "path" => "./theme.json"}
               ]
             }
           }

    assert %{status: :inactive, scope: :user} = Plugins.get("cool-icons")
    assert {:ok, _theme} = Bee.IconThemes.load("cool", :dark)

    # Again (an update): replaced.
    package = Map.put(@package, "version", "2.0.0")
    assert {:ok, "cool-icons"} = Vsix.install(vsix(tmp, theme_files(package), "v2.vsix"))
    assert Plugins.get("cool-icons").version == "2.0.0"
    refute File.exists?(Path.join(Bee.Settings.user_dir(), ".installing-cool-icons"))
  end

  test "installs a color theme extension as a plugin", %{tmp: tmp} do
    package = %{
      "name" => "night-owl",
      "version" => "1.0.0",
      "contributes" => %{
        "themes" => [
          %{"label" => "%themeLabel%", "uiTheme" => "vs-dark", "path" => "./themes/owl.json"},
          %{
            "label" => "Owl Light",
            "uiTheme" => "vs",
            "path" => "./themes/light.json",
            "extra" => 1
          },
          %{"label" => "Unknown base", "uiTheme" => "sepia", "path" => "./themes/x.json"}
        ]
      }
    }

    files = [
      {"extension/package.json", Jason.encode!(package)},
      {"extension/package.nls.json", ~s({"themeLabel": "Night Owl"})},
      {"extension/themes/owl.json", ~s({"colors": {"editor.background": "#011627"}})},
      {"extension/themes/light.json", ~s({"colors": {}})}
    ]

    assert {:ok, "night-owl"} = Vsix.install(vsix(tmp, files))

    manifest =
      Jason.decode!(File.read!(Path.join([Plugins.user_dir(), "night-owl", "plugin.json"])))

    assert manifest["contributes"] == %{
             "themes" => [
               %{"label" => "Night Owl", "uiTheme" => "vs-dark", "path" => "./themes/owl.json"},
               %{"label" => "Owl Light", "uiTheme" => "vs", "path" => "./themes/light.json"}
             ]
           }

    assert Bee.ColorThemes.get("Night Owl").colors["editor.background"] == "#011627"
    assert %{base: :light} = Bee.ColorThemes.theme("Owl Light")
  end

  test "never replaces a plugin it didn't install", %{tmp: tmp} do
    dir = Path.join(Plugins.user_dir(), "cool-icons")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mine.txt"), "mine")

    assert {:error, message} = Vsix.install(vsix(tmp, theme_files()))
    assert message =~ "wasn't installed from a VSIX"
    assert File.read!(Path.join(dir, "mine.txt")) == "mine"
  end

  test "installs any extension: what Bee doesn't understand is left out", %{tmp: tmp} do
    no_themes = put_in(@package, ["contributes"], %{"commands" => []})

    files =
      List.keyreplace(
        theme_files(),
        "extension/package.json",
        0,
        {"extension/package.json", Jason.encode!(no_themes)}
      )

    assert {:ok, "cool-icons"} = Vsix.install(vsix(tmp, files))
    assert %{scope: :user, errors: []} = Plugins.get("cool-icons")

    manifest =
      Jason.decode!(File.read!(Path.join([Plugins.user_dir(), "cool-icons", "plugin.json"])))

    assert manifest["contributes"] == %{}
  end

  test "refuses what isn't an extension", %{tmp: tmp} do
    assert {:error, message} = Vsix.install(vsix(tmp, [{"extension/readme.md", "hi"}]))
    assert message =~ "no extension/package.json"

    File.write!(Path.join(tmp, "fake.vsix"), "not a zip")
    assert {:error, message} = Vsix.install(Path.join(tmp, "fake.vsix"))
    assert message =~ "not a VSIX"

    assert {:error, message} =
             Vsix.install(vsix(tmp, theme_files() ++ [{"extension/../../evil.txt", "x"}]))

    assert message =~ "unsafe path"
    refute File.exists?(Path.join(Plugins.user_dir(), "cool-icons"))
  end

  describe "uninstall" do
    test "deletes a user plugin's folder", %{tmp: tmp} do
      {:ok, name} = Vsix.install(vsix(tmp, theme_files()))
      assert :ok = Plugins.uninstall(name)
      refute File.exists?(Path.join(Plugins.user_dir(), name))
      assert Plugins.get(name) == nil
      assert Bee.IconThemes.themes() == []
    end

    test "a symlinked plugin: only the link goes", %{tmp: tmp} do
      target = Path.join(tmp, "dev-plugin")
      File.mkdir_p!(target)
      File.write!(Path.join(target, "plugin.json"), ~s({"name": "dev", "contributes": {}}))
      File.mkdir_p!(Plugins.user_dir())
      File.ln_s!(target, Path.join(Plugins.user_dir(), "dev"))
      Plugins.reload()

      assert :ok = Plugins.uninstall("dev")
      refute File.exists?(Path.join(Plugins.user_dir(), "dev"))
      assert File.exists?(Path.join(target, "plugin.json"))
    end

    test "only user plugins" do
      assert {:error, message} = Plugins.uninstall("nope")
      assert message =~ "no plugin"
    end
  end
end

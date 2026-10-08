defmodule Bee.Plugins.DetailsTest do
  # Plugins are global.
  use ExUnit.Case, async: false

  alias Bee.Plugins
  alias Bee.Plugins.{Details, Vsix}

  @moduletag :capture_log

  setup do
    File.rm_rf!(Plugins.user_dir())
    tmp = Path.join(System.tmp_dir!(), "bee_details_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      File.rm_rf!(Plugins.user_dir())
      Plugins.reload()
    end)

    %{tmp: tmp}
  end

  test "a VSIX's details come from its package.json and README", %{tmp: tmp} do
    package = %{
      "name" => "owl",
      "displayName" => "Night Owl",
      "publisher" => "sdras",
      "version" => "2.0.1",
      "license" => "MIT",
      "repository" => %{"type" => "git", "url" => "git+https://github.com/sdras/night-owl.git"},
      "icon" => "icon.png",
      "categories" => ["Themes"],
      "contributes" => %{
        "themes" => [%{"label" => "Night Owl", "uiTheme" => "vs-dark", "path" => "./t.json"}],
        "commands" => [%{"command" => "owl.ignored", "title" => "Not for Bee"}]
      }
    }

    zip = Path.join(tmp, "owl.vsix")

    {:ok, _} =
      :zip.create(String.to_charlist(zip), [
        {~c"extension/package.json", Jason.encode!(package)},
        {~c"extension/README.md", "# Night Owl"},
        {~c"extension/icon.png", "png"},
        {~c"extension/t.json", ~s({"colors": {}})}
      ])

    {:ok, "owl"} = Vsix.install(zip)
    details = Details.get(Plugins.get("owl"))

    assert %{
             display_name: "Night Owl",
             publisher: "sdras",
             version: "2.0.1",
             license: "MIT",
             repository: "https://github.com/sdras/night-owl",
             icon: "/plugins/owl/icon.png",
             categories: ["Themes"],
             readme: "# Night Owl",
             source: :vsix,
             scope: :user,
             color_themes: ["Night Owl"],
             icon_themes: []
           } = details

    # Features: what Bee uses (plugin.json), not all package.json lists.
    assert [%{title: "Color Themes", rows: [["Night Owl", "dark"]]}] = details.features

    assert {:ok, _path, :icon} = Plugins.asset_path("owl", "icon.png")
    assert :error = Plugins.asset_path("owl", "README.md")
    assert :error = Plugins.asset_path("owl", "../owl/../../secret.png")
  end
end

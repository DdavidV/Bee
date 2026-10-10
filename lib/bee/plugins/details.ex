defmodule Bee.Plugins.Details do
  @moduledoc """
  What a plugin's details page shows (VS Code's extension editor), from
  what the plugin itself has – there is no marketplace:

    * its manifest (`plugin.json`, or what Bee reads of a VS Code
      extension's `package.json`): name, version, description, what it
      contributes (the Features tab)
    * for one installed from a VSIX, the extension's own `package.json`:
      publisher, license, repository, homepage, icon, categories
    * its `README.md` (the Details tab), and its icon, which the page
      loads from the plugin's folder (`Bee.Plugins.asset_path/2`)
  """

  @marker ".vsix.json"

  @type feature :: %{title: String.t(), headers: [String.t()], rows: [[String.t()]]}

  @doc "The details of plugin record `plugin` (`Bee.Plugins.get/2`)."
  def get(plugin) do
    manifest = plugin.manifest || %{}
    vsix? = File.exists?(Path.join(plugin.dir, @marker))
    marker = if vsix?, do: Bee.Plugins.Vsix.marker(plugin.dir), else: %{}
    package = if vsix?, do: read_json(Path.join(plugin.dir, "package.json")), else: %{}
    info = Map.merge(manifest, package)

    %{
      name: plugin.name,
      display_name: plugin.display_name,
      description: plugin.description,
      version: plugin.version,
      scope: plugin.scope,
      status: plugin.status,
      errors: plugin.errors,
      warnings: plugin.warnings,
      dir: plugin.dir,
      source: if(vsix?, do: :vsix, else: :folder),
      open_vsx: marker["openVsx"],
      target_platform: marker["targetPlatform"],
      publisher: string(info["publisher"]),
      license: string(info["license"]),
      repository: url(info["repository"]),
      homepage: url(info["homepage"]),
      categories: Enum.filter(List.wrap(info["categories"]), &is_binary/1),
      icon: icon(plugin, info["icon"]),
      readme: readme(plugin.dir),
      runs: runs(plugin),
      missing_dependencies: missing_dependencies(manifest),
      activation_events: plugin.activation_events,
      color_themes: Enum.map(List.wrap(get_in(manifest, ["contributes", "themes"])), &theme_id/1),
      icon_themes:
        Enum.map(List.wrap(get_in(manifest, ["contributes", "iconThemes"])), & &1["id"]),
      features: features(manifest["contributes"] || %{})
    }
  end

  # The extensions its code needs (`extensionDependencies`) that aren't
  # installed: its own code isn't run without them.
  defp missing_dependencies(manifest) do
    installed =
      for plugin <- Bee.Plugins.list(),
          id = Bee.Plugins.Vsix.extension_id(plugin.dir),
          into: MapSet.new(),
          do: id

    for id <- List.wrap(get_in(manifest, ["extension", "dependencies"])),
        is_binary(id) and String.downcase(id) not in installed,
        do: id
  end

  defp read_json(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = json} <- Bee.JSON.JSONC.decode(text) do
      json
    else
      _ -> %{}
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  # package.json's repository: "url" or %{"url" => …}; web links only.
  defp url(%{"url" => url}), do: url(url)

  defp url(url) when is_binary(url) do
    url = url |> String.replace_prefix("git+", "") |> String.replace_suffix(".git", "")
    if String.starts_with?(url, ["https://", "http://"]), do: url
  end

  defp url(_url), do: nil

  # A URL the page can load the icon from, when it is a file in the folder.
  defp icon(plugin, rel) when is_binary(rel) do
    path = Path.expand(rel, plugin.dir)

    if String.starts_with?(path, plugin.dir <> "/") and File.regular?(path),
      do: "/plugins/#{URI.encode(plugin.name)}/#{URI.encode(Path.relative_to(path, plugin.dir))}"
  end

  defp icon(_plugin, _rel), do: nil

  defp readme(dir) do
    with {:ok, files} <- File.ls(dir),
         name when is_binary(name) <- Enum.find(files, &(String.downcase(&1) == "readme.md")),
         {:ok, text} <- File.read(Path.join(dir, name)),
         true <- String.valid?(text) do
      text
    else
      _ -> nil
    end
  end

  defp runs(plugin) do
    case [
           plugin.server? && "server",
           plugin.browser && "browser",
           plugin.extension? && "extension host (Node.js)"
         ]
         |> Enum.filter(& &1) do
      [] -> "contributions only"
      kinds -> Enum.join(kinds, " + ")
    end
  end

  defp theme_id(theme), do: theme["id"] || theme["label"]

  ## Features: what it contributes, as tables

  defp features(contributes) do
    keys = keybindings(contributes["keybindings"])

    [
      table("Commands", ["Command", "Title", "Keybinding"], contributes["commands"], fn c ->
        title = if c["category"], do: "#{c["category"]}: #{c["title"]}", else: c["title"]
        [c["command"], title, Enum.join(Map.get(keys, c["command"], []), ", ")]
      end),
      table(
        "Settings",
        ["Setting", "Default", "Description"],
        settings(contributes["configuration"]),
        fn {key, spec} ->
          [key, default(spec), spec["markdownDescription"] || spec["description"]]
        end
      ),
      table("Color Themes", ["Theme", "Kind"], contributes["themes"], fn t ->
        [t["label"], if(t["uiTheme"] in ["vs", "hc-light"], do: "light", else: "dark")]
      end),
      table(
        "File Icon Themes",
        ["Theme", "Id"],
        contributes["iconThemes"],
        &[&1["label"], &1["id"]]
      ),
      table("Languages", ["Language", "Files"], contributes["languages"], fn l ->
        files = List.wrap(l["extensions"]) ++ List.wrap(l["filenames"])
        [Enum.join(List.wrap(l["aliases"] || l["id"]), ", "), Enum.join(files, " ")]
      end),
      table("JSON Validation", ["Files", "Schema"], contributes["jsonValidation"], fn v ->
        [Enum.join(List.wrap(v["fileMatch"]), " "), v["url"]]
      end),
      table("Snippets", ["Language", "File"], contributes["snippets"], fn sn ->
        [sn["language"] || "all languages", sn["path"]]
      end),
      table("Views", ["View", "Where"], views(contributes["views"]), fn {where, v} ->
        [v["name"], where]
      end),
      table(
        "Activity Bar and Panel",
        ["Container", "Where"],
        containers(contributes["viewsContainers"]),
        fn
          {where, c} -> [c["title"], where]
        end
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp table(_title, _headers, rows, _fun) when rows in [nil, []], do: nil

  defp table(title, headers, rows, fun),
    do: %{
      title: title,
      headers: headers,
      rows: Enum.map(List.wrap(rows), &Enum.map(fun.(&1), fn v -> v || "" end))
    }

  defp keybindings(list) do
    list
    |> List.wrap()
    |> Enum.group_by(& &1["command"], & &1["key"])
  end

  defp settings(%{"properties" => props}) when is_map(props), do: Enum.sort(props)
  defp settings(list) when is_list(list), do: Enum.flat_map(list, &settings/1)
  defp settings(_), do: []

  defp default(%{"default" => value}), do: Jason.encode!(value)
  defp default(_spec), do: ""

  defp views(views) when is_map(views),
    do: for({where, list} <- Enum.sort(views), v <- List.wrap(list), do: {where, v})

  defp views(_), do: []

  defp containers(containers) when is_map(containers),
    do: for({where, list} <- Enum.sort(containers), c <- List.wrap(list), do: {where, c})

  defp containers(_), do: []
end

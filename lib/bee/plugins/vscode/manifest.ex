defmodule Bee.Plugins.VSCode.Manifest do
  @moduledoc """
  Reads a VS Code extension's `package.json` as a Bee manifest
  (`priv/schemas/manifest.schema.json`), when the plugin is loaded: what
  Bee understands of an installed extension grows with Bee, without
  installing it again.

  Taken from `contributes`: commands, keybindings, menus and submenus
  (`Bee.Commands.Registry`), settings and their defaults
  (`Bee.Settings.Configuration`), file icon themes (`Bee.IconThemes`),
  color themes (`Bee.ColorThemes`), languages with their configuration and
  TextMate grammars (`Bee.Languages`), snippets (`Bee.Snippets`) and JSON
  schemas (`Bee.JSONValidation`). The rest does nothing yet.

  The extension's code (`main`) becomes the plugin's `extension` part: its
  commands are `"runtime": "extension"` ones, registered by that code when
  the extension host runs it.

  Unlike a plugin's own `plugin.json`, where a mistake rejects the plugin,
  this is lenient: an entry Bee can't use (a missing file, a field it
  doesn't know the value of) is left out with a warning, and the rest of
  the extension loads. `"%key%"` texts are looked up in `package.nls.json`.

  A `"bee"` section adds Bee's own parts to an extension, so one package
  works in VS Code and in Bee:

      "bee": {"server": {"module": "MyExt"}, "browser": "bee/browser.js"}
  """

  @marker ".vsix.json"

  @type warning :: String.t()

  @doc "Whether the plugin folder `dir` is a VS Code extension installed from a VSIX."
  def extension?(dir),
    do: File.exists?(Path.join(dir, @marker)) and File.exists?(Path.join(dir, "package.json"))

  @doc "The `package.json` of the extension in `dir`."
  def package_path(dir), do: Path.join(dir, "package.json")

  @doc """
  The manifest of the extension in `dir`: `{:ok, manifest, warnings}` or
  `{:error, message}` (no readable `package.json`, no name).
  """
  @spec read(Path.t()) :: {:ok, map(), [warning]} | {:error, String.t()}
  def read(dir) do
    with {:ok, package} <- json(package_path(dir)), do: from_package(package, dir)
  end

  @doc "Like `read/1`, for an already decoded `package.json`."
  @spec from_package(map(), Path.t()) :: {:ok, map(), [warning]} | {:error, String.t()}
  def from_package(package, dir) do
    with {:ok, name} <- plugin_name(package) do
      nls =
        case json(Path.join(dir, "package.nls.json")) do
          {:ok, nls} -> nls
          {:error, _} -> %{}
        end

      main = string(package["main"])
      {contributes, warnings} = contributes(package, dir, nls, main != nil)

      manifest =
        %{
          "name" => name,
          "displayName" => localized(package["displayName"], nls) || package["name"],
          "description" => localized(package["description"], nls),
          "version" => string(package["version"]),
          "extension" => if(main, do: %{"main" => main}),
          "activationEvents" =>
            case strings(package["activationEvents"]) do
              [] -> nil
              events -> events
            end,
          "contributes" => contributes
        }
        |> Map.merge(bee_parts(package))
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      {:ok, manifest, warnings}
    end
  end

  @doc "A Bee plugin name (lowercase letters, digits, dashes) from the extension's."
  @spec plugin_name(map()) :: {:ok, String.t()} | {:error, String.t()}
  def plugin_name(package) do
    name =
      (string(package["name"]) || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")

    if name == "", do: {:error, "the extension has no name"}, else: {:ok, name}
  end

  # Bee's own parts; the manifest schema checks them.
  defp bee_parts(%{"bee" => %{} = bee}), do: Map.take(bee, ~w(server browser))
  defp bee_parts(_package), do: %{}

  ## Contributions

  # `{contributes, warnings}`: each point's entries Bee can use, and why
  # the others were left out.
  defp contributes(package, dir, nls, main?) do
    section = fn key -> get_in(package, ["contributes", key]) end

    lists = [
      {"commands", &command(&1, dir, nls, main?)},
      {"keybindings", &keybinding/1},
      {"submenus", &submenu(&1, nls)},
      {"languages", &language(&1, dir)},
      {"grammars", &grammar(&1, dir)},
      {"snippets", &snippet(&1, dir)},
      {"jsonValidation", &json_validation(&1, dir)},
      {"iconThemes", &icon_theme(&1, nls)},
      {"themes", &theme(&1, nls)}
    ]

    acc =
      for {point, translate} <- lists, reduce: {%{}, []} do
        acc -> put(acc, point, entries(section.(point), "contributes.#{point}", translate))
      end

    # Menu id → items.
    acc =
      for {menu, items} when is_binary(menu) <- map(section.("menus")), reduce: acc do
        {contributes, warnings} ->
          {kept, dropped} = entries(items, "contributes.menus.#{menu}", &menu_item/1)

          contributes =
            if kept == [],
              do: contributes,
              else: Map.update(contributes, "menus", %{menu => kept}, &Map.put(&1, menu, kept))

          {contributes, warnings ++ dropped}
      end

    acc = put(acc, "configuration", configuration(section.("configuration"), nls))

    case map(section.("configurationDefaults")) do
      defaults when defaults == %{} -> acc
      defaults -> put(acc, "configurationDefaults", {defaults, []})
    end
  end

  defp put({contributes, warnings}, _point, {empty, dropped}) when empty in [[], nil],
    do: {contributes, warnings ++ dropped}

  defp put({contributes, warnings}, point, {kept, dropped}),
    do: {Map.put(contributes, point, kept), warnings ++ dropped}

  # `{kept, warnings}` of a list of entries: `translate` gives `{:ok,
  # entry}`, `{:ok, entry, warnings}` or `{:drop, reason}`.
  defp entries(list, where, translate) do
    results =
      for entry <- List.wrap(list),
          do: if(is_map(entry), do: translate.(entry), else: {:drop, "is not an object"})

    kept = for result <- results, elem(result, 0) == :ok, do: elem(result, 1)

    warnings =
      results
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:drop, reason}, index} -> ["#{where}[#{index}] #{reason}"]
        {{:ok, _entry, notes}, index} -> Enum.map(notes, &"#{where}[#{index}] #{&1}")
        {{:ok, _entry}, _index} -> []
      end)

    {kept, warnings}
  end

  defp map(%{} = map), do: map
  defp map(_other), do: %{}

  ## Commands, keybindings, menus

  # A command of the extension's code. Its icon: a codicon, or images in
  # the extension.
  defp command(%{"command" => id} = c, dir, nls, main?) when is_binary(id) do
    title = text(c["title"], nls)

    cond do
      not Regex.match?(~r/^[A-Za-z0-9_.-]+$/, id) ->
        {:drop, "has the id #{inspect(id)}, which Bee can't use"}

      title == nil ->
        {:drop, "(#{id}) has no title"}

      not main? ->
        {:drop, "(#{id}) needs the extension's code, and it has no main"}

      true ->
        {enablement, notes} = when_clause(c["enablement"], "enablement")

        {:ok,
         %{
           "command" => id,
           "title" => title,
           "category" => text(c["category"], nls),
           "icon" => command_icon(c["icon"], dir),
           "enablement" => enablement,
           "runtime" => "extension"
         }
         |> Map.reject(fn {_k, v} -> is_nil(v) end), notes}
    end
  end

  defp command(_command, _dir, _nls, _main?), do: {:drop, "has no command id"}

  @images ~w(.png .jpg .jpeg .gif .svg .webp)

  defp command_icon("$(" <> _ = icon, _dir),
    do: if(Regex.match?(~r/^\$\([a-z0-9-]+(~spin)?\)$/, icon), do: icon)

  defp command_icon(path, dir) when is_binary(path),
    do: command_icon(%{"light" => path, "dark" => path}, dir)

  defp command_icon(%{"light" => light, "dark" => dark}, dir) do
    if Enum.all?(
         [light, dark],
         &(file?(dir, &1) and String.downcase(Path.extname(&1)) in @images)
       ),
       do: %{"light" => light, "dark" => dark}
  end

  defp command_icon(_icon, _dir), do: nil

  # A `when` clause Bee can read, else none (with a note).
  defp when_clause(nil, _what), do: {nil, []}

  defp when_clause(source, what) when is_binary(source) do
    case Bee.Commands.When.parse(source) do
      {:ok, _ast} -> {source, []}
      {:error, reason} -> {nil, ["has an #{what} Bee can't read, left out: #{reason}"]}
    end
  end

  defp when_clause(_source, what), do: {nil, ["has an #{what} that is not text, left out"]}

  @platforms ~w(key mac linux win)

  defp keybinding(%{"command" => command} = k) when is_binary(command) and command != "" do
    keys = for platform <- @platforms, key = k[platform], into: %{}, do: {platform, key}

    bad =
      Enum.find_value(keys, fn {_platform, key} ->
        case is_binary(key) && Bee.Commands.Keys.parse(key) do
          {:ok, _strokes} -> nil
          {:error, reason} -> reason
          false -> "a key that is not text"
        end
      end)

    cond do
      keys == %{} ->
        {:drop, "(#{command}) has no key"}

      bad ->
        {:drop, "(#{command}) has a key Bee can't bind: #{bad}"}

      not when?(k["when"]) ->
        {:drop, "(#{command}) has a when clause Bee can't read"}

      true ->
        {:ok,
         keys
         |> Map.merge(%{"command" => command, "when" => k["when"], "args" => k["args"]})
         |> Map.reject(fn {_k, v} -> is_nil(v) end)}
    end
  end

  defp keybinding(_keybinding), do: {:drop, "has no command"}

  defp when?(nil), do: true
  defp when?(source) when is_binary(source), do: match?({:ok, _}, Bee.Commands.When.parse(source))
  defp when?(_source), do: false

  defp submenu(%{"id" => id} = m, nls) when is_binary(id) and id != "" do
    case text(m["label"], nls) do
      nil -> {:drop, "(#{id}) has no label"}
      label -> {:ok, %{"id" => id, "label" => label}}
    end
  end

  defp submenu(_submenu, _nls), do: {:drop, "has no id"}

  # An item of a menu: a command (of any extension, or Bee's), or a
  # submenu. `alt` (the command with Alt held) isn't used.
  defp menu_item(item) do
    target =
      cond do
        string(item["command"]) -> %{"command" => item["command"]}
        string(item["submenu"]) -> %{"submenu" => item["submenu"]}
        true -> nil
      end

    cond do
      target == nil ->
        {:drop, "names no command or submenu"}

      not when?(item["when"]) ->
        {:drop, "(#{target["command"] || target["submenu"]}) has a when clause Bee can't read"}

      true ->
        {:ok,
         target
         |> Map.merge(%{"when" => item["when"], "group" => group(item["group"])})
         |> Map.reject(fn {_k, v} -> is_nil(v) end)}
    end
  end

  # "navigation@1": Bee's orders are whole numbers from 0.
  defp group(group) when is_binary(group) do
    case String.split(group, "@") do
      [name] when name != "" ->
        name

      [name, order] when name != "" ->
        case Float.parse(order) do
          {number, ""} -> "#{name}@#{max(round(number), 0)}"
          _ -> name
        end

      _ ->
        nil
    end
  end

  defp group(_group), do: nil

  ## Settings

  @setting ~r/^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/

  # One section or a list of them → `{sections, warnings}`. A setting
  # whose schema Bee can't use is kept without it: any value goes.
  defp configuration(configuration, nls) do
    {sections, warnings} =
      configuration
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn
        {%{"properties" => %{} = properties} = section, index} ->
          {properties, warnings} =
            Enum.reduce(properties, {%{}, []}, fn {name, spec}, {properties, warnings} ->
              where = "contributes.configuration[#{index}] #{name}"

              cond do
                not Regex.match?(@setting, name) ->
                  {properties, warnings ++ ["#{where} is a name Bee can't use"]}

                not is_map(spec) ->
                  {properties, warnings ++ ["#{where} is not an object"]}

                true ->
                  spec = describe(spec, nls)

                  if usable_schema?(name, spec) do
                    {Map.put(properties, name, spec), warnings}
                  else
                    {Map.put(properties, name, Map.take(spec, ~w(description default))),
                     warnings ++
                       ["#{where} has a schema Bee can't use: its values aren't checked"]}
                  end
              end
            end)

          section =
            %{
              "title" => text(section["title"], nls),
              "order" => if(is_number(section["order"]), do: section["order"]),
              "properties" => properties
            }
            |> Map.reject(fn {_k, v} -> is_nil(v) end)

          {if(properties == %{}, do: nil, else: section), warnings}

        {_other, index} ->
          {nil, ["contributes.configuration[#{index}] has no properties"]}
      end)
      |> Enum.unzip()

    {Enum.reject(sections, &is_nil/1), List.flatten(warnings)}
  end

  # Its descriptions translated; the plain one Bee shows is the Markdown
  # one when there is no other.
  defp describe(spec, nls) do
    markdown = text(spec["markdownDescription"], nls)

    spec
    |> Map.drop(~w(description markdownDescription))
    |> Map.merge(
      Map.reject(
        %{
          "description" => text(spec["description"], nls) || markdown,
          "markdownDescription" => markdown
        },
        fn {_k, v} -> is_nil(v) end
      )
    )
  end

  # No reference to a schema elsewhere (it would be fetched), and one the
  # validator accepts.
  defp usable_schema?(name, spec) do
    not remote_ref?(spec) and
      match?(
        {:ok, _},
        Bee.JSON.Schema.resolve(%{"type" => "object", "properties" => %{name => spec}})
      )
  end

  defp remote_ref?(%{"$ref" => ref}) when is_binary(ref), do: not String.starts_with?(ref, "#")
  defp remote_ref?(%{} = map), do: Enum.any?(Map.values(map), &remote_ref?/1)
  defp remote_ref?(list) when is_list(list), do: Enum.any?(list, &remote_ref?/1)
  defp remote_ref?(_other), do: false

  ## Languages, themes

  # Languages: their ids, files, and configuration (when the extension has
  # its file); icons… aren't used yet.
  defp language(%{"id" => id} = l, dir) when is_binary(id) do
    if Regex.match?(~r/^[A-Za-z0-9_.+-]+$/, id) do
      {:ok,
       %{
         "id" => id,
         "aliases" => strings(l["aliases"]),
         "extensions" => Enum.filter(strings(l["extensions"]), &String.starts_with?(&1, ".")),
         "filenames" => strings(l["filenames"]),
         "filenamePatterns" => strings(l["filenamePatterns"]),
         "configuration" => if(file?(dir, l["configuration"]), do: l["configuration"]),
         # A JavaScript regex; kept when Elixir's understands it too.
         "firstLine" =>
           with(
             line when is_binary(line) and line != "" <- l["firstLine"],
             {:ok, _} <- Regex.compile(line),
             do: line,
             else: (_ -> nil)
           )
       }
       |> Map.reject(fn {_k, v} -> v in [nil, []] end)}
    else
      {:drop, "has the id #{inspect(id)}, which Bee can't use"}
    end
  end

  defp language(_language, _dir), do: {:drop, "has no id"}

  # TextMate grammars whose file is in the extension.
  defp grammar(%{"scopeName" => scope, "path" => path} = g, dir)
       when is_binary(scope) and scope != "" and is_binary(path) do
    if file?(dir, path) do
      {:ok,
       %{
         "scopeName" => scope,
         "path" => path,
         "language" => string(g["language"]),
         "injectTo" => strings(g["injectTo"]),
         "embeddedLanguages" =>
           for(
             {k, v} when is_binary(v) <-
               (is_map(g["embeddedLanguages"]) && g["embeddedLanguages"]) || %{},
             into: %{},
             do: {k, v}
           )
       }
       |> Map.reject(fn {_k, v} -> v in [nil, [], %{}] end)}
    else
      {:drop, "names the file #{path}, which the extension doesn't have"}
    end
  end

  defp grammar(_grammar, _dir), do: {:drop, "needs a scopeName and a path"}

  # JSON schemas: web addresses, or files that are in the extension.
  defp json_validation(%{"fileMatch" => match, "url" => url}, dir) when is_binary(url) do
    match = Enum.filter(List.wrap(match), &(is_binary(&1) and &1 != ""))

    cond do
      match == [] ->
        {:drop, "has no fileMatch"}

      String.starts_with?(url, ["http://", "https://"]) or file?(dir, url) ->
        {:ok, %{"fileMatch" => match, "url" => url}}

      true ->
        {:drop, "names the file #{url}, which the extension doesn't have"}
    end
  end

  defp json_validation(_entry, _dir), do: {:drop, "needs a fileMatch and a url"}

  # Snippet files that are in the extension.
  defp snippet(%{"path" => path} = s, dir) when is_binary(path) do
    cond do
      not file?(dir, path) -> {:drop, "names the file #{path}, which the extension doesn't have"}
      language = string(s["language"]) -> {:ok, %{"language" => language, "path" => path}}
      true -> {:ok, %{"path" => path}}
    end
  end

  defp snippet(_snippet, _dir), do: {:drop, "has no path"}

  defp icon_theme(theme, nls),
    do: {:ok, theme |> Map.take(~w(id label path)) |> localize_label(nls)}

  # Color themes need a label, a known uiTheme and a file.
  defp theme(%{"label" => label, "path" => path, "uiTheme" => ui} = theme, nls)
       when is_binary(label) and is_binary(path) do
    if ui in ~w(vs vs-dark hc-black hc-light),
      do: {:ok, theme |> Map.take(~w(id label uiTheme path)) |> localize_label(nls)},
      else: {:drop, "has the uiTheme #{inspect(ui)}, which Bee doesn't know"}
  end

  defp theme(_theme, _nls), do: {:drop, "needs a label, a uiTheme and a path"}

  ## Helpers

  # Whether `rel` ("./grammar/x.json") is a file inside the extension.
  defp file?(dir, rel) when is_binary(rel) do
    path = Path.join(dir, rel |> Path.expand("/") |> String.trim_leading("/"))
    File.regular?(path)
  end

  defp file?(_dir, _rel), do: false

  defp string(text) when is_binary(text) and text != "", do: text
  defp string(_text), do: nil

  defp strings(list) when is_list(list), do: Enum.filter(list, &(is_binary(&1) and &1 != ""))
  defp strings(_list), do: []

  defp localize_label(%{"label" => label} = theme, nls),
    do: %{theme | "label" => localized(label, nls) || label}

  defp localize_label(theme, _nls), do: theme

  # "%displayName%" → its text in package.nls.json.
  defp localized("%" <> _ = text, nls) do
    case nls[String.trim(text, "%")] do
      value when is_binary(value) -> value
      # VS Code also allows %{"message" => …, "comment" => …}.
      %{"message" => value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp localized(text, _nls) when is_binary(text), do: text
  defp localized(_text, _nls), do: nil

  # A text of the extension: plain, "%key%", or %{"value" => …} (a title
  # with its untranslated original). nil when there is none.
  defp text(%{"value" => value}, nls), do: text(value, nls)
  defp text(value, nls), do: string(localized(value, nls))

  defp json(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = map} <- Bee.JSON.JSONC.decode(text) do
      {:ok, map}
    else
      {:error, :enoent} -> {:error, "the extension has no #{Path.basename(path)}"}
      _ -> {:error, "#{Path.basename(path)} is not a JSON object"}
    end
  end
end

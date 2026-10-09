defmodule Bee.Plugins.Vsix do
  @moduledoc """
  Installs a VS Code extension package (`.vsix`, a zip as downloaded from
  the Marketplace or Open VSX) as a Bee plugin in the user's plugins
  folder. Any extension installs; its `plugin.json` gets the parts Bee
  understands: file icon themes (`contributes.iconThemes`, see
  `Bee.IconThemes`), color themes (`contributes.themes`, see
  `Bee.ColorThemes`), languages with their configuration and TextMate
  grammars (`Bee.Languages`), and snippets (`Bee.Snippets`). The rest of it
  does nothing yet.

  The extension's files (the zip's `extension/` folder) are unpacked into
  `<plugins>/<name>`, `name` being the extension's, and a `plugin.json` is
  written for them. A `.vsix.json` marker records where it came from
  (`openVsx`: its Open VSX id, see `Bee.Plugins.OpenVsx`; `targetPlatform`:
  which platform's package it is): installing
  again replaces a plugin installed this way (an update), never a folder
  of another kind or another Open VSX extension of the same name.
  """

  alias Bee.Plugins

  @marker ".vsix.json"
  @max_size 300_000_000
  @max_entries 50_000

  @doc """
  Installs the `.vsix` at `path`. Options: `source`, the Open VSX id it
  was downloaded as, and `target_platform`, the platform of its package. Returns `{:ok, plugin_name}` or `{:error, message}`.
  """
  @spec install(Path.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def install(path, opts \\ []) do
    source = opts[:source]
    origin = %{openVsx: source, targetPlatform: opts[:target_platform]}

    with {:ok, files} <- read(path),
         {:ok, package} <- json(files, "package.json"),
         contributes = contributes(package, files),
         {:ok, name} <- plugin_name(package),
         :ok <- check_target(name, source) do
      write(name, files, manifest(name, package, files, contributes), origin)
    end
  end

  @doc "The `.vsix.json` marker of plugin folder `dir` (`%{}` if there is none)."
  def marker(dir) do
    with {:ok, text} <- File.read(Path.join(dir, @marker)),
         {:ok, %{} = marker} <- Jason.decode(text) do
      marker
    else
      _ -> %{}
    end
  end

  ## Reading the package

  # The files under extension/, by their path inside it.
  defp read(path) do
    zip = String.to_charlist(path)

    with {:ok, [_comment | entries]} <- :zip.list_dir(zip),
         :ok <- check_size(entries),
         :ok <- check_paths(entries),
         {:ok, contents} <- :zip.unzip(zip, [:memory]) do
      files =
        for {name, data} <- contents,
            {:ok, rel} <- [entry_path(to_string(name))],
            into: %{},
            do: {rel, data}

      {:ok, files}
    else
      {:error, :einval} -> {:error, "not a VSIX (zip) file"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "can't read the package: #{inspect(reason)}"}
    end
  end

  # Against zip bombs: what it would unpack to, before unpacking.
  defp check_size(entries) do
    size = Enum.sum(for {:zip_file, _, info, _, _, _} <- entries, do: elem(info, 1))

    cond do
      length(entries) > @max_entries -> {:error, "the package has too many files"}
      size > @max_size -> {:error, "the package is too big (#{div(size, 1_000_000)} MB unpacked)"}
      true -> :ok
    end
  end

  # Before unpacking: :zip leaves out unsafe ones silently, we refuse them.
  defp check_paths(entries) do
    case Enum.find(entries, &(entry_path(to_string(elem(&1, 1))) == :error)) do
      nil -> :ok
      entry -> {:error, "unsafe path in the package: #{elem(entry, 1)}"}
    end
  end

  defp entry_path("extension/" <> rel) do
    segments = String.split(rel, "/")

    cond do
      rel == "" or String.ends_with?(rel, "/") -> :skip
      Enum.any?(segments, &(&1 in ["", ".", ".."])) or String.contains?(rel, "\\") -> :error
      true -> {:ok, rel}
    end
  end

  defp entry_path(path) do
    if Path.type(path) != :relative or ".." in String.split(path, ["/", "\\"]),
      do: :error,
      else: :skip
  end

  defp json(files, rel) do
    with {:ok, data} <- Map.fetch(files, rel),
         {:ok, %{} = map} <- Bee.JSON.JSONC.decode(data) do
      {:ok, map}
    else
      :error -> {:error, "the package has no extension/#{rel}"}
      _ -> {:error, "extension/#{rel} is not a JSON object"}
    end
  end

  # The contributes section of the plugin: what Bee knows of the
  # extension's, with the fields Bee knows (color themes need a label, a
  # known uiTheme and a file). Labels can be "%key%" (package.nls.json).
  defp contributes(package, files) do
    %{
      "languages" => languages(package, files),
      "grammars" => grammars(package, files),
      "snippets" => snippets(package, files),
      "iconThemes" =>
        for(
          %{} = t <- List.wrap(get_in(package, ["contributes", "iconThemes"])),
          do: t |> Map.take(~w(id label path)) |> localize_label(files)
        ),
      "themes" =>
        for(
          %{"label" => label, "path" => path, "uiTheme" => ui} = t <-
            List.wrap(get_in(package, ["contributes", "themes"])),
          is_binary(label) and is_binary(path) and ui in ~w(vs vs-dark hc-black hc-light),
          do: t |> Map.take(~w(id label uiTheme path)) |> localize_label(files)
        )
    }
    |> Map.reject(fn {_k, list} -> list == [] end)
  end

  # Languages: their ids, files, and configuration (when the package has
  # its file); icons… aren't used yet.
  defp languages(package, files) do
    for %{"id" => id} = l <- List.wrap(get_in(package, ["contributes", "languages"])),
        is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_.+-]+$/, id) do
      %{
        "id" => id,
        "aliases" => strings(l["aliases"]),
        "extensions" => Enum.filter(strings(l["extensions"]), &String.starts_with?(&1, ".")),
        "filenames" => strings(l["filenames"]),
        "filenamePatterns" => strings(l["filenamePatterns"]),
        "configuration" =>
          with(
            rel when is_binary(rel) <- l["configuration"],
            true <- Map.has_key?(files, package_path(rel)),
            do: rel,
            else: (_ -> nil)
          ),
        # A JavaScript regex; kept when Elixir's understands it too.
        "firstLine" =>
          with(
            line when is_binary(line) and line != "" <- l["firstLine"],
            {:ok, _} <- Regex.compile(line),
            do: line,
            else: (_ -> nil)
          )
      }
      |> Map.reject(fn {_k, v} -> v in [nil, []] end)
    end
  end

  # TextMate grammars whose file is in the package.
  defp grammars(package, files) do
    for %{"scopeName" => scope, "path" => path} = g <-
          List.wrap(get_in(package, ["contributes", "grammars"])),
        is_binary(scope) and scope != "" and is_binary(path),
        Map.has_key?(files, package_path(path)) do
      %{
        "scopeName" => scope,
        "path" => path,
        "language" => if(is_binary(g["language"]) and g["language"] != "", do: g["language"]),
        "injectTo" => strings(g["injectTo"]),
        "embeddedLanguages" =>
          for(
            {k, v} when is_binary(v) <-
              (is_map(g["embeddedLanguages"]) && g["embeddedLanguages"]) || %{},
            into: %{},
            do: {k, v}
          )
      }
      |> Map.reject(fn {_k, v} -> v in [nil, [], %{}] end)
    end
  end

  # Snippet files that are in the package.
  defp snippets(package, files) do
    for %{"path" => path} = s <- List.wrap(get_in(package, ["contributes", "snippets"])),
        is_binary(path) and Map.has_key?(files, package_path(path)) do
      if is_binary(s["language"]) and s["language"] != "",
        do: %{"language" => s["language"], "path" => path},
        else: %{"path" => path}
    end
  end

  # "./grammar/x.json" → "grammar/x.json", the key of `files`.
  defp package_path(rel), do: rel |> Path.expand("/") |> String.trim_leading("/")

  defp strings(list) when is_list(list), do: Enum.filter(list, &(is_binary(&1) and &1 != ""))
  defp strings(_list), do: []

  # A Bee plugin name (lowercase letters, digits, dashes) from the extension's.
  defp plugin_name(package) do
    name =
      (package["name"] || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")

    if name == "", do: {:error, "the extension has no name"}, else: {:ok, name}
  end

  defp check_target(name, source) do
    target = Path.join(Plugins.user_dir(), name)
    installed = marker(target)["openVsx"]

    cond do
      match?(%{scope: :builtin}, Plugins.get(name)) ->
        {:error, "#{name} is the name of a built-in plugin"}

      File.exists?(target) and not File.exists?(Path.join(target, @marker)) ->
        {:error, "#{target} already exists and wasn't installed from a VSIX; uninstall it first"}

      is_binary(source) and is_binary(installed) and
          String.downcase(source) != String.downcase(installed) ->
        {:error,
         "#{installed}, another extension named #{name}, is installed; uninstall it first"}

      true ->
        :ok
    end
  end

  defp manifest(name, package, files, contributes) do
    %{
      "name" => name,
      "displayName" => localized(package["displayName"], files) || package["name"],
      "description" => localized(package["description"], files),
      "version" => package["version"],
      "contributes" => contributes
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp localize_label(%{"label" => label} = theme, files),
    do: %{theme | "label" => localized(label, files) || label}

  defp localize_label(theme, _files), do: theme

  # "%displayName%" → its text in package.nls.json.
  defp localized("%" <> _ = text, files) do
    key = String.trim(text, "%")

    case json(files, "package.nls.json") do
      {:ok, %{^key => value}} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp localized(text, _files) when is_binary(text), do: text
  defp localized(_text, _files), do: nil

  ## Writing

  # Unpacked next to the plugins folder first, then moved in whole.
  defp write(name, files, manifest, origin) do
    tmp = Path.join(Bee.Settings.user_dir(), ".installing-#{name}")
    target = Path.join(Plugins.user_dir(), name)
    File.rm_rf!(tmp)

    for {rel, data} <- files do
      file = Path.join(tmp, rel)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, data)
    end

    File.write!(Path.join(tmp, "plugin.json"), Jason.encode!(manifest, pretty: true))

    File.write!(
      Path.join(tmp, @marker),
      %{name: manifest["name"], version: manifest["version"]}
      |> Map.merge(origin)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Jason.encode!(pretty: true)
    )

    File.mkdir_p!(Plugins.user_dir())
    File.rm_rf!(target)
    File.rename!(tmp, target)
    Plugins.reload(name)
    {:ok, name}
  rescue
    e in File.Error -> {:error, Exception.message(e)}
  end
end

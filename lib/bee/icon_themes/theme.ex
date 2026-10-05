defmodule Bee.IconThemes.Theme do
  @moduledoc """
  A file icon theme in VS Code's format (the JSON an `iconThemes`
  contribution points to), parsed, and the lookup of a file's or folder's
  icon in it.

      {
        "iconDefinitions": {"_file": {"iconPath": "./icons/file.svg"}, …},
        "file": "_file",
        "folder": "_folder", "folderExpanded": "_folder_open",
        "rootFolder": "…", "rootFolderExpanded": "…",
        "fileExtensions": {"ex": "_elixir"},       // without the dot
        "fileNames": {"mix.exs": "_mix"},
        "folderNames": {"src": "_src"}, "folderNamesExpanded": {…},
        "rootFolderNames": {…}, "rootFolderNamesExpanded": {…},
        "languageIds": {"elixir": "_elixir"},
        "light": {…the associations above, for light color themes…},
        "hidesExplorerArrows": false
      }

  Lookups work like VS Code's: names are matched case-insensitively, a file
  by its name, then its extensions (longest first: `test.ts`, then `ts`),
  then its language, then `file`; a folder by its name, then `folder`
  (`folderExpanded` when open, `rootFolder*` for the workspace root). The
  `light` section overrides the others when the color theme is light.

  Only `iconPath` definitions (SVG or PNG files) are supported; ones using
  an icon font (`fontCharacter`) are skipped, so their files fall back to
  Bee's own icons.
  """

  defstruct icons: %{},
            file: nil,
            folder: nil,
            folder_expanded: nil,
            root_folder: nil,
            root_folder_expanded: nil,
            file_extensions: %{},
            file_names: %{},
            folder_names: %{},
            folder_names_expanded: %{},
            root_folder_names: %{},
            root_folder_names_expanded: %{},
            language_ids: %{},
            hides_explorer_arrows: false

  @type t :: %__MODULE__{}

  @ids [
    file: "file",
    folder: "folder",
    folder_expanded: "folderExpanded",
    root_folder: "rootFolder",
    root_folder_expanded: "rootFolderExpanded"
  ]

  @maps [
    file_extensions: "fileExtensions",
    file_names: "fileNames",
    folder_names: "folderNames",
    folder_names_expanded: "folderNamesExpanded",
    root_folder_names: "rootFolderNames",
    root_folder_names_expanded: "rootFolderNamesExpanded",
    language_ids: "languageIds"
  ]

  @doc """
  Parses theme JSON (decoded). `icon` turns an `iconPath` (as written in
  the theme) into what the lookups return – a URL – or `nil` to drop it.
  Returns `%{dark: theme, light: theme}`.
  """
  @spec parse(map(), (String.t() -> String.t() | nil)) :: %{dark: t(), light: t()}
  def parse(json, icon) when is_map(json) do
    icons =
      for {id, %{"iconPath" => path}} when is_binary(path) <-
            Map.get(json, "iconDefinitions", %{}),
          url = icon.(path),
          into: %{},
          do: {id, url}

    dark = associations(%__MODULE__{icons: icons}, json)

    dark = %{dark | hides_explorer_arrows: json["hidesExplorerArrows"] == true}

    light =
      case json["light"] do
        %{} = light -> associations(dark, light)
        _ -> dark
      end

    %{dark: dark, light: light}
  end

  # Applies a section's associations on top of `theme`'s.
  defp associations(theme, section) do
    theme =
      Enum.reduce(@ids, theme, fn {field, key}, theme ->
        case section[key] do
          id when is_binary(id) -> Map.put(theme, field, id)
          _ -> theme
        end
      end)

    Enum.reduce(@maps, theme, fn {field, key}, theme ->
      case section[key] do
        %{} = map ->
          entries =
            for {name, id} when is_binary(id) <- map, into: %{}, do: {String.downcase(name), id}

          Map.update!(theme, field, &Map.merge(&1, entries))

        _ ->
          theme
      end
    end)
  end

  @doc """
  The icon (URL) of a file named `name`, or `nil` when the theme has none.
  `language` is its language id, if known.
  """
  @spec file_icon(t(), String.t(), String.t() | nil) :: String.t() | nil
  def file_icon(%__MODULE__{} = theme, name, language \\ nil) do
    name = String.downcase(name)

    id =
      theme.file_names[name] ||
        Enum.find_value(extensions(name), &theme.file_extensions[&1]) ||
        (language && theme.language_ids[language]) ||
        theme.file

    theme.icons[id]
  end

  @doc "Whether `file_icon/3` needs the language: no name or extension matches."
  def needs_language?(%__MODULE__{language_ids: ids} = theme, name) when map_size(ids) > 0 do
    name = String.downcase(name)

    not Map.has_key?(theme.file_names, name) and
      not Enum.any?(extensions(name), &Map.has_key?(theme.file_extensions, &1))
  end

  def needs_language?(_theme, _name), do: false

  # "a.test.ts" → ["test.ts", "ts"]
  defp extensions(name) do
    case String.split(name, ".") do
      [_] -> []
      [_ | parts] -> for i <- 0..(length(parts) - 1), do: parts |> Enum.drop(i) |> Enum.join(".")
    end
  end

  @doc """
  The icon (URL) of a folder named `name`, or `nil`. Options: `expanded:`
  (open in the tree), `root:` (the workspace folder).
  """
  @spec folder_icon(t(), String.t(), keyword()) :: String.t() | nil
  def folder_icon(%__MODULE__{} = theme, name, opts \\ []) do
    name = String.downcase(name)
    expanded? = Keyword.get(opts, :expanded, false)

    id =
      if Keyword.get(opts, :root, false),
        do: root_folder(theme, name, expanded?) || folder(theme, name, expanded?),
        else: folder(theme, name, expanded?)

    theme.icons[id]
  end

  defp root_folder(theme, name, true),
    do:
      theme.root_folder_names_expanded[name] || theme.root_folder_names[name] ||
        theme.root_folder_expanded || theme.root_folder

  defp root_folder(theme, name, false), do: theme.root_folder_names[name] || theme.root_folder

  defp folder(theme, name, true),
    do:
      theme.folder_names_expanded[name] || theme.folder_names[name] || theme.folder_expanded ||
        theme.folder

  defp folder(theme, name, false), do: theme.folder_names[name] || theme.folder
end

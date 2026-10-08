defmodule Bee.ColorThemes do
  @moduledoc """
  Color themes: a `Bee.Contributions.Point` for the `themes` section of
  manifests, VS Code style.

      "themes": [
        {"id": "my-theme", "label": "My Theme", "uiTheme": "vs-dark", "path": "./themes/my.json"}
      ]

  `path` (inside the plugin's folder) is a theme in VS Code's format, see
  `Bee.ColorThemes.Theme`; `uiTheme` says whether it is dark (`vs-dark`,
  `hc-black`) or light (`vs`, `hc-light`). A theme without a `path` is
  Bee's own dark or light theme under that name – Bee contributes "dark"
  and "light" (`priv/contributions/bee.json`).

  The `workbench.colorTheme` setting picks one by id, which is the label
  when the contribution has no `id` (like VS Code's). Themes are read when
  first used and cached until their files change.
  """
  @behaviour Bee.Contributions.Point

  require Logger

  alias Bee.ColorThemes.Theme
  alias Bee.Contributions

  @default "dark"
  @max_includes 10

  @type entry :: %{
          id: String.t(),
          label: String.t(),
          base: :dark | :light,
          path: String.t() | nil,
          dir: String.t() | nil,
          plugin: String.t() | nil
        }

  @doc "Every contributed color theme, Bee's first."
  @spec themes() :: [entry]
  def themes, do: Enum.flat_map(Contributions.entries(:color_themes), &elem(&1, 1))

  def theme(id), do: Enum.find(themes(), &(&1.id == id))

  @doc """
  The theme `id`, ready to use. An unknown id, or a theme whose file can't
  be read, gives Bee's dark theme (the latter logged).
  """
  @spec get(String.t() | nil) :: Theme.t()
  def get(id) do
    case theme(id) || theme(@default) do
      %{path: nil} = entry ->
        Theme.plain(entry)

      entry ->
        case read(entry) do
          {:ok, file} ->
            Theme.new(entry, file)

          {:error, message} ->
            Logger.warning("color theme #{inspect(id)}: #{message}")
            Theme.plain(entry)
        end
    end
  end

  ## Reading

  # Cached per file, until it or one it includes changes.
  defp read(%{path: path} = entry) do
    key = {__MODULE__, path}

    with {stamps, file} <- :persistent_term.get(key, nil),
         true <- Enum.all?(stamps, fn {f, mtime} -> mtime(f) == mtime end) do
      {:ok, file}
    else
      _ ->
        with {:ok, file} <- read_file(path, entry.dir, @max_includes) do
          :persistent_term.put(key, {Enum.map(file.files, &{&1, mtime(&1)}), file})
          {:ok, file}
        end
    end
  end

  defp mtime(file) do
    case File.stat(file, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end

  # %{colors, token_colors, files}: the file's, over those it includes.
  defp read_file(path, _dir, 0), do: {:error, "#{path}: too many nested includes"}

  defp read_file(path, dir, depth) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = json} <- Bee.JSON.JSONC.decode(text),
         {:ok, base} <- include(json["include"], path, dir, depth) do
      {:ok,
       %{
         colors: Map.merge(base.colors, Theme.colors(json["colors"])),
         token_colors: base.token_colors ++ token_colors(json["tokenColors"]),
         files: [path | base.files]
       }}
    else
      {:ok, _} -> {:error, "#{path}: must contain a JSON object"}
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, message}
    end
  end

  defp include(nil, _path, _dir, _depth), do: {:ok, %{colors: %{}, token_colors: [], files: []}}

  defp include(rel, path, dir, depth) when is_binary(rel) do
    file = Path.expand(rel, Path.dirname(path))

    if inside?(file, dir),
      do: read_file(file, dir, depth - 1),
      else: {:error, "#{path}: include #{inspect(rel)} must be inside the plugin"}
  end

  defp include(_rel, path, _dir, _depth), do: {:error, "#{path}: include must be a path"}

  # A list of rules; a .tmTheme file instead isn't supported (yet).
  defp token_colors(rules) when is_list(rules), do: Enum.filter(rules, &is_map/1)
  defp token_colors(_rules), do: []

  defp inside?(path, dir), do: String.starts_with?(path, Path.expand(dir) <> "/")

  ## Contribution point

  @impl Contributions.Point
  def key, do: :color_themes

  @impl Contributions.Point
  def normalize!(manifest, source, opts) do
    case get_in(manifest, ["contributes", "themes"]) do
      list when list in [nil, []] -> nil
      list -> Enum.map(list, &entry(&1, source, opts[:dir]))
    end
  end

  defp entry(t, source, dir) do
    id = t["id"] || t["label"]
    plugin = with {:plugin, name} <- source, do: name

    path =
      case {t["path"], dir} do
        {nil, _dir} ->
          nil

        {rel, dir} when is_binary(dir) ->
          path = Path.expand(rel, dir)

          unless inside?(path, dir),
            do: raise(ArgumentError, "color theme #{inspect(id)}: path must be inside the plugin")

          path

        {_rel, nil} ->
          raise ArgumentError, "color theme #{inspect(id)}: a path needs a plugin folder"
      end

    %{
      id: id,
      label: t["label"],
      base: Theme.base(t["uiTheme"]),
      path: path,
      dir: dir && Path.expand(dir),
      plugin: if(is_binary(plugin), do: plugin)
    }
  end

  @impl Contributions.Point
  def conflicts(themes, others) do
    taken = MapSet.new(others, & &1.id)
    for t <- themes, t.id in taken, do: "color theme #{inspect(t.id)} is already defined"
  end
end

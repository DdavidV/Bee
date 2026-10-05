defmodule Bee.IconThemes do
  @moduledoc """
  File icon themes: a `Bee.Contributions.Point` for the `iconThemes`
  section of plugin manifests, VS Code style.

      "iconThemes": [
        {"id": "my-icons", "label": "My Icons", "path": "./icons/theme.json"}
      ]

  `path` (inside the plugin's folder) is a theme in VS Code's format, see
  `Bee.IconThemes.Theme`. The `workbench.iconTheme` setting picks one by
  id; without one Bee uses its own icons.

  Themes are read when first used and cached until their file changes. The
  icons are served from the plugin's folder (`/plugins/<name>/<path>`, see
  `icon_file?/2`).
  """
  @behaviour Bee.Contributions.Point

  alias Bee.Contributions
  alias Bee.IconThemes.Theme

  @type theme :: %{
          id: String.t(),
          label: String.t(),
          path: String.t(),
          dir: String.t(),
          plugin: String.t()
        }

  @doc "Every contributed icon theme, in registration order."
  @spec themes() :: [theme]
  def themes, do: Enum.flat_map(Contributions.entries(:icon_themes), &elem(&1, 1))

  def theme(id), do: Enum.find(themes(), &(&1.id == id))

  @doc """
  The parsed theme `id` for a `:dark` or `:light` color theme:
  `{:ok, %Theme{}}`, or `{:error, message}` (unknown id, unreadable file).
  """
  @spec load(String.t(), :dark | :light) :: {:ok, Theme.t()} | {:error, String.t()}
  def load(id, variant) when variant in [:dark, :light] do
    case theme(id) do
      nil ->
        {:error, "no icon theme #{inspect(id)}"}

      theme ->
        with {:ok, parsed} <- read(theme), do: {:ok, Map.fetch!(parsed, variant)}
    end
  end

  @doc "Whether `path` (absolute) is an icon of one of plugin `name`'s themes."
  def icon_file?(name, path) do
    Enum.any?(themes(), fn theme ->
      theme.plugin == name and
        case read(theme) do
          {:ok, %{files: files}} -> MapSet.member?(files, path)
          {:error, _} -> false
        end
    end)
  end

  # Cached per file and modification time.
  defp read(%{path: path} = theme) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      key = {__MODULE__, path}

      case :persistent_term.get(key, nil) do
        {^mtime, parsed} ->
          {:ok, parsed}

        _ ->
          with {:ok, parsed} <- parse(theme, mtime) do
            :persistent_term.put(key, {mtime, parsed})
            {:ok, parsed}
          end
      end
    else
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp parse(theme, mtime) do
    with {:ok, text} <- File.read(theme.path),
         {:ok, %{} = json} <- Bee.JSON.JSONC.decode(text) do
      base = Path.dirname(theme.path)

      # iconPath → {file, url}, for the existing files inside the plugin.
      resolved =
        for {_id, %{"iconPath" => icon_path}} when is_binary(icon_path) <-
              Map.get(json, "iconDefinitions", %{}),
            file = Path.expand(icon_path, base),
            inside?(file, theme.dir) and File.regular?(file),
            into: %{} do
          rel = Path.relative_to(file, theme.dir)

          {icon_path,
           {file, "/plugins/#{URI.encode(theme.plugin)}/#{URI.encode(rel)}?v=#{mtime}"}}
        end

      parsed = Theme.parse(json, &(resolved |> Map.get(&1, {nil, nil}) |> elem(1)))
      files = resolved |> Map.values() |> MapSet.new(&elem(&1, 0))
      {:ok, Map.put(parsed, :files, files)}
    else
      {:ok, _} ->
        {:error, "#{theme.path}: must contain a JSON object"}

      {:error, reason} when is_atom(reason) ->
        {:error, "#{theme.path}: #{:file.format_error(reason)}"}

      {:error, message} ->
        {:error, "#{theme.path}: #{message}"}
    end
  end

  defp inside?(path, dir), do: String.starts_with?(path, Path.expand(dir) <> "/")

  ## Contribution point

  @impl Bee.Contributions.Point
  def key, do: :icon_themes

  @impl Bee.Contributions.Point
  def normalize!(manifest, source, opts) do
    case get_in(manifest, ["contributes", "iconThemes"]) do
      list when list in [nil, []] ->
        nil

      list ->
        {plugin, dir} =
          case {source, opts[:dir]} do
            {{:plugin, name}, dir} when is_binary(dir) -> {name, Path.expand(dir)}
            _ -> raise ArgumentError, "iconThemes can only come from a plugin"
          end

        for t <- list do
          path = Path.expand(t["path"], dir)

          unless inside?(path, dir),
            do:
              raise(
                ArgumentError,
                "icon theme #{inspect(t["id"])}: path must be inside the plugin"
              )

          %{id: t["id"], label: t["label"], path: path, dir: dir, plugin: plugin}
        end
    end
  end

  @impl Bee.Contributions.Point
  def conflicts(themes, others) do
    taken = MapSet.new(others, & &1.id)
    for t <- themes, t.id in taken, do: "icon theme #{inspect(t.id)} is already defined"
  end
end

defmodule Bee.Plugins.Vsix do
  @moduledoc """
  Installs a VS Code extension package (`.vsix`, a zip as downloaded from
  the Marketplace or Open VSX) as a Bee plugin in the user's plugins
  folder – for the parts Bee understands, which for now are themes: file
  icon themes (`contributes.iconThemes`, see `Bee.IconThemes`) and color
  themes (`contributes.themes`, see `Bee.ColorThemes`).

  The extension's files (the zip's `extension/` folder) are unpacked into
  `<plugins>/<name>`, `name` being the extension's, and a `plugin.json` is
  written for them. A `.vsix.json` marker records where it came from:
  installing again replaces a plugin installed this way (an update), never
  a folder of another kind.
  """

  alias Bee.Plugins

  @marker ".vsix.json"
  @max_size 300_000_000
  @max_entries 50_000

  @doc """
  Installs the `.vsix` at `path`. Returns `{:ok, plugin_name}` or
  `{:error, message}`.
  """
  @spec install(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def install(path) do
    with {:ok, files} <- read(path),
         {:ok, package} <- json(files, "package.json"),
         {:ok, contributes} <- themes(package, files),
         {:ok, name} <- plugin_name(package),
         :ok <- check_target(name) do
      write(name, files, manifest(name, package, files, contributes))
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

  # The contributes section of the plugin: the themes, with the fields Bee
  # knows (color themes need a label, a known uiTheme and a file). Labels
  # can be "%key%" (package.nls.json).
  defp themes(package, files) do
    contributes =
      %{
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

    if contributes == %{},
      do:
        {:error,
         "#{package["name"] || "the extension"} contributes no color or file icon themes; Bee can only install themes from VSIX files for now"},
      else: {:ok, contributes}
  end

  # A Bee plugin name (lowercase letters, digits, dashes) from the extension's.
  defp plugin_name(package) do
    name =
      (package["name"] || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")

    if name == "", do: {:error, "the extension has no name"}, else: {:ok, name}
  end

  defp check_target(name) do
    target = Path.join(Plugins.user_dir(), name)

    cond do
      match?(%{scope: :builtin}, Plugins.get(name)) ->
        {:error, "#{name} is the name of a built-in plugin"}

      File.exists?(target) and not File.exists?(Path.join(target, @marker)) ->
        {:error, "#{target} already exists and wasn't installed from a VSIX; uninstall it first"}

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
  defp write(name, files, manifest) do
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
      Jason.encode!(%{name: manifest["name"], version: manifest["version"]}, pretty: true)
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

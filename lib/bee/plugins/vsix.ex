defmodule Bee.Plugins.Vsix do
  @moduledoc """
  Installs a VS Code extension package (`.vsix`, a zip as downloaded from
  the Marketplace or Open VSX) as a Bee plugin in the user's plugins
  folder. Any extension installs; what Bee uses of it is read from its
  `package.json` when the plugin loads (`Bee.Plugins.VSCode.Manifest`).

  The extension's files (the zip's `extension/` folder) are unpacked into
  `<plugins>/<name>`, `name` being the extension's. A `.vsix.json` marker
  makes the folder a VS Code extension and records where it came from
  (`openVsx`: its Open VSX id, see `Bee.Plugins.OpenVsx`; `targetPlatform`:
  which platform's package it is): installing
  again replaces a plugin installed this way (an update), never a folder
  of another kind or another Open VSX extension of the same name.
  """

  alias Bee.Plugins
  alias Bee.Plugins.VSCode.Manifest

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

    with {:ok, files, executables} <- read(path),
         {:ok, package} <- json(files, "package.json"),
         {:ok, name} <- Manifest.plugin_name(package),
         :ok <- check_target(name, source) do
      marker = Map.merge(%{name: name, version: package["version"], modes: true}, origin)
      write(name, files, executables, marker)
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

  @doc """
  Makes the scripts and programs of the extension in `dir` executable
  again, once: an install by a Bee that didn't keep file modes (its marker
  has no `modes`) left them plain files, which an extension can't run (a
  language server's launch script, say). What starts like a script (`#!`)
  or a program (ELF, Mach-O) is one.
  """
  def repair_modes(dir) do
    with %{} = marker when not is_map_key(marker, "modes") and marker != %{} <- marker(dir) do
      for file <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
          File.regular?(file),
          executable_content?(file),
          do: File.chmod(file, 0o755)

      File.write(
        Path.join(dir, @marker),
        Jason.encode!(Map.put(marker, "modes", true), pretty: true)
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @magic [
    "#!",
    <<0x7F, "ELF">>,
    <<0xFE, 0xED, 0xFA, 0xCE>>,
    <<0xFE, 0xED, 0xFA, 0xCF>>,
    <<0xCE, 0xFA, 0xED, 0xFE>>,
    <<0xCF, 0xFA, 0xED, 0xFE>>,
    <<0xCA, 0xFE, 0xBA, 0xBE>>
  ]

  defp executable_content?(file) do
    case File.open(file, [:read, :binary], &IO.binread(&1, 4)) do
      {:ok, head} when is_binary(head) -> String.starts_with?(head, @magic)
      _ -> false
    end
  end

  ## Reading the package

  # The files under extension/, by their path inside it, and which of them
  # are executable (an extension's scripts and programs, e.g. a language
  # server it starts).
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

      executables =
        for {:zip_file, name, info, _, _, _} <- entries,
            {:ok, rel} <- [entry_path(to_string(name))],
            mode = elem(info, 7),
            is_integer(mode) and Bitwise.band(mode, 0o111) != 0,
            into: MapSet.new(),
            do: rel

      {:ok, files, executables}
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

  ## Writing

  # Unpacked next to the plugins folder first, then moved in whole.
  defp write(name, files, executables, marker) do
    tmp = Path.join(Bee.Settings.user_dir(), ".installing-#{name}")
    target = Path.join(Plugins.user_dir(), name)
    File.rm_rf!(tmp)

    for {rel, data} <- files do
      file = Path.join(tmp, rel)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, data)
      if rel in executables, do: File.chmod!(file, 0o755)
    end

    File.write!(
      Path.join(tmp, @marker),
      marker |> Map.reject(fn {_k, v} -> is_nil(v) end) |> Jason.encode!(pretty: true)
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

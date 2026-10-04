defmodule Bee.Workspace.FS do
  @moduledoc """
  Pure filesystem helpers. Every path coming from the browser must go
  through `resolve/2` so it cannot escape the workspace root.
  """

  @type entry :: %{name: String.t(), path: String.t(), type: :dir | :file}

  @doc """
  Resolves `rel` against `root`, refusing anything that ends up outside `root`.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, :outside_root}
  def resolve(root, rel) do
    root = Path.expand(root)
    abs = Path.expand(rel, root)

    if abs == root or String.starts_with?(abs, root <> "/") do
      {:ok, abs}
    else
      {:error, :outside_root}
    end
  end

  @doc """
  Like `resolve/2` but raises.
  """
  def resolve!(root, rel) do
    case resolve(root, rel) do
      {:ok, abs} -> abs
      {:error, reason} -> raise ArgumentError, "path #{inspect(rel)} rejected: #{reason}"
    end
  end

  @doc """
  Lists a directory relative to `root`: directories first, then files,
  both alphabetically. Entries whose path relative to `root` matches one of
  the `exclude` globs (see `Bee.Workspace.Glob`) are skipped.
  """
  @spec list_dir(String.t(), String.t(), [String.t()]) :: [entry]
  def list_dir(root, rel, exclude \\ []) do
    with {:ok, abs} <- resolve(root, rel),
         {:ok, names} <- File.ls(abs) do
      names
      |> Enum.map(fn name ->
        type = if File.dir?(Path.join(abs, name)), do: :dir, else: :file
        %{name: name, path: relative(root, Path.join(abs, name)), type: type}
      end)
      |> Enum.reject(fn entry ->
        Enum.any?(exclude, &Bee.Workspace.Glob.match?(&1, entry.path))
      end)
      |> Enum.sort_by(&{&1.type != :dir, String.downcase(&1.name)})
    else
      _ -> []
    end
  end

  @doc """
  Path of `abs` relative to `root` ("" for the root itself).
  """
  def relative(root, abs) do
    case Path.relative_to(abs, Path.expand(root)) do
      ^abs -> abs
      "." -> ""
      rel -> rel
    end
  end

  @doc """
  Writes atomically (temp file + rename), keeping the original file mode.
  """
  def atomic_write(path, contents) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.bee-#{System.unique_integer([:positive])}"
      )

    with :ok <- File.write(tmp, contents),
         :ok <- copy_mode(path, tmp),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  defp copy_mode(from, to) do
    case File.stat(from) do
      {:ok, %{mode: mode}} -> File.chmod(to, Bitwise.band(mode, 0o7777))
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end

defmodule Bee.FS do
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
  both alphabetically. Names in `exclude` are skipped.
  """
  @spec list_dir(String.t(), String.t(), [String.t()]) :: [entry]
  def list_dir(root, rel, exclude \\ []) do
    with {:ok, abs} <- resolve(root, rel),
         {:ok, names} <- File.ls(abs) do
      names
      |> Enum.reject(&(&1 in exclude))
      |> Enum.map(fn name ->
        type = if File.dir?(Path.join(abs, name)), do: :dir, else: :file
        %{name: name, path: relative(root, Path.join(abs, name)), type: type}
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
end

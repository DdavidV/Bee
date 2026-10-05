defmodule Bee.Workspace.Files do
  @moduledoc """
  File operations of the Explorer: create, rename, delete, copy and move
  files and folders, VS Code style. Paths are absolute and must lie inside
  `root` (the workspace); a new name may contain slashes (`"a/b.txt"`
  creates folder `a` too), but not leave the workspace.

  Every function returns `{:ok, ...}` or `{:error, message}` with a message
  for the user.
  """

  alias Bee.Workspace.FS

  @doc "Creates an empty file `name` in folder `dir` (and missing folders on the way)."
  def create_file(root, dir, name), do: create(root, dir, name, :file)

  @doc "Creates folder `name` (and missing ones on the way) in folder `dir`."
  def create_folder(root, dir, name), do: create(root, dir, name, :folder)

  defp create(root, dir, name, kind) do
    with {:ok, dir} <- inside(root, dir),
         {:ok, path} <- target(root, dir, name),
         :ok <- free(root, path) do
      result =
        case kind do
          :folder ->
            File.mkdir_p(path)

          :file ->
            with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, "", [:exclusive])
        end

      case result do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, "Can't create #{show(root, path)}: #{format(reason)}"}
      end
    end
  end

  @doc "Renames `path` to `name` (in the same folder, unless `name` has slashes)."
  def rename(root, path, name) do
    with {:ok, path} <- existing(root, path),
         {:ok, to} <- target(root, Path.dirname(path), name) do
      cond do
        to == path ->
          {:ok, path}

        # Only the case differs: allowed on case-insensitive file systems too.
        String.downcase(to) == String.downcase(path) ->
          move_file(root, path, to)

        true ->
          with :ok <- free(root, to),
               :ok <- not_into_itself(root, path, to),
               do: move_file(root, path, to)
      end
    end
  end

  @doc "Deletes a file, or a folder with everything in it."
  def delete(root, path) do
    with {:ok, path} <- existing(root, path) do
      cond do
        path == Path.expand(root) ->
          {:error, "The workspace folder itself can't be deleted"}

        true ->
          case File.rm_rf(path) do
            {:ok, _} ->
              {:ok, path}

            {:error, reason, _file} ->
              {:error, "Can't delete #{show(root, path)}: #{format(reason)}"}
          end
      end
    end
  end

  @doc """
  Copies (`:copy`) or moves (`:cut`) `paths` into folder `dir`. A copy
  that would take an existing name gets `"name copy.ext"`,
  `"name copy 2.ext"`, …; a move onto an existing name is refused.
  Returns `{:ok, [{from, to}]}`.
  """
  def paste(root, paths, dir, op) when op in [:copy, :cut] do
    with {:ok, dir} <- inside(root, dir) do
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, done} ->
        case paste_one(root, path, dir, op) do
          {:ok, pair} -> {:cont, {:ok, done ++ [pair]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
    end
  end

  defp paste_one(root, path, dir, :cut) do
    with {:ok, path} <- existing(root, path) do
      to = Path.join(dir, Path.basename(path))

      cond do
        to == path ->
          {:ok, {path, path}}

        true ->
          with :ok <- free(root, to),
               :ok <- not_into_itself(root, path, to),
               do: move(root, path, to)
      end
    end
  end

  defp paste_one(root, path, dir, :copy) do
    with {:ok, path} <- existing(root, path),
         :ok <- not_into_itself(root, path, Path.join(dir, Path.basename(path))) do
      to = copy_name(dir, Path.basename(path), File.dir?(path))

      case File.cp_r(path, to) do
        {:ok, _} -> {:ok, {path, to}}
        {:error, reason, _file} -> {:error, "Can't copy #{show(root, path)}: #{format(reason)}"}
      end
    end
  end

  # "a.txt" → "a copy.txt", "a copy 2.txt", … (folders keep dots: "v1.2 copy").
  defp copy_name(dir, name, folder?) do
    {stem, ext} =
      case {folder?, Path.extname(name)} do
        {false, ext} when ext != "" and ext != name -> {Path.rootname(name), ext}
        _ -> {name, ""}
      end

    candidate = Path.join(dir, name)

    if File.exists?(candidate) do
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&Path.join(dir, "#{stem} copy#{if &1 > 1, do: " #{&1}"}#{ext}"))
      |> Enum.find(&(not File.exists?(&1)))
    else
      candidate
    end
  end

  defp move(root, from, to) do
    with {:ok, to} <- move_file(root, from, to), do: {:ok, {from, to}}
  end

  defp move_file(root, from, to) do
    with :ok <- File.mkdir_p(Path.dirname(to)),
         :ok <- File.rename(from, to) do
      {:ok, to}
    else
      {:error, reason} -> {:error, "Can't move #{show(root, from)}: #{format(reason)}"}
    end
  end

  ## Checks

  defp inside(root, path) do
    case FS.resolve(root, path) do
      {:ok, abs} -> {:ok, abs}
      {:error, :outside_root} -> {:error, "#{path} is outside the workspace"}
    end
  end

  defp existing(root, path) do
    with {:ok, abs} <- inside(root, path) do
      if File.exists?(abs) or match?({:ok, _}, File.lstat(abs)),
        do: {:ok, abs},
        else: {:error, "#{show(root, abs)} doesn't exist"}
    end
  end

  # Where `name` points to from `dir`: a non-empty relative name, inside the workspace.
  defp target(root, dir, name) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, "A file or folder name must be provided"}

      Path.type(name) != :relative or String.contains?(name, "\\") ->
        {:error, "#{name} is not a valid name"}

      Enum.any?(Path.split(name), &(&1 in [".", ".."])) ->
        {:error, "#{name} is not a valid name"}

      true ->
        inside(root, Path.join(dir, name))
    end
  end

  defp free(root, path) do
    if File.exists?(path) or match?({:ok, _}, File.lstat(path)),
      do: {:error, "A file or folder #{show(root, path)} already exists"},
      else: :ok
  end

  defp not_into_itself(root, from, to) do
    if String.starts_with?(to, from <> "/"),
      do: {:error, "Can't move or copy #{show(root, from)} into itself"},
      else: :ok
  end

  defp show(root, path), do: FS.relative(root, path)

  defp format(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp format(reason), do: inspect(reason)
end

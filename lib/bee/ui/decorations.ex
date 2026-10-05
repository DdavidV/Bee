defmodule Bee.UI.Decorations do
  @moduledoc """
  File decorations, VS Code style: a colour and a short badge (`"M"`, `"U"`)
  for a file, e.g. its git status. Plugins set theirs with
  `Bee.API.set_file_decorations/2`; the Explorer and the editor tabs show
  them.

  Folders take the colour (not the badge) of what they contain, so changes
  are easy to find in a collapsed tree. When a folder contains several
  kinds, the most important colour wins: conflict, then modified, then
  deleted, then added / untracked. Ignored files don't colour folders.
  """

  @colors ~w(modified added deleted untracked conflict ignored)
  @rank %{"conflict" => 5, "modified" => 4, "deleted" => 3, "added" => 2, "untracked" => 2}

  @type decoration :: %{
          badge: String.t() | nil,
          color: String.t() | nil,
          tooltip: String.t() | nil
        }

  def colors, do: @colors

  @doc "Normalizes `%{path => %{badge, color, tooltip}}` (atom or string keys)."
  def normalize!(decorations) when is_map(decorations) do
    Map.new(decorations, fn {path, d} ->
      unless is_map(d), do: raise(ArgumentError, "a decoration must be a map, got: #{inspect(d)}")
      get = fn key -> Map.get(d, key, Map.get(d, Atom.to_string(key))) end
      color = to_string(get.(:color) || "")

      {to_string(path),
       %{
         badge: get.(:badge) && get.(:badge) |> to_string() |> String.slice(0, 2),
         color: if(color in @colors, do: color),
         tooltip: get.(:tooltip) && to_string(get.(:tooltip))
       }}
    end)
  end

  def normalize!(other),
    do: raise(ArgumentError, "decorations must be a map, got: #{inspect(other)}")

  @doc """
  Decorations by workspace-relative path, for `root`: the files' own, plus
  their folders' (colour only). Paths outside `root` are dropped.
  """
  @spec for_workspace(%{String.t() => decoration}, String.t()) :: %{String.t() => decoration}
  def for_workspace(decorations, root) do
    files =
      for {path, d} <- decorations,
          rel = relative(path, root),
          rel != nil,
          into: %{},
          do: {rel, d}

    folders =
      Enum.reduce(files, %{}, fn {rel, d}, acc ->
        if rank(d.color) > 0 do
          rel
          |> Path.dirname()
          |> ancestors()
          |> Enum.reduce(acc, fn dir, acc ->
            Map.update(
              acc,
              dir,
              folder(d.color),
              &if(rank(d.color) > rank(&1.color), do: folder(d.color), else: &1)
            )
          end)
        else
          acc
        end
      end)

    Map.merge(folders, files)
  end

  defp folder(color), do: %{badge: nil, color: color, tooltip: nil}

  defp rank(color), do: Map.get(@rank, color, 0)

  # "a/b/c" → ["a/b/c", "a/b", "a"]
  defp ancestors("."), do: []
  defp ancestors(dir), do: [dir | ancestors(Path.dirname(dir))]

  defp relative(path, root) do
    cond do
      Path.type(path) != :absolute -> path
      String.starts_with?(path, root <> "/") -> Path.relative_to(path, root)
      true -> nil
    end
  end
end

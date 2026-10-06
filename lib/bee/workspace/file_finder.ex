defmodule Bee.Workspace.FileFinder do
  @moduledoc """
  Finds a workspace's files by name for one window's Quick Open, off the
  window's process: typing never waits for it.

  Started when Quick Open opens (`start/3`), it lists the workspace's files
  in the background – `git ls-files` in a git repository (what `.gitignore`
  leaves out is left out), else a walk of the folder – minus `files.exclude`
  and `search.exclude`, at most `max`. They come in chunks, each matched
  against the current query as it arrives.

  `query/2` asks for a query's matches; the owner gets
  `{:file_finder, pid, query, paths, loading?}` (paths workspace-relative,
  best first). Queries sent faster than they are answered are skipped to the
  latest; one that extends the previous one only searches its matches
  (`Bee.Workbench.QuickOpen.narrow/2`). The finder stops with its owner, or
  when told (`stop/1`).
  """
  use GenServer

  alias Bee.Workbench.QuickOpen
  alias Bee.Workspace.{FS, Glob}

  @chunk 2_000

  def start(root, owner \\ self(), max \\ 50_000),
    do: GenServer.start(__MODULE__, {root, owner, max})

  def query(finder, query), do: GenServer.cast(finder, {:query, query})

  def stop(finder), do: GenServer.cast(finder, :stop)

  ## Server

  @impl true
  def init({root, owner, max}) do
    Process.monitor(owner)
    me = self()
    # Linked: it goes when we do.
    spawn_link(fn -> list(root, max, &send(me, {:chunk, &1})) && send(me, :listed) end)

    {:ok, %{owner: owner, entries: [], loading?: true, query: nil, normalized: nil, matches: []}}
  end

  @impl true
  def handle_cast({:query, query}, s), do: {:noreply, s |> search(latest(query)) |> reply()}
  def handle_cast(:stop, s), do: {:stop, :normal, s}

  @impl true
  def handle_info({:chunk, paths}, s) do
    entries = Enum.map(paths, &QuickOpen.entry/1)
    s = %{s | entries: entries ++ s.entries}

    if s.normalized,
      do: {:noreply, reply(%{s | matches: QuickOpen.match(entries, s.normalized) ++ s.matches})},
      else: {:noreply, s}
  end

  def handle_info(:listed, s), do: {:noreply, reply(%{s | loading?: false})}
  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = s), do: {:stop, :normal, s}

  # Typed faster than answered: only the last query counts.
  defp latest(query) do
    receive do
      {:"$gen_cast", {:query, newer}} -> latest(newer)
    after
      0 -> query
    end
  end

  defp search(s, query) do
    q = QuickOpen.normalize(query)

    matches =
      if s.normalized && s.normalized != "" && String.starts_with?(q, s.normalized),
        do: QuickOpen.narrow(s.matches, q),
        else: QuickOpen.match(s.entries, q)

    %{s | query: query, normalized: q, matches: matches}
  end

  defp reply(%{query: nil} = s), do: s

  defp reply(s) do
    send(s.owner, {:file_finder, self(), s.query, QuickOpen.top(s.matches), s.loading?})
    s
  end

  ## Listing

  @doc """
  Lists `root`'s files (relative paths), at most `max`, calling `emit` with
  each chunk. `git ls-files` in a repository, else a walk.
  """
  def list(root, max, emit) do
    exclude = Bee.Settings.excluded_globs(root) ++ search_excludes(root)

    case git_files(root) do
      {:ok, files} ->
        files
        |> Stream.reject(&excluded?(&1, exclude))
        |> Stream.filter(&File.regular?(Path.join(root, &1)))
        |> Stream.take(max)
        |> Stream.chunk_every(@chunk)
        |> Enum.each(emit)

      :error ->
        walk(root, exclude, {[], 0, max, emit}) |> flush()
    end

    true
  end

  # Tracked and new files, without ignored ones; deleted ones are filtered
  # by the caller.
  defp git_files(root) do
    with git when git != nil <- System.find_executable("git"),
         {out, 0} <-
           System.cmd(git, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
             cd: root,
             stderr_to_stdout: true
           ) do
      {:ok, out |> String.split(<<0>>, trim: true) |> Enum.uniq()}
    else
      _ -> :error
    end
  end

  # A path is excluded when it, or a folder it is in, matches.
  defp excluded?(path, exclude) do
    exclude != [] and
      Enum.any?(ancestors(path), fn p -> Enum.any?(exclude, &Glob.match?(&1, p)) end)
  end

  defp ancestors(path) do
    case Path.dirname(path) do
      "." -> [path]
      dir -> [path | ancestors(dir)]
    end
  end

  defp search_excludes(root) do
    case Bee.Settings.get("search.exclude", root) do
      %{} = map -> for {pattern, true} <- map, do: Glob.compile(pattern)
      _ -> []
    end
  end

  # Level by level (breadth first): when `max` cuts the list short, what is
  # left out is the deepest files, not the top folder's. state: {batch, its
  # size, files left to list, emit}
  defp walk(root, exclude, state), do: walk(root, exclude, :queue.from_list([""]), state)

  defp walk(_root, _exclude, _dirs, {_batch, _size, 0, _emit} = state), do: state

  defp walk(root, exclude, dirs, state) do
    case :queue.out(dirs) do
      {:empty, _} ->
        state

      {{:value, rel}, dirs} ->
        {dirs, state} =
          root
          |> FS.list_dir(rel, exclude)
          |> Enum.reduce({dirs, state}, fn
            _entry, {_dirs, {_batch, _size, 0, _emit}} = acc ->
              acc

            %{type: :dir, path: path}, {dirs, state} ->
              case File.lstat(Path.join(root, path)) do
                {:ok, %{type: :directory}} -> {:queue.in(path, dirs), state}
                _ -> {dirs, state}
              end

            %{type: :file, path: path}, {dirs, {batch, size, left, emit}} ->
              state = {[path | batch], size + 1, left - 1, emit}
              {dirs, if(size + 1 >= @chunk, do: flush(state), else: state)}
          end)

        walk(root, exclude, dirs, state)
    end
  end

  defp flush({[], _size, left, emit}), do: {[], 0, left, emit}

  defp flush({batch, _size, left, emit}) do
    emit.(Enum.reverse(batch))
    {[], 0, left, emit}
  end
end

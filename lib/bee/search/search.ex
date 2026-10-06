defmodule Bee.Search do
  @moduledoc """
  Text search and replace across the workspace, VS Code style.

  `start/2` runs a search in its own process (under `Bee.Search.TaskSup`):
  files are read and matched in parallel (`Task.async_stream`) and results
  are sent to the caller in batches:

    * `{:search_results, ref, [file_result]}`
    * `{:search_done, ref, %{files, matches, limit_hit, ms}}`

  A file result is `%{path, matches: [match]}`, `path` relative to the
  workspace; a match is `%{from, to, line, before, match, after}` – byte
  offsets into the file's text, the 1-based line where it starts, and the
  text around it for a preview.

  Searched are the workspace's files (`files.exclude` honoured), minus
  `search.exclude`, filtered by the include / exclude globs of the query.
  Open files are searched with their unsaved text. Files over 2 MB and
  binary (non UTF-8) files are skipped.

  Options (`opts`): `:root` (the workspace searched; default
  `Bee.Workspace.root/0`), `:query`, `:regex`, `:case_sensitive`,
  `:whole_word`, `:include`, `:exclude` (comma-separated globs),
  `:max_results`.
  """

  alias Bee.Editor.Buffer
  alias Bee.Workspace.{FS, Glob}

  @max_size 2_000_000
  @flush_ms 100
  # Preview: characters kept before a match (the sidebar is narrow) and after it.
  @preview_before 20
  @preview 60

  @type handle :: %{ref: reference(), pid: pid()}

  @doc """
  Starts searching; results go to `reply_to`. Returns `{:ok, handle}` (stop
  it with `cancel/1`) or `{:error, message}` for an invalid regex.
  """
  @spec start(map(), pid()) :: {:ok, handle} | {:error, String.t()}
  def start(opts, reply_to \\ self()) do
    with {:ok, regex} <- compile(opts) do
      ref = make_ref()

      {:ok, pid} =
        Task.Supervisor.start_child(Bee.Search.TaskSup, fn -> run(regex, opts, ref, reply_to) end)

      {:ok, %{ref: ref, pid: pid}}
    end
  end

  def cancel(%{pid: pid}), do: Process.exit(pid, :kill)
  def cancel(nil), do: :ok

  @doc "The regex for `opts` (unicode, multiline: `^`/`$` match at line ends)."
  def compile(opts) do
    query = Map.get(opts, :query, "")
    source = if opts[:regex], do: query, else: Regex.escape(query)
    source = if opts[:whole_word], do: "\\b(?:#{source})\\b", else: source
    flags = if opts[:case_sensitive], do: "um", else: "umi"

    cond do
      query == "" ->
        {:error, "empty query"}

      true ->
        case Regex.compile(source, flags) do
          {:ok, regex} -> {:ok, regex}
          {:error, {reason, at}} -> {:error, "Invalid regular expression: #{reason} (at #{at})"}
        end
    end
  end

  ## Searching

  defp run(regex, opts, ref, reply_to) do
    started = System.monotonic_time(:millisecond)
    root = Map.get(opts, :root) || Bee.Workspace.root()
    max = Map.get(opts, :max_results) || Bee.Settings.get("search.maxResults", root) || 20_000

    acc = %{batch: [], flushed_at: started, files: 0, matches: 0, limit_hit: false}

    acc =
      root
      |> files(opts)
      |> Task.async_stream(&search_file(root, &1, regex),
        ordered: false,
        timeout: :infinity,
        max_concurrency: System.schedulers_online() * 2
      )
      |> Enum.reduce_while(acc, fn
        {:ok, nil}, acc ->
          {:cont, acc}

        {:ok, result}, acc ->
          {result, limit_hit} = truncate(result, max - acc.matches)

          acc = %{
            acc
            | batch: [result | acc.batch],
              files: acc.files + 1,
              matches: acc.matches + length(result.matches)
          }

          acc = maybe_flush(acc, ref, reply_to)
          if limit_hit, do: {:halt, %{acc | limit_hit: true}}, else: {:cont, acc}
      end)

    flush(acc, ref, reply_to)

    send(reply_to, {
      :search_done,
      ref,
      %{
        files: acc.files,
        matches: acc.matches,
        limit_hit: acc.limit_hit,
        ms: System.monotonic_time(:millisecond) - started
      }
    })
  end

  defp truncate(result, room) when length(result.matches) <= room, do: {result, false}
  defp truncate(result, room), do: {%{result | matches: Enum.take(result.matches, room)}, true}

  defp maybe_flush(acc, ref, reply_to) do
    now = System.monotonic_time(:millisecond)

    if now - acc.flushed_at >= @flush_ms,
      do: %{flush(acc, ref, reply_to) | flushed_at: now},
      else: acc
  end

  defp flush(%{batch: []} = acc, _ref, _reply_to), do: acc

  defp flush(acc, ref, reply_to) do
    send(reply_to, {:search_results, ref, Enum.reverse(acc.batch)})
    %{acc | batch: []}
  end

  @doc false
  # The files a search looks at, workspace-relative.
  def files(root, opts) do
    include = globs(opts[:include])
    exclude = globs(opts[:exclude]) ++ setting_globs("search.exclude", root)

    FS.walk(root, "", Bee.Settings.excluded_globs(root))
    |> Enum.filter(fn path ->
      (include == [] or Enum.any?(include, &Glob.match?(&1, path))) and
        not Enum.any?(exclude, &Glob.match?(&1, path))
    end)
  end

  # "src, *.ex" → globs; like VS Code, a pattern without a slash matches at
  # any depth, and a folder matches everything inside it.
  defp globs(nil), do: []

  defp globs(patterns) do
    for pattern <- String.split(patterns, ",", trim: true),
        pattern =
          pattern |> String.trim() |> String.trim_leading("./") |> String.trim_trailing("/"),
        pattern != "",
        expanded <- glob_variants(pattern),
        do: Glob.compile(expanded)
  end

  defp glob_variants("/" <> pattern), do: [pattern, pattern <> "/**"]
  defp glob_variants("**/" <> _ = pattern), do: [pattern, pattern <> "/**"]
  defp glob_variants(pattern), do: ["**/" <> pattern, "**/" <> pattern <> "/**"]

  defp setting_globs(key, root) do
    case Bee.Settings.get(key, root) do
      %{} = map -> for {pattern, true} <- map, do: Glob.compile(pattern)
      _ -> []
    end
  end

  defp search_file(root, rel, regex) do
    abs = Path.join(root, rel)

    with {:ok, text} <- read(abs),
         [_ | _] = matches <- matches(text, regex) do
      %{path: rel, matches: matches}
    else
      _ -> nil
    end
  end

  # The open buffer's text (unsaved changes), else the file's.
  defp read(abs) do
    case Registry.lookup(Bee.Registry, {:buffer, abs}) do
      [{_pid, _}] ->
        {:ok, Buffer.get(abs).text}

      [] ->
        with {:ok, %{size: size}} when size <= @max_size <- File.stat(abs),
             {:ok, text} <- File.read(abs),
             true <- String.valid?(text) do
          {:ok, text}
        else
          _ -> :skip
        end
    end
  catch
    :exit, _ -> :skip
  end

  @doc """
  Matches of `regex` in `text` (see the moduledoc for their shape).
  Empty matches are skipped.
  """
  def matches(text, regex) do
    regex
    |> Regex.scan(text, return: :index, capture: :first)
    |> Enum.flat_map(fn
      [{_start, 0}] -> []
      [{start, len}] -> [{start, start + len}]
    end)
    |> with_lines(text)
  end

  # Line numbers and previews, in one pass over the text.
  defp with_lines(ranges, text) do
    {matches, _} =
      Enum.map_reduce(ranges, {0, 1, 0}, fn {from, to}, {pos, line, line_start} ->
        newlines = :binary.matches(text, "\n", scope: {pos, from - pos})
        line = line + length(newlines)
        line_start = if newlines == [], do: line_start, else: elem(List.last(newlines), 0) + 1
        line_end = line_end(text, from)
        match_end = min(to, line_end)

        match = %{
          from: from,
          to: to,
          line: line,
          before: text |> binary_part(line_start, from - line_start) |> shorten_left(),
          match: binary_part(text, from, match_end - from),
          after: text |> binary_part(match_end, line_end - match_end) |> String.slice(0, @preview)
        }

        {match, {from, line, line_start}}
      end)

    matches
  end

  defp line_end(text, pos) do
    case :binary.match(text, "\n", scope: {pos, byte_size(text) - pos}) do
      {nl, _} -> nl
      :nomatch -> byte_size(text)
    end
  end

  defp shorten_left(before) do
    trimmed = String.trim_leading(before)

    if String.length(trimmed) > @preview_before,
      do: "…" <> String.slice(trimmed, -@preview_before, @preview_before),
      else: trimmed
  end

  ## Replacing

  @doc """
  Replaces the matches of `opts` in `paths` (workspace-relative) with
  `replacement` – in regex mode `$1`… `$&` refer to groups, `$$` is a `$`.
  `only: [from]` limits it to the matches starting at those byte offsets.
  Open files are edited through their buffer (undoable, unsaved), others
  written to disk. Returns `{:ok, replaced_count}` or `{:error, message}`.
  """
  def replace(paths, opts, replacement, only \\ nil) do
    with {:ok, regex} <- compile(opts) do
      root = Map.get(opts, :root) || Bee.Workspace.root()

      count =
        paths
        |> Task.async_stream(&replace_file(Path.join(root, &1), regex, opts, replacement, only),
          timeout: 30_000
        )
        |> Enum.reduce(0, fn {:ok, n}, acc -> acc + n end)

      {:ok, count}
    end
  end

  defp replace_file(abs, regex, opts, replacement, only) do
    with {:ok, text} <- read(abs),
         [_ | _] = edits <- edits(text, regex, opts, replacement, only) do
      case Registry.lookup(Bee.Registry, {:buffer, abs}) do
        [{_pid, _}] ->
          case Buffer.edit(abs, edits) do
            {:ok, _} -> length(edits)
            _ -> 0
          end

        [] ->
          {:ok, new_text} = Buffer.apply_edits(text, edits)
          if FS.atomic_write(abs, new_text) == :ok, do: length(edits), else: 0
      end
    else
      _ -> 0
    end
  end

  @doc false
  # `[{from, to, replacement}]` for the matches in `text`.
  def edits(text, regex, opts, replacement, only \\ nil) do
    for [{start, len} | groups] <- Regex.scan(regex, text, return: :index),
        len > 0,
        only == nil or start in only do
      insert =
        if opts[:regex],
          do: expand(replacement, binary_part(text, start, len), groups, text),
          else: replacement

      {start, start + len, insert}
    end
  end

  # $1…$99 → groups, $& / $0 → the match, $$ → $.
  defp expand(replacement, whole, groups, text) do
    Regex.replace(~r/\$(\$|&|\d{1,2})/, replacement, fn
      _, "$" -> "$"
      _, "&" -> whole
      _, "0" -> whole
      _, n -> group(groups, String.to_integer(n), text)
    end)
  end

  defp group(groups, n, text) do
    case Enum.at(groups, n - 1) do
      {start, len} when start >= 0 -> binary_part(text, start, len)
      _ -> ""
    end
  end
end

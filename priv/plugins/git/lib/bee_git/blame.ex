defmodule BeeGit.Blame do
  @moduledoc """
  Parses `git blame --porcelain` into `%{lines: [hash], commits: %{hash =>
  commit}}`: `lines` has the commit of every line (index 0 = line 1), a
  commit is `%{author, mail, time, summary}`. Uncommitted lines have the
  all-zero hash.
  """

  @uncommitted String.duplicate("0", 40)

  def uncommitted, do: @uncommitted

  def parse(output) do
    {lines, commits, _current} =
      output
      |> String.split("\n")
      |> Enum.reduce({%{}, %{}, nil}, fn line, {lines, commits, current} ->
        case line do
          "\t" <> _content ->
            {hash, final} = current
            {Map.put(lines, final, hash), commits, {hash, final + 1}}

          _ ->
            case Regex.run(~r/^([0-9a-f]{40}) \d+ (\d+)/, line) do
              [_, hash, final] ->
                {lines, Map.put_new(commits, hash, %{}), {hash, String.to_integer(final)}}

              nil ->
                {lines, put_key(commits, current, line), current}
            end
        end
      end)

    count = map_size(lines)

    %{
      lines: for(n <- 1..count//1, do: Map.get(lines, n)),
      commits: Map.new(commits, fn {hash, info} -> {hash, commit(hash, info)} end)
    }
  end

  defp put_key(commits, nil, _line), do: commits

  defp put_key(commits, {hash, _}, line) do
    case String.split(line, " ", parts: 2) do
      [key, value] when key in ~w(author author-mail author-time summary) ->
        Map.update!(commits, hash, &Map.put(&1, key, value))

      _ ->
        commits
    end
  end

  defp commit(@uncommitted, _info),
    do: %{author: "You", mail: nil, time: nil, summary: "Uncommitted changes"}

  defp commit(_hash, info) do
    %{
      author: info["author"],
      mail: info["author-mail"] && String.trim(info["author-mail"], "<") |> String.trim(">"),
      time: info["author-time"] && String.to_integer(info["author-time"]),
      summary: info["summary"]
    }
  end
end

defmodule BeeGit.Log do
  @moduledoc """
  Recent commits with their files: parses
  `git log --format=#{"%x1e%H%x1f%h%x1f%an%x1f%at%x1f%s"} --name-status`.
  """

  def format, do: "%x1e%H%x1f%h%x1f%an%x1f%at%x1f%s"

  def parse(output) do
    for chunk <- String.split(output, "\x1e", trim: true),
        [header | rest] = String.split(chunk, "\n", trim: true),
        [hash, short, author, time, subject] <- [String.split(header, "\x1f")] do
      %{
        hash: hash,
        short: short,
        author: author,
        time: String.to_integer(time),
        subject: subject,
        files:
          for line <- rest, [status | paths] = String.split(line, "\t"), paths != [] do
            %{status: String.first(status), path: List.last(paths)}
          end
      }
    end
  end

  @doc "\"5 minutes ago\" for a unix time."
  def relative(nil), do: ""

  def relative(time) do
    seconds = max(System.os_time(:second) - time, 0)

    {n, unit} =
      cond do
        seconds < 60 -> {0, :now}
        seconds < 3600 -> {div(seconds, 60), "minute"}
        seconds < 86_400 -> {div(seconds, 3600), "hour"}
        seconds < 30 * 86_400 -> {div(seconds, 86_400), "day"}
        seconds < 365 * 86_400 -> {div(seconds, 30 * 86_400), "month"}
        true -> {div(seconds, 365 * 86_400), "year"}
      end

    case {n, unit} do
      {_, :now} -> "just now"
      {1, unit} -> "1 #{unit} ago"
      {n, unit} -> "#{n} #{unit}s ago"
    end
  end
end

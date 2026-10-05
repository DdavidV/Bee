defmodule BeeGit.Git do
  @moduledoc """
  Runs git. Never prompts (`GIT_TERMINAL_PROMPT=0`; push and pull need SSH
  keys or a credential helper) and doesn't take optional locks, so polling
  `status` doesn't get in the way of git running elsewhere.
  """

  @env [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_OPTIONAL_LOCKS", "0"}, {"LC_ALL", "C"}]

  @doc "Runs `git args` in `dir`. `{:ok, output}` or `{:error, message}`."
  def run(dir, args, opts \\ []) do
    git = Keyword.get(opts, :git) || setting_git()

    case System.cmd(git, args, cd: dir, env: @env, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    # git not installed / not executable
    e in ErlangError -> {:error, "cannot run git: #{inspect(e.original)}"}
  end

  # A diff exits with 1 when the files differ.
  def run_diff(dir, args) do
    case System.cmd(setting_git(), args, cd: dir, env: @env, stderr_to_stdout: true) do
      {out, code} when code in [0, 1] -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e in ErlangError -> {:error, "cannot run git: #{inspect(e.original)}"}
  end

  @doc "The repository's top directory containing `dir`, or nil."
  def toplevel(dir) do
    case run(dir, ["rev-parse", "--show-toplevel"]) do
      {:ok, out} -> String.trim(out)
      {:error, _} -> nil
    end
  end

  def has_head?(repo), do: match?({:ok, _}, run(repo, ["rev-parse", "--verify", "-q", "HEAD"]))

  @doc "Runs `fun` with a temporary file holding `text`, removed afterwards."
  def with_temp_file(text, fun) do
    path = Path.join(System.tmp_dir!(), "bee-git-#{System.unique_integer([:positive])}")
    File.write!(path, text)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp setting_git do
    case Bee.API.setting("git.path") do
      path when is_binary(path) and path != "" -> path
      _ -> "git"
    end
  end
end

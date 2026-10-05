defmodule BeeGit do
  @moduledoc """
  Bee's git plugin: VS Code's Source Control, plus GitLens-style blame.

  Server part (this module, one process):

    * keeps `git status` of the workspace's repository, refreshed when files
      change, and shows it in the Source Control container (`git.changes`:
      conflicts / staged / changes, with stage, unstage and discard buttons,
      and a commit box) and the recent commits (`git.commits`)
    * a status bar item with the branch (click: checkout) and one with the
      ahead / behind counts (click: sync)
    * sets the `git.repository` context key
    * runs push / pull / fetch in the background, so they can take as long
      as they need
    * answers the browser part: `blame` and `diff` of a file (with its
      unsaved text) and `commit` details

  The browser part (`browser.js`) draws the blame of the current line, its
  hover, the file blame gutter and the change markers.
  """
  use Bee.Plugin

  alias BeeGit.{Blame, Diff, Git, Log, Status}

  @changes "git.changes"
  @commits "git.commits"
  @log_size 50

  @impl true
  def activate(ctx) do
    state = %{ctx: ctx, repo: nil, status: nil, log: [], has_head: false, op: nil, timer: nil}
    {:ok, refresh(state)}
  end

  ## Repository

  @command "git.init"
  def init(ctx, state) do
    case Git.run(ctx.root, ["init"]) do
      {:ok, _} -> {:ok, refresh(state)}
      {:error, message} -> error(ctx, message)
    end
  end

  @command "git.refresh"
  def refresh_command(_ctx, state), do: {:ok, refresh(state)}

  ## Staging

  @command "git.stage"
  def stage(ctx, state), do: git(ctx, state, ["add", "--" | paths(ctx)])

  @command "git.stageAll"
  def stage_all(ctx, state), do: git(ctx, state, ["add", "-A"])

  @command "git.unstage"
  def unstage(ctx, state) do
    if state.has_head,
      do: git(ctx, state, ["restore", "--staged", "--" | paths(ctx)]),
      else: git(ctx, state, ["rm", "--cached", "-q", "--" | paths(ctx)])
  end

  @command "git.unstageAll"
  def unstage_all(ctx, state) do
    if state.has_head,
      do: git(ctx, state, ["reset", "-q"]),
      else: git(ctx, state, ["rm", "--cached", "-r", "-q", "."])
  end

  # Asks first: discarding can't be undone.
  @command "git.clean"
  def clean(%{args: [path | _]} = ctx, _state) do
    Bee.API.quick_pick(
      ctx,
      [%{label: "Discard Changes", description: rel(ctx, path), value: path}],
      "git.cleanConfirmed",
      placeholder: "Discard the changes in #{Path.basename(path)}? This can't be undone."
    )
  end

  @command "git.cleanConfirmed"
  def clean_confirmed(%{args: [path | _]}, state) do
    entry =
      Enum.find(state.status.entries, &(abs(state, &1.path) == path and &1.group == :change))

    if entry && entry.letter == "U",
      do: File.rm_rf(path),
      else: Git.run(state.repo, ["restore", "--worktree", "--", path])

    {:ok, refresh(state)}
  end

  @command "git.cleanAll"
  def clean_all(ctx, state) do
    changes = Enum.count(state.status.entries, &(&1.group == :change))

    Bee.API.quick_pick(
      ctx,
      [
        %{
          label: "Discard All #{changes} Changes",
          description: "untracked files are deleted",
          value: "all"
        }
      ],
      "git.cleanAllConfirmed",
      placeholder: "Discard all changes? This can't be undone."
    )
  end

  @command "git.cleanAllConfirmed"
  def clean_all_confirmed(_ctx, state) do
    if state.has_head, do: Git.run(state.repo, ["restore", "--worktree", "--", "."])
    Git.run(state.repo, ["clean", "-fdq"])
    {:ok, refresh(state)}
  end

  @command "git.openFile"
  def open_file(%{args: [path | _]} = ctx, _state), do: Bee.API.open_file(ctx, path)

  ## Committing

  # From the commit box (the text is the last argument) or the palette (asks).
  @command "git.commit"
  def commit(%{args: []} = ctx, _state),
    do: Bee.API.input_box(ctx, "git.commit", prompt: "Commit message", placeholder: "Message")

  def commit(%{args: args} = ctx, state) do
    message = args |> List.last() |> to_string() |> String.trim()
    staged? = Enum.any?(state.status.entries, &(&1.group == :staged))
    changes? = Enum.any?(state.status.entries, &(&1.group == :change))

    cond do
      message == "" ->
        error(ctx, "Please provide a commit message")

      not staged? and not changes? ->
        error(ctx, "There are no changes to commit.")

      true ->
        # Nothing staged: commit everything, like VS Code's smart commit.
        unless staged?, do: Git.run(state.repo, ["add", "-A"])

        case Git.run(state.repo, ["commit", "-q", "-m", message]) do
          {:ok, _} ->
            Bee.API.clear_view_input(ctx, @changes)
            {:ok, refresh(state)}

          {:error, output} ->
            error(ctx, output)
        end
    end
  end

  ## Branches

  @command "git.checkout"
  def checkout(ctx, state) do
    branches =
      case Git.run(state.repo, ["branch", "--format=%(refname:short)"]) do
        {:ok, out} -> String.split(out, "\n", trim: true)
        {:error, _} -> []
      end

    current = state.status && state.status.branch

    items =
      [%{label: "+ Create new branch…", description: "", value: %{create: true}}] ++
        for branch <- branches,
            do: %{
              label: branch,
              description: if(branch == current, do: "current", else: ""),
              value: branch
            }

    Bee.API.quick_pick(ctx, items, "git.checkoutTo", placeholder: "Select a branch to checkout")
  end

  @command "git.checkoutTo"
  def checkout_to(%{args: [%{"create" => true} | _]} = ctx, _state),
    do:
      Bee.API.input_box(ctx, "git.branch", prompt: "New branch name", placeholder: "Branch name")

  def checkout_to(%{args: [branch | _]} = ctx, state),
    do: git(ctx, state, ["checkout", "-q", branch])

  @command "git.branch"
  def branch(%{args: []} = ctx, _state),
    do:
      Bee.API.input_box(ctx, "git.branch", prompt: "New branch name", placeholder: "Branch name")

  def branch(%{args: args} = ctx, state) do
    case args |> List.last() |> to_string() |> String.trim() |> String.replace(~r/\s+/, "-") do
      "" -> :ok
      name -> git(ctx, state, ["checkout", "-q", "-b", name])
    end
  end

  ## Remotes (in the background: they may take a while)

  @command "git.pull"
  def pull(ctx, state), do: background(ctx, state, "Pulling", [["pull", "--ff-only"]])

  @command "git.push"
  def push(ctx, state) do
    args =
      if state.status && state.status.upstream,
        do: ["push"],
        else: ["push", "-u", "origin", (state.status && state.status.branch) || "HEAD"]

    background(ctx, state, "Pushing", [args])
  end

  @command "git.fetch"
  def fetch(ctx, state), do: background(ctx, state, "Fetching", [["fetch", "--prune"]])

  @command "git.sync"
  def sync(ctx, state), do: background(ctx, state, "Syncing", [["pull", "--ff-only"], ["push"]])

  defp background(ctx, %{op: op}, _what, _commands) when op != nil,
    do: error(ctx, "#{op}… – wait for it to finish")

  defp background(ctx, state, what, commands) do
    host = ctx.host
    repo = state.repo

    Task.start(fn ->
      result =
        Enum.reduce_while(commands, {:ok, ""}, fn args, _ ->
          case Git.run(repo, args) do
            {:ok, _} = ok -> {:cont, ok}
            error -> {:halt, error}
          end
        end)

      send(host, {:op_done, ctx, what, result})
    end)

    {:ok, publish(%{state | op: what})}
  end

  ## Browser part

  @impl true
  def handle_request("blame", %{"path" => path}, _ctx, state) do
    with repo when repo != nil <- state.repo,
         text when is_binary(text) <- Bee.API.text(path),
         {:ok, out} <-
           Git.with_temp_file(text, fn tmp ->
             Git.run(repo, ["blame", "--porcelain", "--contents", tmp, "--", path])
           end) do
      blame = Blame.parse(out)

      commits =
        Map.new(blame.commits, fn {hash, c} ->
          {hash, Map.merge(c, %{relative: Log.relative(c.time)})}
        end)

      {:reply,
       %{
         lines: blame.lines,
         commits: commits,
         inline: Bee.API.setting("git.blame.inline") != false
       }}
    else
      _ -> {:reply, nil}
    end
  end

  # Changes of the (unsaved) text against the index, as VS Code's gutter.
  def handle_request("diff", %{"path" => path}, _ctx, state) do
    with repo when repo != nil <- state.repo,
         true <- Bee.API.setting("git.decorations.gutter") != false,
         text when is_binary(text) <- Bee.API.text(path),
         {:ok, original} <- Git.run(repo, ["show", ":" <> Path.relative_to(path, repo)]),
         {:ok, out} <-
           Git.with_temp_file(original, fn a ->
             Git.with_temp_file(text, fn b ->
               Git.run_diff(repo, ["diff", "--no-index", "-U0", "--no-color", "--", a, b])
             end)
           end) do
      {:reply, Diff.parse(out)}
    else
      _ -> {:reply, nil}
    end
  end

  # Stages one change, as the peek shows it: the hunk's old lines (checked
  # against the index, in case it changed since) replaced by its new ones.
  def handle_request(
        "stageHunk",
        %{"path" => path, "hunk" => hunk, "lines" => lines},
        _ctx,
        state
      ) do
    hunk = %{
      old_start: hunk["old_start"],
      old_count: hunk["old_count"],
      old_lines: hunk["old_lines"]
    }

    rel = Path.relative_to(path, state.repo)

    with repo when repo != nil <- state.repo,
         {:ok, original} <- Git.run(repo, ["show", ":" <> rel]),
         {:ok, staged} <- Diff.apply_hunk(original, hunk, lines),
         {:ok, sha} <- Git.with_temp_file(staged, &Git.run(repo, ["hash-object", "-w", &1])),
         mode = index_mode(repo, rel),
         {:ok, _} <-
           Git.run(repo, ["update-index", "--cacheinfo", "#{mode},#{String.trim(sha)},#{rel}"]) do
      {:reply, true, refresh(state)}
    else
      {:error, :outdated} -> {:error, "this change is out of date, try again"}
      {:error, message} -> {:error, message}
      _ -> {:error, "cannot stage this change"}
    end
  end

  def handle_request("commit", %{"hash" => hash}, _ctx, state) do
    with repo when repo != nil <- state.repo,
         {:ok, out} <-
           Git.run(repo, ["show", "-s", "--format=%H%x1f%an%x1f%ae%x1f%at%x1f%B", hash]),
         [full, author, mail, time, message] <- String.split(out, "\x1f", parts: 5) do
      {:reply,
       %{
         hash: full,
         author: author,
         mail: mail,
         time: String.to_integer(time),
         relative: Log.relative(String.to_integer(time)),
         message: String.trim(message)
       }}
    else
      _ -> {:error, "unknown commit"}
    end
  end

  defp index_mode(repo, rel) do
    case Git.run(repo, ["ls-files", "-s", "--", rel]) do
      {:ok, <<mode::binary-size(6), " ", _::binary>>} -> mode
      _ -> "100644"
    end
  end

  ## Keeping up

  @impl true
  def handle_event({:fs_changed, _path}, state), do: {:ok, refresh_soon(state)}
  def handle_event({:buffer_saved, _path}, state), do: {:ok, refresh_soon(state)}
  def handle_event(_event, _state), do: :ok

  @impl true
  def handle_info(:refresh, state), do: {:ok, refresh(%{state | timer: nil})}

  def handle_info({:op_done, ctx, what, result}, state) do
    case result do
      {:ok, _} -> Bee.API.set_status(ctx, "#{what} done")
      {:error, message} -> Bee.API.show_message(ctx, :error, "Git: #{message}")
    end

    {:ok, refresh(%{state | op: nil})}
  end

  def handle_info(_msg, _state), do: :ok

  # File events come in bursts (a checkout touches many files).
  defp refresh_soon(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(state.ctx.host, :refresh, 300)}

  defp refresh_soon(state), do: state

  ## Reading the repository

  defp refresh(state) do
    root = state.ctx.root

    state =
      case Git.toplevel(root) do
        nil ->
          %{state | repo: nil, status: nil, log: [], has_head: false}

        repo ->
          status =
            case Git.run(repo, [
                   "status",
                   "--porcelain=v1",
                   "-z",
                   "--branch",
                   "--untracked-files=all",
                   "--ignored=matching"
                 ]) do
              {:ok, out} -> Status.parse(out)
              {:error, _} -> %{branch: nil, upstream: nil, ahead: 0, behind: 0, entries: []}
            end

          log =
            case Git.run(repo, [
                   "log",
                   "-n",
                   "#{@log_size}",
                   "--format=#{Log.format()}",
                   "--name-status"
                 ]) do
              {:ok, out} -> Log.parse(out)
              {:error, _} -> []
            end

          %{state | repo: repo, status: status, log: log, has_head: Git.has_head?(repo)}
      end

    publish(state)
  end

  ## Showing

  defp publish(%{repo: nil} = state) do
    ctx = state.ctx
    Bee.API.set_context(ctx, "git.repository", false)

    Bee.API.set_view(ctx, @changes, %{
      message:
        "The folder currently open doesn't have a git repository. You can initialize a repository which will enable source control features powered by git.",
      buttons: [%{label: "Initialize Repository", command: "git.init"}]
    })

    Bee.API.set_view(ctx, @commits, %{message: "No repository."})
    Bee.API.remove_status_item(ctx, "branch")
    Bee.API.remove_status_item(ctx, "sync")
    Bee.API.set_file_decorations(ctx, %{})
    Bee.API.post_message(ctx, %{changed: true})
    state
  end

  defp publish(state) do
    ctx = state.ctx
    status = state.status
    Bee.API.set_context(ctx, "git.repository", true)

    groups =
      [
        {:conflict, "merge", "Merge Changes", "conflictGroup", "conflict"},
        {:staged, "staged", "Staged Changes", "stagedGroup", "staged"},
        {:change, "changes", "Changes", "changesGroup", "change"}
      ]
      |> Enum.map(fn {group, id, label, group_context, item_context} ->
        entries = Enum.filter(status.entries, &(&1.group == group))
        {entries, group_item(state, id, label, group_context, item_context, entries)}
      end)
      |> Enum.reject(fn {entries, _} -> entries == [] end)
      |> Enum.map(&elem(&1, 1))

    count =
      status.entries
      |> Enum.reject(&(&1.group == :ignored))
      |> Enum.map(& &1.path)
      |> Enum.uniq()
      |> length()

    branch = status.branch || "HEAD"

    Bee.API.set_view(ctx, @changes, %{
      input: %{
        placeholder: "Message (Ctrl+Enter to commit on '#{branch}')",
        command: "git.commit",
        action: "✓ Commit"
      },
      items: groups,
      message: if(groups == [], do: "No changes."),
      badge: count
    })

    Bee.API.set_view(ctx, @commits, commits_view(state))

    dirty = if count > 0, do: "*", else: ""

    Bee.API.set_status_item(ctx, "branch", %{
      text: if(state.op, do: "#{branch}#{dirty} – #{state.op}…", else: "#{branch}#{dirty}"),
      icon: if(state.op, do: "arrow-path", else: "share"),
      tooltip: "#{branch}, Checkout Branch…",
      command: "git.checkout",
      priority: 100
    })

    if status.upstream do
      Bee.API.set_status_item(ctx, "sync", %{
        text: "#{status.behind}↓ #{status.ahead}↑",
        icon: "arrow-path",
        tooltip: "Synchronize Changes (#{status.upstream})",
        command: "git.sync",
        priority: 99
      })
    else
      Bee.API.remove_status_item(ctx, "sync")
    end

    Bee.API.set_file_decorations(ctx, decorations(state))

    # The browser part reloads blame and change markers.
    Bee.API.post_message(ctx, %{changed: true})
    state
  end

  # The Explorer's colours: green for new files, yellow for modified ones,
  # red for conflicts, dimmed for ignored ones. A file both staged and
  # changed shows its working tree state, like VS Code.
  defp decorations(state) do
    state.status.entries
    |> Enum.group_by(& &1.path)
    |> Map.new(fn {path, entries} ->
      entry =
        Enum.find(entries, &(&1.group == :conflict)) ||
          Enum.find(entries, &(&1.group == :change)) || hd(entries)

      {abs(state, String.trim_trailing(path, "/")),
       %{badge: entry.letter, color: entry.color, tooltip: entry.label}}
    end)
  end

  defp group_item(state, id, label, group_context, item_context, entries) do
    %{
      id: id,
      label: label,
      context: group_context,
      decoration: %{text: to_string(length(entries))},
      arguments: [],
      children:
        for entry <- Enum.sort_by(entries, & &1.path) do
          path = abs(state, entry.path)
          rel = rel(state.ctx, path)
          dir = Path.dirname(rel)

          %{
            id: "#{id}:#{entry.path}",
            label: Path.basename(entry.path),
            description: if(dir != ".", do: dir),
            tooltip: "#{rel} • #{entry.label}#{if entry.from, do: " (from #{entry.from})"}",
            resource: path,
            decoration: %{text: entry.letter, color: entry.color},
            context: item_context,
            command: %{command: "git.openFile", arguments: [path]},
            arguments: [path]
          }
        end
    }
  end

  defp commits_view(%{log: []}), do: %{message: "No commits yet."}

  defp commits_view(state) do
    %{
      items:
        for commit <- state.log do
          %{
            id: commit.hash,
            label: commit.subject,
            description: "#{commit.author}, #{Log.relative(commit.time)}",
            tooltip:
              "#{commit.short} • #{commit.author} • #{format_time(commit.time)}\n\n#{commit.subject}",
            icon: "user-circle",
            context: "commit",
            expanded: false,
            children:
              for file <- commit.files do
                path = abs(state, file.path)

                %{
                  id: "#{commit.hash}:#{file.path}",
                  label: Path.basename(file.path),
                  description: Path.dirname(file.path) |> then(&if(&1 == ".", do: nil, else: &1)),
                  resource: path,
                  decoration: %{text: file.status, color: file_color(file.status)},
                  context: "commitFile",
                  command: %{command: "git.openFile", arguments: [path]},
                  arguments: [path]
                }
              end
          }
        end
    }
  end

  defp file_color("A"), do: "added"
  defp file_color("D"), do: "deleted"
  defp file_color(_), do: "modified"

  defp format_time(time),
    do: time |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M")

  ## Helpers

  defp git(ctx, state, args) do
    case Git.run(state.repo, args) do
      {:ok, _} -> {:ok, refresh(state)}
      {:error, message} -> error(ctx, message)
    end
  end

  defp error(ctx, message) do
    Bee.API.show_message(ctx, :error, "Git: #{message}")
    :ok
  end

  defp paths(%{args: args}), do: Enum.filter(args, &is_binary/1)

  defp abs(state, repo_path), do: Path.join(state.repo, repo_path)

  defp rel(ctx, path) do
    case Path.relative_to(path, ctx.root) do
      ^path -> path
      rel -> rel
    end
  end
end

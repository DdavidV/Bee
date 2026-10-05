defmodule BeeGitTest do
  # The built-in git plugin, with a real repository in the test workspace.
  use ExUnit.Case, async: false

  alias Bee.Editor.Buffer
  alias Bee.Plugins
  alias BeeGit.{Blame, Diff, Log, Status}

  @moduletag :capture_log

  describe "parsing" do
    test "status: branch, upstream, groups and renames" do
      out =
        Enum.join(
          [
            "## main...origin/main [ahead 2, behind 1]",
            "M  staged.ex",
            " M changed.ex",
            "MM both.ex",
            "?? new.ex",
            "UU conflict.ex",
            "R  new_name.ex",
            "old_name.ex",
            ""
          ],
          <<0>>
        )

      status = Status.parse(out)
      assert %{branch: "main", upstream: "origin/main", ahead: 2, behind: 1} = status

      assert Enum.map(status.entries, &{&1.path, &1.group, &1.letter}) == [
               {"staged.ex", :staged, "M"},
               {"changed.ex", :change, "M"},
               {"both.ex", :staged, "M"},
               {"both.ex", :change, "M"},
               {"new.ex", :change, "U"},
               {"conflict.ex", :conflict, "!"},
               {"new_name.ex", :staged, "R"}
             ]

      assert List.last(status.entries).from == "old_name.ex"
      assert %{branch: "main", upstream: nil} = Status.parse("## No commits yet on main" <> <<0>>)
    end

    test "blame porcelain" do
      hash = String.duplicate("a", 40)

      out = """
      #{hash} 1 1 2
      author Ada
      author-mail <ada@example.com>
      author-time 1700000000
      summary First
      \tline one
      #{hash} 2 2
      \tline two
      #{Blame.uncommitted()} 3 3 1
      author Not Committed Yet
      \tnew line
      """

      assert %{lines: [^hash, ^hash, uncommitted], commits: commits} = Blame.parse(out)
      assert uncommitted == Blame.uncommitted()

      assert commits[hash] == %{
               author: "Ada",
               mail: "ada@example.com",
               time: 1_700_000_000,
               summary: "First"
             }

      assert commits[uncommitted].author == "You"
    end

    test "diff hunks" do
      out = """
      @@ -0,0 +1,2 @@
      @@ -5 +7 @@
      @@ -9,2 +10,0 @@
      """

      assert %{added: [[1, 2]], modified: [[7, 7]], deleted: [10], hunks: hunks} = Diff.parse(out)
      assert length(hunks) == 3
    end

    test "hunks keep their old lines, and one can be applied alone" do
      out = """
      diff --git a/x b/x
      @@ -1 +1 @@
      -one
      +ONE
      @@ -3,0 +4,2 @@
      +new a
      +new b
      @@ -5 +6,0 @@
      -five
      \\ No newline at end of file
      """

      assert [
               %{old_start: 1, old_count: 1, new_start: 1, new_count: 1, old_lines: ["one"]},
               %{old_start: 3, old_count: 0, new_start: 4, new_count: 2, old_lines: []},
               %{old_start: 5, old_count: 1, new_start: 6, new_count: 0, old_lines: ["five"]}
             ] = Diff.parse(out).hunks

      original = "one\ntwo\nthree\nfour\nfive\n"
      [first, second, third] = Diff.parse(out).hunks

      assert Diff.apply_hunk(original, first, ["ONE"]) == {:ok, "ONE\ntwo\nthree\nfour\nfive\n"}

      assert Diff.apply_hunk(original, second, ["new a", "new b"]) ==
               {:ok, "one\ntwo\nthree\nnew a\nnew b\nfour\nfive\n"}

      assert Diff.apply_hunk(original, third, []) == {:ok, "one\ntwo\nthree\nfour\n"}
      # the original changed since: refuse rather than stage the wrong lines
      assert Diff.apply_hunk("uno\n", first, ["ONE"]) == {:error, :outdated}
    end

    test "log and relative times" do
      out = "\x1eabc\x1fab\x1fAda\x1f1700000000\x1fFirst\n\nA\ta.ex\nR100\told.ex\tnew.ex\n"

      assert [%{hash: "abc", author: "Ada", subject: "First", files: files}] = Log.parse(out)
      assert files == [%{status: "A", path: "a.ex"}, %{status: "R", path: "new.ex"}]

      now = System.os_time(:second)
      assert Log.relative(now) == "just now"
      assert Log.relative(now - 120) == "2 minutes ago"
      assert Log.relative(now - 86_400) == "1 day ago"
    end
  end

  describe "the plugin" do
    setup do
      root = Bee.Workspace.root()
      File.rm_rf!(root)
      File.mkdir_p!(root)
      Application.put_env(:bee, :builtin_plugins, true)
      Plugins.subscribe()
      Bee.UI.subscribe()

      on_exit(fn ->
        Application.put_env(:bee, :builtin_plugins, false)
        Plugins.reload()
        File.rm_rf!(root)
      end)

      %{root: root}
    end

    defp sh!(root, args) do
      {out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
      out
    end

    defp repo!(root) do
      sh!(root, ["init", "-q", "-b", "main"])
      sh!(root, ["config", "user.name", "Ada"])
      sh!(root, ["config", "user.email", "ada@example.com"])
      File.write!(Path.join(root, "a.txt"), "one\ntwo\n")
      sh!(root, ["add", "."])
      sh!(root, ["commit", "-q", "-m", "First commit"])
    end

    defp ctx(fields \\ []),
      do: struct(Bee.Plugins.Context, [window: self(), root: Bee.Workspace.root()] ++ fields)

    defp run(id, args \\ []), do: :ok = Plugins.execute("git", id, ctx(args: args))

    # The changes view once it matches `fun`.
    defp await_view(fun, tries \\ 100) do
      view = Bee.UI.view("git.changes")

      cond do
        view && fun.(view) -> view
        tries == 0 -> flunk("git.changes is #{inspect(view)}")
        true -> Process.sleep(30) && await_view(fun, tries - 1)
      end
    end

    defp group(view, id), do: Enum.find(view.items, &(&1.id == id))
    defp labels(nil), do: []
    defp labels(group), do: Enum.map(group.children, &{&1.label, &1.decoration.text})

    test "outside a repository it offers to initialize one", %{root: root} do
      Plugins.reload()
      view = await_view(&(&1.buttons != []))
      assert [%{label: "Initialize Repository", command: "git.init"}] = view.buttons
      assert Bee.UI.context()["git.repository"] == false

      run("git.init")
      await_view(&(&1.input != nil))
      assert File.dir?(Path.join(root, ".git"))
      assert Bee.UI.context()["git.repository"] == true
    end

    test "changes, staging and committing", %{root: root} do
      repo!(root)
      File.write!(Path.join(root, "a.txt"), "one\nTWO\n")
      File.write!(Path.join(root, "b.txt"), "new\n")
      Plugins.reload()

      view = await_view(&(&1.items != []))
      assert labels(group(view, "changes")) == [{"a.txt", "M"}, {"b.txt", "U"}]
      assert view.badge == 2
      assert view.input.placeholder =~ "commit on 'main'"
      assert Enum.any?(Bee.UI.status_items(), &(&1.owner == "git" and &1.text == "main*"))

      run("git.stage", [Path.join(root, "b.txt")])
      view = await_view(&group(&1, "staged"))
      assert labels(group(view, "staged")) == [{"b.txt", "A"}]
      assert labels(group(view, "changes")) == [{"a.txt", "M"}]

      run("git.unstage", [Path.join(root, "b.txt")])
      await_view(&(group(&1, "staged") == nil))

      # nothing staged: commits everything (smart commit), clears the box
      run("git.commit", ["Second commit"])
      assert_receive {:bee_api, {:set_view_input, "git.changes", ""}}, 3_000
      view = await_view(&(&1.items == []))
      assert view.message == "No changes."
      assert sh!(root, ["log", "--format=%s"]) == "Second commit\nFirst commit\n"

      commits = Bee.UI.view("git.commits")
      assert [%{label: "Second commit"}, %{label: "First commit"}] = commits.items
      assert [%{label: "a.txt"}, %{label: "b.txt"}] = hd(commits.items).children
    end

    test "the Explorer's colours: new green, modified yellow, ignored dimmed", %{root: root} do
      repo!(root)
      File.mkdir_p!(Path.join(root, "lib/deep"))
      File.write!(Path.join(root, ".gitignore"), "_build/\n")
      File.mkdir_p!(Path.join(root, "_build"))
      File.write!(Path.join(root, "_build/x"), "")
      File.write!(Path.join(root, "lib/deep/new.ex"), "new\n")
      File.write!(Path.join(root, "a.txt"), "changed\n")
      Plugins.reload()
      await_view(&(&1.items != []))

      decorations = Bee.UI.Decorations.for_workspace(Bee.UI.decorations(), root)
      assert %{badge: "M", color: "modified"} = decorations["a.txt"]
      assert %{badge: "U", color: "untracked"} = decorations["lib/deep/new.ex"]
      assert %{badge: nil, color: "untracked"} = decorations["lib"]
      assert %{badge: nil, color: "ignored"} = decorations["_build"]

      # after committing, nothing is decorated but ignored files
      run("git.commit", ["all"])
      await_view(&(&1.items == []))
      decorations = Bee.UI.Decorations.for_workspace(Bee.UI.decorations(), root)
      assert Map.keys(decorations) == ["_build"]
    end

    test "discarding asks first", %{root: root} do
      repo!(root)
      path = Path.join(root, "a.txt")
      File.write!(path, "changed\n")
      Plugins.reload()
      await_view(&(&1.items != []))

      run("git.clean", [path])

      assert_receive {:bee_api,
                      {:quick_pick, %{command: "git.cleanConfirmed", items: [%{value: ^path}]}}},
                     3_000

      assert File.read!(path) == "changed\n"

      run("git.cleanConfirmed", [path])
      await_view(&(&1.items == []))
      assert File.read!(path) == "one\ntwo\n"
    end

    test "blame and change markers for the editor, with unsaved text", %{root: root} do
      repo!(root)
      path = Path.join(root, "a.txt")
      {:ok, _} = Buffer.open(path)
      on_exit(fn -> Buffer.close(path) end)
      Buffer.update(path, "one\nTWO\nthree\n")
      Plugins.reload()
      await_view(& &1)

      :ok = Plugins.request("git", "blame", %{"path" => path}, ctx(), "r1")

      assert_receive {:bee_api,
                      {:reply, "r1", {:ok, %{lines: [first, second, third], commits: commits}}}},
                     3_000

      assert first != Blame.uncommitted()
      assert %{author: "Ada", summary: "First commit", relative: "just now"} = commits[first]
      assert second == Blame.uncommitted() and third == Blame.uncommitted()

      :ok = Plugins.request("git", "diff", %{"path" => path}, ctx(), "r2")

      # "two" → "TWO" + "three": one hunk, as VS Code marks it
      assert_receive {:bee_api, {:reply, "r2", {:ok, diff}}}, 3_000
      assert %{added: [], modified: [[2, 3]], deleted: [], hunks: [%{old_lines: ["two"]}]} = diff

      :ok = Plugins.request("git", "commit", %{"hash" => first}, ctx(), "r3")

      assert_receive {:bee_api,
                      {:reply, "r3", {:ok, %{message: "First commit", mail: "ada@example.com"}}}},
                     3_000
    end

    test "staging one change of an open file, from its peek", %{root: root} do
      repo!(root)
      path = Path.join(root, "a.txt")
      File.write!(path, "one\ntwo\nthree\nfour\n")
      sh!(root, ["commit", "-qam", "four lines"])
      {:ok, _} = Buffer.open(path)
      on_exit(fn -> Buffer.close(path) end)
      Buffer.update(path, "ONE\ntwo\nthree\nFOUR\n")
      Plugins.reload()
      await_view(& &1)

      :ok = Plugins.request("git", "diff", %{"path" => path}, ctx(), "d1")
      assert_receive {:bee_api, {:reply, "d1", {:ok, %{hunks: [first, second]}}}}, 3_000
      assert %{old_lines: ["one"], new_start: 1} = first
      assert %{old_lines: ["four"], new_start: 4} = second

      hunk = %{"old_start" => 1, "old_count" => 1, "old_lines" => first.old_lines}
      params = %{"path" => path, "hunk" => hunk, "lines" => ["ONE"]}
      :ok = Plugins.request("git", "stageHunk", params, ctx(), "s1")
      assert_receive {:bee_api, {:reply, "s1", {:ok, true}}}, 3_000

      # only the first line is staged; the file on disk is untouched
      assert sh!(root, ["diff", "--cached", "-U0", "--no-color"]) =~ ~r/-one\n\+ONE\n$/
      assert sh!(root, ["show", ":a.txt"]) == "ONE\ntwo\nthree\nfour\n"
      assert File.read!(path) == "one\ntwo\nthree\nfour\n"

      # staging it again: the index no longer has "one" there
      :ok = Plugins.request("git", "stageHunk", params, ctx(), "s2")

      assert_receive {:bee_api, {:reply, "s2", {:error, "this change is out of date" <> _}}},
                     3_000
    end

    test "branches: checkout offers the branches and creating one", %{root: root} do
      repo!(root)
      Plugins.reload()
      await_view(& &1)

      run("git.checkout")

      assert_receive {:bee_api,
                      {:quick_pick, %{items: [%{value: %{create: true}}, %{label: "main"}]}}},
                     3_000

      run("git.checkoutTo", [%{"create" => true}])
      assert_receive {:bee_api, {:input_box, %{command: "git.branch"}}}

      run("git.branch", ["feature x"])
      await_view(&(&1.input.placeholder =~ "feature-x"))
      assert sh!(root, ["branch", "--show-current"]) == "feature-x\n"
    end
  end
end

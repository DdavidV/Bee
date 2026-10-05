defmodule Bee.SearchTest do
  # Uses the shared test workspace and settings.
  use ExUnit.Case, async: false

  alias Bee.Editor.Buffer
  alias Bee.Search

  setup do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(
      Path.join(root, "lib/a.ex"),
      "defmodule A do\n  def hello, do: :héllo\n  # Hello again\nend\n"
    )

    File.write!(Path.join(root, "test/a_test.exs"), "hello world\n")
    File.write!(Path.join(root, "notes.md"), "nothing here\n")
    File.write!(Path.join(root, "bin.dat"), <<255, 0, 104, 101, 108, 108, 111>>)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm(Bee.Settings.user_path())
      Bee.Settings.reload()
    end)

    %{root: root}
  end

  defp search(opts) do
    {:ok, %{ref: ref}} = Search.start(opts)
    collect(ref, [])
  end

  defp collect(ref, acc) do
    receive do
      {:search_results, ^ref, files} -> collect(ref, acc ++ files)
      {:search_done, ^ref, stats} -> {Enum.sort_by(acc, & &1.path), stats}
    after
      3_000 -> flunk("search did not finish")
    end
  end

  defp paths({files, _stats}), do: Enum.map(files, & &1.path)

  test "finds matches with line numbers and previews, case-insensitive by default" do
    {[a, t], stats} = search(%{query: "hello"})

    assert a.path == "lib/a.ex"

    assert [
             %{line: 2, before: "def ", match: "hello", after: ", do: :héllo"},
             %{line: 3, before: "# ", match: "Hello", after: " again"}
           ] = a.matches

    # byte offsets into the file
    text = File.read!(Path.join(Bee.Workspace.root(), "lib/a.ex"))
    assert binary_part(text, hd(a.matches).from, 5) == "hello"

    assert t.path == "test/a_test.exs"
    assert %{files: 2, matches: 3, limit_hit: false} = stats
  end

  test "match case, whole word and regex options" do
    assert {[%{path: "test/a_test.exs"}, _] = _, _} =
             search(%{query: "hello"}) |> then(fn {f, s} -> {Enum.reverse(f), s} end)

    {files, _} = search(%{query: "Hello", case_sensitive: true})
    assert [%{path: "lib/a.ex", matches: [%{line: 3}]}] = files

    {files, _} = search(%{query: "hell", whole_word: true})
    assert files == []

    {files, _} = search(%{query: "h.llo$", regex: true, case_sensitive: true})
    assert [%{path: "lib/a.ex", matches: [%{match: "héllo", line: 2}]}] = files

    assert {:error, "Invalid regular expression" <> _} = Search.start(%{query: "(", regex: true})
    assert {:error, _} = Search.start(%{query: ""})
  end

  test "include / exclude globs and the search.exclude setting" do
    assert paths(search(%{query: "hello", include: "lib"})) == ["lib/a.ex"]
    assert paths(search(%{query: "hello", include: "*.exs"})) == ["test/a_test.exs"]
    assert paths(search(%{query: "hello", exclude: "test, *.md"})) == ["lib/a.ex"]

    File.write!(Bee.Settings.user_path(), ~s({"search.exclude": {"lib/**": true}}))
    Bee.Settings.reload()
    assert paths(search(%{query: "hello"})) == ["test/a_test.exs"]
  end

  test "stops at max_results" do
    assert {_files, %{matches: 2, limit_hit: true}} = search(%{query: "hello", max_results: 2})
  end

  test "open files are searched with their unsaved text", %{root: root} do
    path = Path.join(root, "notes.md")
    {:ok, _} = Buffer.open(path)
    on_exit(fn -> Buffer.close(path) end)
    Buffer.update(path, "unsaved hello\n")

    assert "notes.md" in paths(search(%{query: "hello"}))
  end

  describe "replace" do
    test "literal text in closed files, written to disk", %{root: root} do
      assert {:ok, 3} = Search.replace(["lib/a.ex", "test/a_test.exs"], %{query: "hello"}, "bye")
      # "héllo" isn't "hello"
      assert File.read!(Path.join(root, "test/a_test.exs")) == "bye world\n"
      assert File.read!(Path.join(root, "lib/a.ex")) =~ "def bye, do: :héllo\n  # bye again"
    end

    test "regex groups, one match only" do
      opts = %{query: "(\\w+) (\\w+)", regex: true}
      text = "hello world\nfoo bar\n"
      {:ok, regex} = Search.compile(opts)

      assert Search.edits(text, regex, opts, "$2 $1 ($&) $$") ==
               [{0, 11, "world hello (hello world) $"}, {12, 19, "bar foo (foo bar) $"}]

      assert Search.edits(text, regex, opts, "x", [12]) == [{12, 19, "x"}]
    end

    test "open files are edited through their buffer", %{root: root} do
      path = Path.join(root, "test/a_test.exs")
      {:ok, _} = Buffer.open(path)
      on_exit(fn -> Buffer.close(path) end)
      Buffer.subscribe()

      assert {:ok, 1} = Search.replace(["test/a_test.exs"], %{query: "world"}, "there")
      assert_receive {:buffer_edited, ^path, _, [{6, 11, "there"}], "hello there\n"}
      # not saved
      assert File.read!(path) == "hello world\n"
    end
  end
end

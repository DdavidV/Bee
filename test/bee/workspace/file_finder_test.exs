defmodule Bee.Workspace.FileFinderTest do
  use ExUnit.Case, async: true

  alias Bee.Workspace.FileFinder

  setup do
    root = Path.join(System.tmp_dir!(), "bee_finder_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/deep"))
    File.mkdir_p!(Path.join(root, "target"))
    File.write!(Path.join(root, "lib/app.ex"), "")
    File.write!(Path.join(root, "lib/deep/apple.ex"), "")
    File.write!(Path.join(root, "target/app.o"), "")
    File.write!(Path.join(root, "README.md"), "")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp listed(root, max \\ 100) do
    me = self()
    FileFinder.list(root, max, &send(me, {:chunk, &1}))
    collect([])
  end

  defp collect(acc) do
    receive do
      {:chunk, paths} -> collect(acc ++ paths)
    after
      0 -> Enum.sort(acc)
    end
  end

  # The answer to `query` once the finder has listed everything.
  defp answer(finder, query) do
    FileFinder.query(finder, query)

    receive do
      {:file_finder, ^finder, ^query, paths, false} -> paths
      {:file_finder, ^finder, ^query, _paths, true} -> answer(finder, query)
    after
      3_000 -> flunk("no answer for #{query}")
    end
  end

  test "lists a folder's files; a git repository's without what .gitignore leaves out",
       %{root: root} do
    assert listed(root) == ["README.md", "lib/app.ex", "lib/deep/apple.ex", "target/app.o"]
    # cut short: the top folder's files first
    assert listed(root, 1) == ["README.md"]

    File.write!(Path.join(root, ".gitignore"), "target/\n")
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root)

    assert listed(root) == [".gitignore", "README.md", "lib/app.ex", "lib/deep/apple.ex"]
  end

  test "answers queries, best first; stops with its owner", %{root: root} do
    {:ok, finder} = FileFinder.start(root)
    ref = Process.monitor(finder)

    assert answer(finder, "app") == ["lib/app.ex", "target/app.o", "lib/deep/apple.ex"]
    # narrowed from "app"
    assert answer(finder, "appl") == ["lib/deep/apple.ex"]
    assert answer(finder, "readme") == ["README.md"]

    FileFinder.stop(finder)
    assert_receive {:DOWN, ^ref, :process, ^finder, :normal}
  end

  test "goes when the window does", %{root: root} do
    test = self()

    owner =
      spawn(fn ->
        {:ok, finder} = FileFinder.start(root)
        send(test, {:finder, finder})
        receive do: (:never -> :ok)
      end)

    assert_receive {:finder, finder}
    ref = Process.monitor(finder)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^finder, :normal}
  end
end

defmodule Bee.Workspace.FSTest do
  use ExUnit.Case, async: true

  alias Bee.Workspace.FS

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "bee_fs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "resolve/2" do
    test "accepts paths inside the root", %{tmp_dir: root} do
      assert FS.resolve(root, "lib/a.ex") == {:ok, Path.join(root, "lib/a.ex")}
      assert FS.resolve(root, "") == {:ok, root}
      assert FS.resolve(root, "lib/../mix.exs") == {:ok, Path.join(root, "mix.exs")}
    end

    test "rejects paths escaping the root", %{tmp_dir: root} do
      assert FS.resolve(root, "..") == {:error, :outside_root}
      assert FS.resolve(root, "../other") == {:error, :outside_root}
      assert FS.resolve(root, "/etc/passwd") == {:error, :outside_root}
      # sibling directory sharing the root's name as a prefix
      assert FS.resolve(root, "../" <> Path.basename(root) <> "-evil/x") ==
               {:error, :outside_root}
    end
  end

  describe "list_dir/3" do
    test "lists dirs first, alphabetically, skipping excluded names", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "zdir"))
      File.mkdir_p!(Path.join(root, "Adir/nested"))
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, "b.txt"), "")
      File.write!(Path.join(root, "A.txt"), "")

      assert [
               %{name: "Adir", path: "Adir", type: :dir},
               %{name: "zdir", path: "zdir", type: :dir},
               %{name: "A.txt", path: "A.txt", type: :file},
               %{name: "b.txt", path: "b.txt", type: :file}
             ] = FS.list_dir(root, "", ["**/.git"])

      assert [%{name: "nested", path: "Adir/nested", type: :dir}] = FS.list_dir(root, "Adir")
    end

    test "exclude globs match the path relative to the root", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "a/deps"))
      File.mkdir_p!(Path.join(root, "a/keep"))

      assert [%{name: "keep"}] = FS.list_dir(root, "a", ["**/deps"])
      assert [_, _] = FS.list_dir(root, "a", ["deps"]), "unanchored name only matches at the root"
    end

    test "returns [] for missing or escaping paths", %{tmp_dir: root} do
      assert FS.list_dir(root, "nope") == []
      assert FS.list_dir(root, "..") == []
    end
  end
end

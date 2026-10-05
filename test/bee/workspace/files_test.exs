defmodule Bee.Workspace.FilesTest do
  use ExUnit.Case, async: true

  alias Bee.Workspace.Files

  setup do
    root = Path.join(System.tmp_dir!(), "bee_files_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "a")
    File.write!(Path.join(root, "README.md"), "readme")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp p(root, rel), do: Path.join(root, rel)

  test "creates files and folders, nested ones too", %{root: root} do
    assert {:ok, path} = Files.create_file(root, p(root, "lib"), "b.ex")
    assert path == p(root, "lib/b.ex")
    assert File.read!(path) == ""

    assert {:ok, _} = Files.create_file(root, root, " docs/guide/intro.md ")
    assert File.regular?(p(root, "docs/guide/intro.md"))

    assert {:ok, _} = Files.create_folder(root, root, "assets/css")
    assert File.dir?(p(root, "assets/css"))
  end

  test "refuses taken, empty and escaping names", %{root: root} do
    assert {:error, message} = Files.create_file(root, p(root, "lib"), "a.ex")
    assert message == "A file or folder lib/a.ex already exists"
    assert {:error, _} = Files.create_folder(root, root, "lib")

    assert {:error, "A file or folder name must be provided"} =
             Files.create_file(root, root, "  ")

    assert {:error, _} = Files.create_file(root, root, "../evil")
    assert {:error, _} = Files.create_file(root, root, "a/../../evil")
    assert {:error, _} = Files.create_file(root, root, "/etc/passwd")
    assert {:error, _} = Files.create_file(root, "/tmp", "x")
    refute File.exists?(Path.join(Path.dirname(root), "evil"))
  end

  test "renames, also into a new folder, but not onto an existing name", %{root: root} do
    assert {:ok, to} = Files.rename(root, p(root, "lib/a.ex"), "b.ex")
    assert to == p(root, "lib/b.ex")
    assert File.read!(to) == "a"

    assert {:ok, _} = Files.rename(root, p(root, "lib/b.ex"), "sub/c.ex")
    assert File.read!(p(root, "lib/sub/c.ex")) == "a"

    assert {:error, message} = Files.rename(root, p(root, "lib"), "README.md")
    assert message =~ "already exists"
    assert {:error, _} = Files.rename(root, p(root, "lib"), "lib/inner")
    assert {:ok, _} = Files.rename(root, p(root, "README.md"), "readme.md")
    assert File.exists?(p(root, "readme.md"))
    assert {:error, message} = Files.rename(root, p(root, "nope"), "x")
    assert message =~ "doesn't exist"
  end

  test "deletes files and folders, never the workspace", %{root: root} do
    assert {:ok, _} = Files.delete(root, p(root, "lib"))
    refute File.exists?(p(root, "lib"))
    assert {:ok, _} = Files.delete(root, p(root, "README.md"))
    assert {:error, _} = Files.delete(root, root)
    assert {:error, _} = Files.delete(root, Path.dirname(root))
    assert File.dir?(root)
  end

  test "copy-pastes with copy names, folders too", %{root: root} do
    assert {:ok, [{_, to}]} = Files.paste(root, [p(root, "lib/a.ex")], p(root, "lib"), :copy)
    assert to == p(root, "lib/a copy.ex")
    assert {:ok, [{_, to}]} = Files.paste(root, [p(root, "lib/a.ex")], p(root, "lib"), :copy)
    assert to == p(root, "lib/a copy 2.ex")

    assert {:ok, [{_, to}, {_, _}]} =
             Files.paste(root, [p(root, "lib"), p(root, "README.md")], root, :copy)

    assert to == p(root, "lib copy")
    assert File.read!(p(root, "lib copy/a.ex")) == "a"
    assert File.exists?(p(root, "README copy.md"))

    assert {:error, message} = Files.paste(root, [p(root, "lib")], p(root, "lib"), :copy)
    assert message =~ "into itself"
  end

  test "cut-pastes (moves), refusing taken names", %{root: root} do
    File.mkdir_p!(p(root, "docs"))
    assert {:ok, [{from, to}]} = Files.paste(root, [p(root, "README.md")], p(root, "docs"), :cut)
    assert {from, to} == {p(root, "README.md"), p(root, "docs/README.md")}
    refute File.exists?(from)

    # Into the folder it is in: nothing to do.
    assert {:ok, [{same, same}]} = Files.paste(root, [to], p(root, "docs"), :cut)

    File.write!(p(root, "README.md"), "new")
    assert {:error, message} = Files.paste(root, [p(root, "README.md")], p(root, "docs"), :cut)
    assert message =~ "already exists"
    assert {:error, _} = Files.paste(root, [p(root, "lib")], p(root, "lib"), :cut)
  end
end

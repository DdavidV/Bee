defmodule Bee.Editor.BufferTest do
  use ExUnit.Case, async: true

  alias Bee.Editor.Buffer

  setup do
    dir = Path.join(System.tmp_dir!(), "bee_buffer_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "a.txt")
    File.write!(path, "hello")
    Buffer.subscribe()
    %{dir: dir, path: path}
  end

  test "open reads the file and is clean", %{path: path} do
    assert {:ok, %Buffer{text: "hello", version: 0} = buffer} = Buffer.open(path)
    refute Buffer.dirty?(buffer)
    assert_receive {:buffer_opened, ^path, "hello"}
  end

  test "opening twice returns the same process", %{path: path} do
    {:ok, _} = Buffer.open(path)
    [{pid, _}] = Registry.lookup(Bee.Registry, {:buffer, path})
    {:ok, _} = Buffer.open(path)
    assert [{^pid, _}] = Registry.lookup(Bee.Registry, {:buffer, path})
  end

  test "update makes it dirty, save writes to disk and cleans it", %{path: path} do
    {:ok, _} = Buffer.open(path)

    buffer = Buffer.update(path, "hello world")
    assert Buffer.dirty?(buffer)
    assert buffer.version == 1
    assert_receive {:buffer_changed, ^path, 1, "hello world"}
    assert File.read!(path) == "hello"

    assert {:ok, buffer} = Buffer.save(path, "hello world!")
    refute Buffer.dirty?(buffer)
    assert File.read!(path) == "hello world!"
    assert_receive {:buffer_saved, ^path, "hello world!"}
  end

  test "updating back to the disk text makes it clean again", %{path: path} do
    {:ok, _} = Buffer.open(path)
    assert Buffer.dirty?(Buffer.update(path, "x"))
    refute Buffer.dirty?(Buffer.update(path, "hello"))
  end

  test "save keeps the file mode and leaves no temp files", %{dir: dir, path: path} do
    File.chmod!(path, 0o755)
    {:ok, _} = Buffer.open(path)
    {:ok, _} = Buffer.save(path, "#!/bin/sh")

    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o755
    assert File.ls!(dir) == ["a.txt"]
  end

  test "reloads from disk when clean", %{path: path} do
    {:ok, _} = Buffer.open(path)
    File.write!(path, "changed")
    send_fs_event(path)

    assert_receive {:buffer_reloaded, ^path, "changed"}
    assert %{text: "changed"} = Buffer.get(path)
  end

  test "keeps unsaved changes when the file changes on disk", %{path: path} do
    {:ok, _} = Buffer.open(path)
    Buffer.update(path, "mine")
    File.write!(path, "theirs")
    send_fs_event(path)

    refute_receive {:buffer_reloaded, _, _}
    assert %{text: "mine"} = Buffer.get(path)
  end

  test "refuses binary and missing files", %{dir: dir} do
    bin = Path.join(dir, "img.bin")
    File.write!(bin, <<0xFF, 0xFE, 0x00>>)
    assert {:error, :binary_file} = Buffer.open(bin)
    assert {:error, :enoent} = Buffer.open(Path.join(dir, "missing"))
  end

  describe "lifecycle" do
    test "stops when the last client closes it", %{path: path} do
      other = spawn_client()
      {:ok, _} = Buffer.open(path)
      {:ok, _} = Buffer.open(path, other)
      [{pid, _}] = Registry.lookup(Bee.Registry, {:buffer, path})
      ref = Process.monitor(pid)

      Buffer.close(path)
      refute_receive {:DOWN, ^ref, _, _, _}

      Buffer.close(path, other)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert_receive {:buffer_closed, ^path}
    end

    test "stops when its last client dies", %{path: path} do
      client = spawn_client()
      {:ok, _} = Buffer.open(path, client)
      [{pid, _}] = Registry.lookup(Bee.Registry, {:buffer, path})
      ref = Process.monitor(pid)
      # Monitors are async signals and may be overtaken by the client's :DOWN
      # (different sender). A call from us is ordered after our monitor.
      Buffer.get(path)

      Process.exit(client, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  defp spawn_client do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # Simulate Bee.Workspace's watcher broadcast.
  defp send_fs_event(path),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, "fs", {:fs_changed, path})

  describe "server-side edits" do
    test "apply_edits/2 applies non-overlapping byte ranges at once" do
      assert Buffer.apply_edits("hello world", [{6, 11, "there"}, {0, 0, ">> "}]) ==
               {:ok, ">> hello there"}

      assert Buffer.apply_edits("abc", []) == {:ok, "abc"}
      assert Buffer.apply_edits("abc", [{0, 2, "x"}, {1, 3, "y"}]) == {:error, :invalid_edits}
      assert Buffer.apply_edits("abc", [{2, 4, "x"}]) == {:error, :invalid_edits}
      assert Buffer.apply_edits("abc", [{2, 1, "x"}]) == {:error, :invalid_edits}
      assert Buffer.apply_edits("abc", [:nope]) == {:error, :invalid_edits}
      # splitting "ö" (2 bytes) in half
      assert Buffer.apply_edits("ö", [{1, 2, ""}]) == {:error, :invalid_utf8}
    end

    test "edit/2 changes the text, broadcasts the edits and makes it dirty", %{path: path} do
      {:ok, _} = Buffer.open(path)

      assert {:ok, buffer} = Buffer.edit(path, [{0, 1, "J"}])
      assert buffer.text == "Jello" and buffer.version == 1
      assert Buffer.dirty?(buffer)
      assert_receive {:buffer_edited, ^path, 1, [{0, 1, "J"}], "Jello"}
      assert_receive {:buffer_changed, ^path, 1, "Jello"}

      assert {:error, :invalid_edits} = Buffer.edit(path, [{0, 99, ""}])
      assert Buffer.edit(Path.join(Path.dirname(path), "closed.txt"), []) == {:error, :not_open}
    end
  end
end

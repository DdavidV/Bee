defmodule Bee.WorkspaceTest do
  # Workspaces and settings are global.
  use ExUnit.Case, async: false

  alias Bee.{Settings, Workspace}

  setup do
    old = Application.get_env(:bee, :workspace_idle_ms)
    Application.put_env(:bee, :workspace_idle_ms, 30)

    base = Path.join(System.tmp_dir!(), "bee_workspaces_#{System.unique_integer([:positive])}")
    a = Path.join(base, "a")
    b = Path.join(base, "b")
    File.mkdir_p!(Path.join(a, "lib"))
    File.mkdir_p!(b)

    on_exit(fn ->
      if old,
        do: Application.put_env(:bee, :workspace_idle_ms, old),
        else: Application.delete_env(:bee, :workspace_idle_ms)

      File.rm_rf!(base)
    end)

    %{a: a, b: b}
  end

  # A window: a process that opens a folder and lives until told.
  defp window(root) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:opened, Workspace.open(root)})

        receive do
          :close -> Workspace.close(root)
        end

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:opened, {:ok, ^root}}
    pid
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  test "a folder is open while a window uses it", %{a: a} do
    w1 = window(a)
    w2 = window(a)
    assert a in Workspace.list()

    send(w1, :close)
    Process.sleep(60)
    assert a in Workspace.list(), "still used by the second window"

    # A window that goes away closes it too.
    Process.exit(w2, :kill)
    eventually(fn -> a not in Workspace.list() end)
  end

  test "only folders open; paths are made absolute", %{a: a} do
    assert {:error, message} = Workspace.open(Path.join(a, "nope"))
    assert message =~ "not a folder"

    window = window(a)
    assert {:ok, ^a} = Workspace.open(Path.join(a, "lib/.."), window)
    Process.exit(window, :kill)
  end

  test "for_path finds the innermost open folder", %{a: a, b: b} do
    inner = Path.join(a, "lib")
    windows = [window(a), window(inner), window(b)]

    assert Workspace.for_path(Path.join(inner, "x.ex")) == inner
    assert Workspace.for_path(Path.join(a, "README.md")) == a
    assert Workspace.for_path(b) == b
    assert Workspace.for_path("/elsewhere/file") == nil

    Enum.each(windows, &Process.exit(&1, :kill))
  end

  describe "settings" do
    setup %{a: a, b: b} do
      File.mkdir_p!(Path.dirname(Settings.user_path()))
      File.write!(Settings.user_path(), ~s({"editor.tabSize": 4, "editor.fontSize": 16}))

      for {root, size} <- [{a, 20}, {b, 24}] do
        File.mkdir_p!(Path.join(root, ".bee"))
        File.write!(Settings.workspace_path(root), ~s({"editor.fontSize": #{size}}))
      end

      Settings.reload()

      on_exit(fn ->
        File.rm(Settings.user_path())
        Settings.reload()
      end)
    end

    test "each workspace has its own layer over the user's", %{a: a, b: b} do
      windows = [window(a), window(b)]

      assert Settings.get("editor.fontSize", a) == 20
      assert Settings.get("editor.fontSize", b) == 24
      assert Settings.get("editor.tabSize", b) == 4
      assert Settings.get("editor.fontSize") == 16

      # A change to one workspace's file is that workspace's alone.
      Settings.subscribe()
      File.write!(Settings.workspace_path(a), ~s({"editor.fontSize": 30}))
      send(Process.whereis(Settings), {:fs_changed, Settings.workspace_path(a)})
      assert_receive {:settings_changed, {:workspace, ^a}}
      assert Settings.get("editor.fontSize", a) == 30
      assert Settings.get("editor.fontSize", b) == 24

      Enum.each(windows, &Process.exit(&1, :kill))
    end

    test "a folder that isn't open is read as it is", %{a: a} do
      assert Settings.get("editor.fontSize", a) == 20
    end
  end
end

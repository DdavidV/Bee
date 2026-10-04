defmodule BeeWeb.EditorLiveTest do
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib/bee"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "mix.exs"), "")
    File.write!(Path.join(root, "lib/bee/app.ex"), "")
    on_exit(fn -> File.rm_rf!(root) end)
    :ok
  end

  test "explorer lists the workspace root without excluded dirs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#explorer button[phx-value-path='lib']")
    assert has_element?(view, "#explorer button[phx-value-path='mix.exs']")
    refute has_element?(view, "#explorer button[phx-value-path='_build']")
  end

  test "expanding directories lazily lists children", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#explorer button[phx-value-path='lib/bee']")
    view |> element("#explorer button[phx-value-path='lib']") |> render_click()
    view |> element("#explorer button[phx-value-path='lib/bee']") |> render_click()
    assert has_element?(view, "#explorer button[phx-value-path='lib/bee/app.ex']")

    # collapsing hides them again
    view |> element("#explorer button[phx-value-path='lib']") |> render_click()
    refute has_element?(view, "#explorer button[phx-value-path='lib/bee']")
  end

  test "clicking a file selects it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#explorer button[phx-value-path='mix.exs']") |> render_click()
    assert has_element?(view, "#selected-file", "mix.exs")
  end

  test "new files show up after a file system event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    root = Bee.Workspace.root()
    path = Path.join(root, "new.txt")
    File.write!(path, "")

    # Don't depend on inotify timing: simulate the watcher's broadcast.
    send(view.pid, {:fs_changed, path})
    assert has_element?(view, "#explorer button[phx-value-path='new.txt']")
  end
end

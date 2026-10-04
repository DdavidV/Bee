defmodule BeeWeb.EditorLiveTest do
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib/bee"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "mix.exs"), "defmodule M do\nend\n")
    File.write!(Path.join(root, "lib/bee/app.ex"), "")
    File.write!(Path.join(root, "README.md"), "# Readme")

    on_exit(fn ->
      stop_buffers_under(root)
      File.rm_rf!(root)
    end)

    :ok
  end

  # Buffers stop asynchronously once their LiveView is gone; make sure none
  # survive into the next test with stale text.
  defp stop_buffers_under(root) do
    for {path, pid} <-
          Registry.select(Bee.Registry, [{{{:buffer, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}]),
        String.starts_with?(path, root <> "/") do
      DynamicSupervisor.terminate_child(Bee.BufferSup, pid)
    end
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

  describe "editing" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      %{view: view, path: Path.join(Bee.Workspace.root(), "mix.exs")}
    end

    test "clicking a file opens it in a tab", %{view: view, path: path} do
      open_file(view, "mix.exs")

      assert_push_event(view, "cm:open", %{
        path: ^path,
        text: "defmodule M do\nend\n",
        lang: "elixir"
      })

      assert has_element?(view, "#tabs [phx-value-path='#{path}']", "mix.exs")
      assert has_element?(view, "#status-lang", "elixir")
    end

    test "opening an open file activates its tab instead", %{view: view, path: path} do
      open_file(view, "mix.exs")
      open_file(view, "README.md")
      open_file(view, "mix.exs")

      assert_push_event(view, "cm:activate", %{path: ^path})
      assert has_element?(view, "#tabs > div:nth-child(2)")
      refute has_element?(view, "#tabs > div:nth-child(3)")
    end

    test "changes mark the tab dirty and save writes them", %{view: view, path: path} do
      open_file(view, "mix.exs")

      render_hook(view, "doc_changed", %{"path" => path, "text" => "changed"})
      assert has_element?(view, "#tabs button[data-confirm]")
      assert File.read!(path) == "defmodule M do\nend\n"

      render_hook(view, "save", %{"path" => path, "text" => "changed"})
      assert File.read!(path) == "changed"
      refute has_element?(view, "#tabs button[data-confirm]")
      assert has_element?(view, "#status", "Saved mix.exs")
    end

    test "closing a tab activates its neighbour and stops the buffer", %{view: view, path: path} do
      open_file(view, "mix.exs")
      open_file(view, "README.md")
      [{buffer, _}] = Registry.lookup(Bee.Registry, {:buffer, path})
      ref = Process.monitor(buffer)

      view
      |> element("#tabs button[phx-click='close_tab'][phx-value-path='#{path}']")
      |> render_click()

      assert_push_event(view, "cm:close", %{path: ^path})
      refute has_element?(view, "#tabs [phx-value-path='#{path}']")
      assert_receive {:DOWN, ^ref, :process, ^buffer, :normal}
    end

    test "events for paths that are not open are ignored", %{view: view} do
      outside = Path.join(System.tmp_dir!(), "bee_not_open.txt")
      render_hook(view, "save", %{"path" => outside, "text" => "x"})
      refute File.exists?(outside)
    end

    test "files changed on disk are reloaded into the editor", %{view: view, path: path} do
      open_file(view, "mix.exs")
      File.write!(path, "from disk")
      Phoenix.PubSub.broadcast(Bee.PubSub, "fs", {:fs_changed, path})

      assert_push_event(view, "cm:reload", %{path: ^path, text: "from disk"})
    end
  end

  test "new files show up after a file system event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    root = Bee.Workspace.root()
    path = Path.join(root, "new.txt")
    File.write!(path, "")

    # Don't depend on inotify timing: simulate the watcher's broadcast.
    send(view.pid, {:fs_changed, path})
    # The LiveView refreshes the tree via send_update/3, i.e. a message to
    # itself that may be queued behind our next call. One round trip first
    # guarantees it is processed before has_element?/2.
    _ = render(view)
    assert has_element?(view, "#explorer button[phx-value-path='new.txt']")
  end

  defp open_file(view, rel) do
    view |> element("#explorer button[phx-value-path='#{rel}']") |> render_click()
  end
end

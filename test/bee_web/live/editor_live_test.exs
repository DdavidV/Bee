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

  describe "sidebar" do
    test "Ctrl+B / explorer button hides and shows it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#sidebar:not(.hidden)")

      view |> element("#toggle-sidebar") |> render_click()
      assert has_element?(view, "#sidebar.hidden")

      # the keybinding pushes the same event
      render_hook(view, "toggle_sidebar", %{})
      assert has_element?(view, "#sidebar:not(.hidden)")
    end

    test "keeps expanded dirs while hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#explorer button[phx-value-path='lib']") |> render_click()

      render_hook(view, "toggle_sidebar", %{})
      render_hook(view, "toggle_sidebar", %{})
      assert has_element?(view, "#explorer button[phx-value-path='lib/bee']")
    end
  end

  describe "terminal" do
    # Keep the user's shell and rc files out of tests.
    setup do
      previous = System.get_env("SHELL")
      System.put_env("SHELL", "/bin/sh")

      on_exit(fn ->
        if previous, do: System.put_env("SHELL", previous), else: System.delete_env("SHELL")
      end)
    end

    test "toggling the panel opens it with a new shell", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#panel")

      id = open_panel(view)
      assert has_element?(view, "#term-tab-#{id}", "1: sh")
      assert [{_pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})
    end

    test "output is forwarded only after term_ready, starting with the scrollback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      id = open_panel(view)

      refute_push_event(view, "term:data", %{id: ^id}, 300)

      render_hook(view, "term_ready", %{"id" => id, "cols" => 80, "rows" => 24})
      assert_reply(view, %{data: scrollback})
      assert Base.decode64!(scrollback) =~ "$"

      render_hook(view, "term_input", %{"id" => id, "data" => "echo bee-$((40 + 2))\n"})
      assert await_term_output(view, id, "bee-42")
    end

    test "killing a terminal stops its process and removes the tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      id = open_panel(view)
      [{pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})
      ref = Process.monitor(pid)

      view |> element("#panel button[phx-click='close_terminal']") |> render_click()
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      refute has_element?(view, "#term-tab-#{id}")
    end

    test "exiting the shell removes its tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      id = open_panel(view)
      [{pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})
      ref = Process.monitor(pid)

      render_hook(view, "term_ready", %{"id" => id, "cols" => 80, "rows" => 24})
      render_hook(view, "term_input", %{"id" => id, "data" => "exit\n"})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      # the LiveView got :term_exit before the DOWN reached us; one round trip to be sure
      _ = render(view)
      refute has_element?(view, "#term-tab-#{id}")
    end

    test "closing the panel keeps shells running; reopening reuses them", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      id = open_panel(view)

      render_hook(view, "toggle_panel", %{})
      refute has_element?(view, "#panel")
      assert [{_pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})

      render_hook(view, "toggle_panel", %{})
      assert has_element?(view, "#term-#{id}")
      refute has_element?(view, "#term-tab-#{id} ~ [id^='term-tab-']")
    end

    test "terminals of other sessions cannot be driven", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      {:ok, other, _html} = live(conn, ~p"/")
      id = open_panel(other)

      render_hook(view, "term_ready", %{"id" => id, "cols" => 80, "rows" => 24})
      assert_reply(view, %{data: ""})
    end

    test "terminals stop when the LiveView goes away", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      id = open_panel(view)
      [{pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})
      ref = Process.monitor(pid)

      GenServer.stop(view.pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  describe "title bar" do
    setup do
      previous = System.get_env("SHELL")
      System.put_env("SHELL", "/bin/sh")

      on_exit(fn ->
        if previous, do: System.put_env("SHELL", previous), else: System.delete_env("SHELL")
      end)
    end

    test "window title shows the active file and the workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      workspace = Path.basename(Bee.Workspace.root())
      assert view |> element("#window-title") |> render() =~ workspace

      open_file(view, "mix.exs")
      assert view |> element("#window-title") |> render() =~ "mix.exs — #{workspace}"
    end

    test "menus open, switch, and close on Escape, click-away or a second click", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "[role=menu]")

      open_menu(view, "file")
      assert has_element?(view, "#menu-file")
      assert has_element?(view, "#menu-file-button[aria-expanded=true]")

      open_menu(view, "view")
      assert has_element?(view, "#menu-view")
      refute has_element?(view, "#menu-file")

      render_keydown(view, "close_menu", %{"key" => "Escape"})
      refute has_element?(view, "[role=menu]")

      open_menu(view, "view")
      render_click(view, "close_menu", %{})
      refute has_element?(view, "[role=menu]")

      open_menu(view, "view")
      open_menu(view, "view")
      refute has_element?(view, "[role=menu]")
    end

    test "layout toggles reflect and change the layout", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#layout-sidebar[aria-pressed=true]")
      assert has_element?(view, "#layout-panel[aria-pressed=false]")

      view |> element("#layout-sidebar") |> render_click()
      assert has_element?(view, "#sidebar.hidden")
      assert has_element?(view, "#layout-sidebar[aria-pressed=false]")

      view |> element("#layout-panel") |> render_click()
      assert has_element?(view, "#panel")
      assert has_element?(view, "#layout-panel[aria-pressed=true]")
    end

    test "View menu toggles the explorer and terminal, with check marks", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view, "view")
      assert has_element?(view, "#menu-view-explorer .hero-check-micro")
      refute has_element?(view, "#menu-view-terminal .hero-check-micro")

      menu_click(view, "view", "terminal")
      assert has_element?(view, "#panel")
      refute has_element?(view, "#menu-view"), "menu closes after an item is chosen"
      open_menu(view, "view")
      assert has_element?(view, "#menu-view-terminal .hero-check-micro")

      menu_click(view, "view", "explorer")
      assert has_element?(view, "#sidebar.hidden")
      open_menu(view, "view")
      refute has_element?(view, "#menu-view-explorer .hero-check-micro")
    end

    test "Terminal menu creates and kills terminals", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view, "terminal")
      assert has_element?(view, "#menu-terminal-kill[disabled]")

      html = menu_click(view, "terminal", "new")
      [_, id] = Regex.run(~r/id="term-(\d+)"/, html)
      [{pid, _}] = Registry.lookup(Bee.Registry, {:terminal, String.to_integer(id)})
      ref = Process.monitor(pid)
      open_menu(view, "terminal")
      refute has_element?(view, "#menu-terminal-kill[disabled]")

      menu_click(view, "terminal", "kill")
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      refute has_element?(view, "#term-#{id}")
    end

    test "File menu is disabled without an editor and closes the active one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view, "file")
      assert has_element?(view, "#menu-file-save[disabled]")
      assert has_element?(view, "#menu-file-close[disabled]")

      open_file(view, "mix.exs")
      open_menu(view, "file")
      refute has_element?(view, "#menu-file-close[disabled]")

      menu_click(view, "file", "close")
      refute has_element?(view, "#tabs > div")
      open_menu(view, "file")
      assert has_element?(view, "#menu-file-close[disabled]")
    end
  end

  defp open_menu(view, menu), do: view |> element("#menu-#{menu}-button") |> render_click()

  defp menu_click(view, menu, item) do
    unless has_element?(view, "#menu-#{menu}"), do: open_menu(view, menu)
    view |> element("#menu-#{menu}-#{item}") |> render_click()
  end

  defp open_panel(view) do
    html = view |> element("#layout-panel") |> render_click()
    [_, id] = Regex.run(~r/id="term-(\d+)"/, html)
    String.to_integer(id)
  end

  # Output arrives in arbitrary chunks; collect until `expected` shows up.
  defp await_term_output(view, id, expected, acc \\ "") do
    assert_push_event(view, "term:data", %{id: ^id, data: data}, 2_000)
    acc = acc <> Base.decode64!(data)
    if acc =~ expected, do: acc, else: await_term_output(view, id, expected, acc)
  end

  defp open_file(view, rel) do
    view |> element("#explorer button[phx-value-path='#{rel}']") |> render_click()
  end
end

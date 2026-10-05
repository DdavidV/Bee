defmodule BeeWeb.EditorLiveTest do
  use BeeWeb.ConnCase, async: false

  # Invalid settings/keybindings are logged on purpose in some tests.
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  setup do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib/bee"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.write!(Path.join(root, "mix.exs"), "defmodule M do\nend\n")
    File.write!(Path.join(root, "lib/bee/app.ex"), "")
    File.write!(Path.join(root, "README.md"), "# Readme")

    put_user_settings(%{})

    on_exit(fn ->
      stop_buffers_under(root)
      File.rm_rf!(root)
    end)

    :ok
  end

  # Writes the user settings.json (always pinning /bin/sh, to keep the user's
  # shell and rc files out of tests) and reloads.
  defp put_user_settings(settings) do
    write_and_reload(
      Bee.Settings.user_path(),
      Jason.encode!(Map.merge(%{"terminal.integrated.shell" => "/bin/sh"}, settings)),
      &Bee.Settings.reload/0
    )
  end

  defp put_keybindings(text),
    do:
      write_and_reload(
        Bee.Commands.Keybindings.user_path(),
        text,
        &Bee.Commands.Keybindings.reload/0
      )

  defp write_and_reload(path, text, reload) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    reload.()

    on_exit(fn ->
      File.rm(path)
      reload.()
    end)
  end

  defp data(view, selector, attr) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(attr)
    |> hd()
  end

  defp json_data(view, selector, attr), do: view |> data(selector, attr) |> Jason.decode!()

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
        lang: "elixir",
        mode: "elixir"
      })

      assert has_element?(view, "#tabs [phx-value-path='#{path}']", "mix.exs")
      assert has_element?(view, "#status-lang", "Elixir")
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

      view |> element("#view-explorer") |> render_click()
      assert has_element?(view, "#sidebar.hidden")

      # the keybinding pushes the same event
      run(view, "workbench.action.toggleSidebarVisibility")
      assert has_element?(view, "#sidebar:not(.hidden)")
    end

    test "keeps expanded dirs while hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#explorer button[phx-value-path='lib']") |> render_click()

      run(view, "workbench.action.toggleSidebarVisibility")
      run(view, "workbench.action.toggleSidebarVisibility")
      assert has_element?(view, "#explorer button[phx-value-path='lib/bee']")
    end
  end

  describe "terminal" do
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

      run(view, "workbench.action.togglePanel")
      refute has_element?(view, "#panel")
      assert [{_pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})

      run(view, "workbench.action.togglePanel")
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

  describe "commands" do
    test "live commands run on the server", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.togglePanel")
      assert has_element?(view, "#panel")
    end

    test "client commands are sent to the browser, unless disabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      run(view, "workbench.action.files.save")
      refute_push_event(view, "bee:exec", _, 50)

      open_file(view, "mix.exs")
      run(view, "workbench.action.files.save")
      assert_push_event(view, "bee:exec", %{command: "workbench.action.files.save"})
    end

    test "unknown commands are reported", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "no.such.command")
      assert render(view) =~ "Command &#39;no.such.command&#39; not found"
    end

    test "the when context describes the window", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      ctx = json_data(view, "#workbench", "data-context")
      assert %{"panelVisible" => false, "sideBarVisible" => true, "activeEditor" => nil} = ctx
      assert ctx["config.editor.fontSize"] == 14

      open_file(view, "mix.exs")
      run(view, "workbench.action.togglePanel")

      assert %{
               "panelVisible" => true,
               "terminalCount" => 1,
               "activeEditor" => "mix.exs",
               "editorLangId" => "elixir",
               "resourceExtname" => ".exs"
             } = json_data(view, "#workbench", "data-context")
    end
  end

  describe "command palette" do
    test "lives in the title bar: the command center opens it in place", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#titlebar #command-center #window-title")
      assert has_element?(view, "#command-center[title='Show All Commands (Ctrl+Shift+P)']")

      view |> element("#command-center") |> render_click()
      assert has_element?(view, "#titlebar #palette #palette-input")
      refute has_element?(view, "#command-center")

      view |> element("#palette-input") |> render_keydown(%{"key" => "Escape"})
      assert has_element?(view, "#titlebar #command-center")
    end

    test "lists enabled commands with their keybindings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.showCommands")

      assert has_element?(view, "#palette-input")

      assert has_element?(
               view,
               "#palette [data-command='workbench.action.togglePanel']",
               "View: Toggle Panel Visibility"
             )

      assert has_element?(
               view,
               "#palette [data-command='workbench.action.togglePanel']",
               "Ctrl+J"
             )

      # needs an open editor
      refute has_element?(view, "#palette [data-command='workbench.action.closeActiveEditor']")
    end

    test "fuzzy filtering, arrow keys and Enter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.showCommands")

      view |> form("#palette-form", %{query: "tgl pnl"}) |> render_change()
      assert has_element?(view, "#palette [data-command='workbench.action.togglePanel']")
      refute has_element?(view, "#palette [data-command='workbench.action.terminal.new']")

      view |> form("#palette-form", %{query: "terminal"}) |> render_change()

      assert has_element?(view, "#palette li:first-child [aria-selected=true]"),
             "the first match is selected after filtering"

      view |> element("#palette-input") |> render_keydown(%{"key" => "ArrowDown"})
      view |> element("#palette-input") |> render_keydown(%{"key" => "ArrowUp"})
      view |> form("#palette-form") |> render_submit()

      refute has_element?(view, "#palette")
      assert has_element?(view, "#panel"), "first match, Create New Terminal, ran"
    end

    test "contiguous matches rank above scattered ones", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.showCommands")
      view |> form("#palette-form", %{query: "term"}) |> render_change()

      assert has_element?(
               view,
               "#palette li:first-child [data-command='workbench.action.terminal.new']"
             )

      assert has_element?(
               view,
               "#palette li:last-child [data-command='workbench.action.toggleSidebarVisibility']"
             )
    end

    test "Escape and click-away close it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.showCommands")
      view |> element("#palette-input") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#palette")

      run(view, "workbench.action.showCommands")
      render_click(view, "close_palette", %{})
      refute has_element?(view, "#palette")
    end

    test "clicking an item runs it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.showCommands")

      view
      |> element("#palette [data-command='workbench.action.toggleSidebarVisibility']")
      |> render_click()

      assert has_element?(view, "#sidebar.hidden")
      refute has_element?(view, "#palette")
    end
  end

  describe "settings" do
    test "editor, terminal and theme settings reach the browser", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.togglePanel")

      put_user_settings(%{
        "editor.fontSize" => 20,
        "editor.wordWrap" => "on",
        "terminal.integrated.fontSize" => 16,
        "workbench.colorTheme" => "light"
      })

      _ = render(view)

      assert %{"fontSize" => 20, "wordWrap" => "on", "theme" => "light"} =
               json_data(view, "#editor", "data-settings")

      assert %{"fontSize" => 16, "theme" => "light"} =
               json_data(view, "#panel [phx-hook=Terminal]", "data-settings")

      assert data(view, "#workbench", "data-theme") == "light"
    end

    test "files.exclude changes refresh the explorer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#explorer button[phx-value-path='README.md']")
      refute has_element?(view, "#explorer button[phx-value-path='_build']")

      put_user_settings(%{"files.exclude" => %{"README.md" => true, "**/_build" => false}})
      _ = render(view)

      refute has_element?(view, "#explorer button[phx-value-path='README.md']")
      assert has_element?(view, "#explorer button[phx-value-path='_build']")
    end

    test "problems are shown and open the offending file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#problems")

      put_user_settings(%{"editor.fontSize" => "big"})
      _ = render(view)
      assert has_element?(view, "#problems", "1 problem")

      view |> element("#problems") |> render_click()
      path = Bee.Settings.user_path()
      assert_push_event(view, "cm:open", %{path: ^path})
    end

    test "Open User Settings creates a documented file; saving it applies it", %{conn: conn} do
      File.rm(Bee.Settings.user_path())
      Bee.Settings.reload()
      on_exit(fn -> File.rm(Bee.Settings.user_path()) end)

      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.openSettingsJson")

      path = Bee.Settings.user_path()
      assert_push_event(view, "cm:open", %{path: ^path, text: text, lang: "jsonc", mode: "json"})
      assert text =~ "editor.fontSize"
      assert view |> element("#window-title") |> render() =~ "settings.json"

      render_hook(view, "save", %{"path" => path, "text" => ~s({"editor.fontSize": 22})})
      assert json_data(view, "#editor", "data-settings")["fontSize"] == 22
      assert has_element?(view, "#status", "Saved User Settings")
    end

    test "workspace settings override user settings", %{conn: conn} do
      put_user_settings(%{"editor.tabSize" => 4})
      on_exit(fn -> File.rm_rf!(Path.dirname(Bee.Settings.workspace_path())) end)

      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.openWorkspaceSettingsFile")
      path = Bee.Settings.workspace_path()
      assert_push_event(view, "cm:open", %{path: ^path})

      render_hook(view, "save", %{"path" => path, "text" => ~s({"editor.tabSize": 8})})
      assert json_data(view, "#editor", "data-settings")["tabSize"] == 8
    end
  end

  describe "keybindings" do
    test "user keybindings are sent to the browser and change menu shortcuts", %{conn: conn} do
      put_keybindings("""
      // mine
      [
        {"key": "ctrl+alt+j", "command": "workbench.action.togglePanel"},
        {"key": "ctrl+b", "command": "-workbench.action.toggleSidebarVisibility"},
      ]
      """)

      {:ok, view, _html} = live(conn, ~p"/")
      bindings = json_data(view, "#workbench", "data-keybindings")

      assert %{
               "key" => ["ctrl+alt+j"],
               "command" => "workbench.action.togglePanel",
               "when" => ["true"]
             } =
               List.last(bindings)

      refute Enum.any?(bindings, &(&1["command"] == "workbench.action.toggleSidebarVisibility"))

      open_menu(view, "view")

      assert has_element?(
               view,
               "#menu-view [data-command='workbench.action.togglePanel']",
               "Ctrl+Alt+J"
             )

      refute has_element?(
               view,
               "#menu-view [data-command='workbench.action.toggleSidebarVisibility']",
               "Ctrl+B"
             )
    end

    test "chords and when clauses are passed through", %{conn: conn} do
      put_keybindings(
        ~s([{"key": "ctrl+k ctrl+t", "command": "workbench.action.terminal.new", "when": "!terminalFocus && panelVisible"}])
      )

      {:ok, view, _html} = live(conn, ~p"/")

      assert %{
               "key" => ["ctrl+k", "ctrl+t"],
               "when" => ["and", ["not", ["key", "terminalFocus"]], ["key", "panelVisible"]]
             } =
               List.last(json_data(view, "#workbench", "data-keybindings"))
    end

    test "editing keybindings.json in Bee applies on save; errors become problems", %{conn: conn} do
      File.rm(Bee.Commands.Keybindings.user_path())

      on_exit(fn ->
        File.rm(Bee.Commands.Keybindings.user_path()) && Bee.Commands.Keybindings.reload()
      end)

      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.openGlobalKeybindingsFile")
      path = Bee.Commands.Keybindings.user_path()
      assert_push_event(view, "cm:open", %{path: ^path})

      render_hook(view, "save", %{
        "path" => path,
        "text" => ~s([{"key": "ctrl+nope", "command": "x"}])
      })

      assert has_element?(view, "#problems", "1 problem")

      render_hook(view, "save", %{
        "path" => path,
        "text" => ~s([{"key": "f6", "command": "workbench.action.togglePanel"}])
      })

      refute has_element?(view, "#problems")
      open_menu(view, "view")
      assert has_element?(view, "#menu-view [data-command='workbench.action.togglePanel']", "F6")
    end
  end

  describe "title bar" do
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

      assert has_element?(
               view,
               "#menu-view [data-command='workbench.action.toggleSidebarVisibility'] .hero-check-micro"
             )

      refute has_element?(
               view,
               "#menu-view [data-command='workbench.action.togglePanel'] .hero-check-micro"
             )

      menu_click(view, "view", "workbench.action.togglePanel")
      assert has_element?(view, "#panel")
      refute has_element?(view, "#menu-view"), "menu closes after an item is chosen"
      open_menu(view, "view")

      assert has_element?(
               view,
               "#menu-view [data-command='workbench.action.togglePanel'] .hero-check-micro"
             )

      menu_click(view, "view", "workbench.action.toggleSidebarVisibility")
      assert has_element?(view, "#sidebar.hidden")
      open_menu(view, "view")

      refute has_element?(
               view,
               "#menu-view [data-command='workbench.action.toggleSidebarVisibility'] .hero-check-micro"
             )
    end

    test "Terminal menu creates and kills terminals", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view, "terminal")

      assert has_element?(
               view,
               "#menu-terminal [data-command='workbench.action.terminal.kill'][disabled]"
             )

      html = menu_click(view, "terminal", "workbench.action.terminal.new")
      [_, id] = Regex.run(~r/id="term-(\d+)"/, html)
      [{pid, _}] = Registry.lookup(Bee.Registry, {:terminal, String.to_integer(id)})
      ref = Process.monitor(pid)
      open_menu(view, "terminal")

      refute has_element?(
               view,
               "#menu-terminal [data-command='workbench.action.terminal.kill'][disabled]"
             )

      menu_click(view, "terminal", "workbench.action.terminal.kill")
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      refute has_element?(view, "#term-#{id}")
    end

    test "File menu is disabled without an editor and closes the active one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      open_menu(view, "file")

      assert has_element?(
               view,
               "#menu-file [data-command='workbench.action.files.save'][disabled]"
             )

      assert has_element?(
               view,
               "#menu-file [data-command='workbench.action.closeActiveEditor'][disabled]"
             )

      open_file(view, "mix.exs")
      open_menu(view, "file")

      refute has_element?(
               view,
               "#menu-file [data-command='workbench.action.closeActiveEditor'][disabled]"
             )

      menu_click(view, "file", "workbench.action.closeActiveEditor")
      refute has_element?(view, "#tabs > div")
      open_menu(view, "file")

      assert has_element?(
               view,
               "#menu-file [data-command='workbench.action.closeActiveEditor'][disabled]"
             )
    end
  end

  describe "undo / redo" do
    test "buttons in the tab bar and the Edit menu follow what the editor reports", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#editor-actions [data-command='undo']")

      open_file(view, "mix.exs")
      assert has_element?(view, "#editor-actions [data-command='undo'][disabled]")
      assert has_element?(view, "#editor-actions [data-command='redo'][disabled]")
      assert has_element?(view, "#editor-actions [data-command='undo'][title='Undo (Ctrl+Z)']")

      assert has_element?(
               view,
               "#editor-actions [data-command='redo'][title='Redo (Ctrl+Shift+Z)']"
             )

      render_hook(view, "history_changed", %{"canUndo" => true, "canRedo" => false})
      refute has_element?(view, "#editor-actions [data-command='undo'][disabled]")
      assert has_element?(view, "#editor-actions [data-command='redo'][disabled]")

      # implemented in the browser: the server asks for it
      view |> element("#editor-actions [data-command='undo']") |> render_click()
      assert_push_event(view, "bee:exec", %{command: "undo"})

      open_menu(view, "edit")
      assert has_element?(view, "#menu-edit [data-command='redo'][disabled]", "Ctrl+Shift+Z")
      assert has_element?(view, "#menu-edit [data-command='undo']", "Ctrl+Z")
      refute has_element?(view, "#menu-edit [data-command='undo'][disabled]")
    end

    test "keybindings of client commands carry their enablement", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      bindings = json_data(view, "#workbench", "data-keybindings")

      assert %{
               "client" => true,
               "enablement" => ["key", "canUndo"],
               "when" => ["key", "editorTextFocus"]
             } =
               Enum.find(bindings, &(&1["command"] == "undo"))

      refute Map.has_key?(
               Enum.find(bindings, &(&1["command"] == "workbench.action.togglePanel")),
               "client"
             )
    end
  end

  describe "layout" do
    test "sashes resize the sidebar and the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert data(view, "#workbench", "style") =~ "--sidebar-width: 256px"
      assert has_element?(view, "#sash-sidebar[phx-hook='Sash']")

      render_hook(view, "layout_resize", %{"part" => "sidebar", "size" => 333})
      assert data(view, "#workbench", "style") =~ "--sidebar-width: 333px"

      render_hook(view, "layout_resize", %{"part" => "panel", "size" => 9999})
      assert data(view, "#workbench", "style") =~ "--panel-height: 1200px"

      # double-click: back to the default
      render_hook(view, "layout_resize", %{"part" => "sidebar", "size" => nil})
      assert data(view, "#workbench", "style") =~ "--sidebar-width: 256px"

      # no sash for a hidden sidebar
      run(view, "workbench.action.toggleSidebarVisibility")
      refute has_element?(view, "#sash-sidebar")
    end

    test "the browser's saved sizes come with the connection: no jump after connecting", %{
      conn: conn
    } do
      # before connecting: the saved sizes (applied by root.html.heex), else the defaults
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ "--sidebar-width: var(--saved-sidebar-width, 256px)"

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"layout" => %{"sidebar" => 400, "panel" => 9999}})
        |> live(~p"/")

      assert data(view, "#workbench", "style") =~ "--sidebar-width: 400px; --panel-height: 1200px"
    end

    test "pulling a sash past the minimum hides the part, keeping its size", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "layout_resize", %{"part" => "sidebar", "size" => 300})

      render_hook(view, "layout_hide", %{"part" => "sidebar"})
      assert has_element?(view, "#sidebar.hidden")
      refute has_element?(view, "#sash-sidebar")

      run(view, "workbench.action.toggleSidebarVisibility")
      assert data(view, "#workbench", "style") =~ "--sidebar-width: 300px"

      run(view, "workbench.action.togglePanel")
      assert has_element?(view, "#panel")
      render_hook(view, "layout_hide", %{"part" => "panel"})
      refute has_element?(view, "#panel")
      # already hidden: nothing happens
      render_hook(view, "layout_hide", %{"part" => "panel"})
      refute has_element?(view, "#panel")
    end
  end

  describe "search" do
    defp await(fun, tries \\ 60) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition not met")
        true -> Process.sleep(30) && await(fun, tries - 1)
      end
    end

    defp search_for(view, query) do
      view |> form("#search-form", %{query: query}) |> render_change()
      await(fn -> render(view) =~ "result" end)
    end

    test "Find in Files shows the view; results arrive grouped by file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.action.findInFiles")
      assert has_element?(view, "#sidebar-title", "Search")
      assert has_element?(view, "#search-query")
      assert_push_event(view, "search:focus", %{})

      search_for(view, "defmodule")
      assert has_element?(view, "#search-status", "1 result in 1 file")
      assert has_element?(view, "[data-search-file='mix.exs']", "mix.exs")

      assert has_element?(
               view,
               "[data-search-match='mix.exs:0'] span.bg-warning\\/35",
               "defmodule"
             )

      # case sensitivity is a toggle
      search_for(view, "DEFMODULE")
      assert has_element?(view, "#search-status", "1 result")
      view |> element("#search-view [data-command='toggleSearchCaseSensitive']") |> render_click()
      await(fn -> has_element?(view, "#search-status", "No results found") end)

      assert has_element?(
               view,
               "#search-view [data-command='toggleSearchCaseSensitive'][aria-pressed='true']"
             )
    end

    test "clicking a match opens the file and selects it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.view.search")
      search_for(view, "end")

      view |> element("[data-search-match='mix.exs:15']") |> render_click()
      path = Path.join(Bee.Workspace.root(), "mix.exs")
      assert_push_event(view, "cm:open", %{path: ^path})
      assert_push_event(view, "cm:reveal", %{path: ^path, from: 15, to: 18})
    end

    test "the selection seeds Find in Files", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      open_file(view, "mix.exs")
      path = Path.join(Bee.Workspace.root(), "mix.exs")
      render_hook(view, "selection_changed", %{"path" => path, "ranges" => [[10, 11]]})

      run(view, "workbench.action.findInFiles")
      assert has_element?(view, "#search-query[value='M']")
    end

    test "replace all writes closed files and edits open ones", %{conn: conn} do
      File.write!(Path.join(Bee.Workspace.root(), "README.md"), "# Readme\nmodule M\n")
      {:ok, view, _html} = live(conn, ~p"/")
      open_file(view, "mix.exs")

      run(view, "workbench.action.replaceInFiles")
      assert has_element?(view, "#search-replace")
      search_for(view, "M")
      view |> form("#search-form", %{query: "M", replace: "N"}) |> render_change()
      _ = render(view)

      view |> element("#search-replace-all") |> render_click()

      readme = Path.join(Bee.Workspace.root(), "README.md")
      mix = Path.join(Bee.Workspace.root(), "mix.exs")
      # case-insensitive by default: the m of Readme too
      assert File.read!(readme) == "# ReadNe\nNodule N\n"
      # open: changed in the editor (undoable), not on disk
      assert_push_event(view, "cm:edit", %{path: ^mix, text: "defNodule N do\nend\n"})
      assert File.read!(mix) == "defmodule M do\nend\n"
      assert has_element?(view, "#flash-info", "Replaced")
    end

    test "invalid regexes are reported", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      run(view, "workbench.view.search")
      run(view, "toggleSearchRegex")
      view |> form("#search-form", %{query: "(oops"}) |> render_change()
      assert has_element?(view, "#search-status .text-error", "Invalid regular expression")
    end
  end

  describe "plugins" do
    @examples Path.expand("../../../examples/plugins", __DIR__)

    setup do
      File.rm_rf!(Bee.Plugins.user_dir())
      File.mkdir_p!(Bee.Plugins.user_dir())
      Bee.Plugins.reload()

      on_exit(fn ->
        File.rm_rf!(Bee.Plugins.user_dir())
        Bee.Plugins.reload()
      end)
    end

    defp install(examples) do
      for example <- examples,
          do:
            File.cp_r!(Path.join(@examples, example), Path.join(Bee.Plugins.user_dir(), example))

      Bee.Plugins.reload()
    end

    # Plugins answer asynchronously (Bee.API messages to the LiveView).
    defp eventually(fun, tries \\ 60) do
      if fun.() do
        :ok
      else
        if tries == 0, do: flunk("condition not met")
        Process.sleep(50)
        eventually(fun, tries - 1)
      end
    end

    test "the Plugins view lists installed plugins and their problems", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#view-extensions") |> render_click()
      assert has_element?(view, "#plugins-view", "No plugins installed")
      assert has_element?(view, "#sidebar > div.hidden #explorer")

      install(["word-count"])
      File.mkdir_p!(Path.join(Bee.Plugins.user_dir(), "broken"))
      File.write!(Path.join(Bee.Plugins.user_dir(), "broken/plugin.json"), "{nope")
      Bee.Plugins.reload()

      assert has_element?(view, "#plugin-word-count", "Word Count")
      assert has_element?(view, "#plugin-word-count", "installed")
      assert has_element?(view, "#plugin-broken", "invalid")
      assert has_element?(view, "#problems", "1 problem")

      # the same button hides the sidebar again
      view |> element("#view-extensions") |> render_click()
      assert has_element?(view, "#sidebar.hidden")
    end

    test "plugin commands are in the palette and answer through Bee.API", %{conn: conn} do
      install(["word-count"])
      {:ok, view, _html} = live(conn, ~p"/")
      open_file(view, "README.md")

      run(view, "workbench.action.showCommands")
      view |> form("#palette-form", %{query: "count words"}) |> render_change()
      assert has_element?(view, "#palette-items", "Word Count: Count Words")
      view |> form("#palette-form") |> render_submit()

      eventually(fn -> render(view) =~ "1 word in README.md" end)
      assert Bee.Plugins.get("word-count").status == :active
    end

    test "a server plugin edits the open file; the edit is pushed to the editor", %{conn: conn} do
      install(["upcase"])
      {:ok, view, _html} = live(conn, ~p"/")
      open_file(view, "mix.exs")
      path = Path.join(Bee.Workspace.root(), "mix.exs")

      # "defmodule M do\nend\n": select "defmodule"
      render_hook(view, "selection_changed", %{"path" => path, "ranges" => [[0, 9]]})
      run(view, "upcase.selection")

      assert_push_event(
        view,
        "cm:edit",
        %{path: ^path, edits: [[0, 9, "DEFMODULE"]], text: text},
        3_000
      )

      assert text == "DEFMODULE M do\nend\n"
      # the editor then reports the change as usual
      render_hook(view, "doc_changed", %{"path" => path, "text" => text})
      assert has_element?(view, "#tabs button[data-confirm]")
    end

    test "browser parts are handed to the page; their messages are shown", %{conn: conn} do
      install(["insert-date", "word-count"])
      {:ok, view, _html} = live(conn, ~p"/")

      assert [%{"name" => "insert-date", "url" => "/plugins/insert-date/browser.js?v=" <> _}] =
               json_data(view, "#browser-plugins", "data-plugins")

      render_hook(view, "plugin_message", %{
        "plugin" => "insert-date",
        "level" => "error",
        "text" => "oops"
      })

      assert has_element?(view, "#flash-error", "insert-date: oops")
    end

    test "open editors switch language when a plugin contributes it", %{conn: conn} do
      File.write!(Path.join(Bee.Workspace.root(), ".env"), "A=1\n")
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_problem", %{"path" => Path.join(Bee.Workspace.root(), ".env")})
      assert_push_event(view, "cm:open", %{lang: "plaintext", mode: nil})

      install(["dotenv"])
      _ = render(view)
      assert_push_event(view, "cm:language", %{lang: "dotenv", mode: "dotenv"})
      assert has_element?(view, "#status-lang", "Dotenv")
    end

    test "a plugin view: tree, inline buttons, input box, badge and status item", %{conn: conn} do
      File.write!(
        Path.join(Bee.Workspace.root(), "notes.txt"),
        "TODO: first\nok\nFIXME: second\n"
      )

      install(["todos"])
      {:ok, view, _html} = live(conn, ~p"/")

      # its container in the activity bar, with the count as badge
      eventually(fn -> render(view) =~ ~s(id="view-todos") end)
      eventually(fn -> has_element?(view, "#view-todos", "2") end)
      assert has_element?(view, "[id^='status-item-todos-count']", "2 TODOs")

      view |> element("#view-todos") |> render_click()
      assert has_element?(view, "#sidebar-title", "TODOs")
      assert has_element?(view, "[data-item='notes.txt']", "notes.txt")
      assert has_element?(view, "[data-item='notes.txt:1']", "TODO: first")
      assert has_element?(view, "[data-item='notes.txt:3']", "FIXME: second")
      # view/title buttons in the header
      assert has_element?(view, "#sidebar [data-command='todos.refresh']")

      # a leaf runs its command with its arguments: open at the line
      view |> element("[data-item='notes.txt:3']") |> render_click()
      path = Path.join(Bee.Workspace.root(), "notes.txt")
      assert_push_event(view, "cm:open", %{path: ^path}, 3_000)
      assert_push_event(view, "cm:reveal", %{path: ^path, line: 3})

      # folding a group
      view |> element("[data-item='notes.txt']") |> render_click()
      refute has_element?(view, "[data-item='notes.txt:1']")
      view |> element("[data-item='notes.txt']") |> render_click()

      # an inline button gets the item's arguments
      view
      |> element("[data-item='notes.txt:1'] [data-command='todos.hide']")
      |> render_click()

      eventually(fn -> not has_element?(view, "[data-item='notes.txt:1']") end)
      assert has_element?(view, "#view-todos", "1")

      # the input box runs its command with the text
      view
      |> form("#view-input-todos\\.list", %{"value" => "write docs"})
      |> render_submit()

      eventually(fn ->
        File.read(Path.join(Bee.Workspace.root(), "TODO.md")) == {:ok, "- TODO: write docs\n"}
      end)

      eventually(fn -> has_element?(view, "[data-item='TODO.md:1']", "TODO: write docs") end)
    end

    test "plugins ask through the palette: quick pick and input box", %{conn: conn} do
      File.write!(Path.join(Bee.Workspace.root(), "notes.txt"), "TODO: first\nFIXME: second\n")
      install(["todos"])
      {:ok, view, _html} = live(conn, ~p"/")
      eventually(fn -> Bee.Plugins.get("todos").status == :active end)

      run(view, "todos.goTo")
      eventually(fn -> has_element?(view, "#palette [data-pick]") end)
      assert has_element?(view, "#palette-input[placeholder='Go to a TODO']")
      view |> form("#palette-form", %{query: "fixme"}) |> render_change()
      assert has_element?(view, "#palette [data-pick='1']", "FIXME: second")
      refute has_element?(view, "#palette [data-pick='0']")
      view |> form("#palette-form") |> render_submit()

      path = Path.join(Bee.Workspace.root(), "notes.txt")
      assert_push_event(view, "cm:reveal", %{path: ^path, line: 2}, 3_000)

      # with no text, todos.add asks for it
      run(view, "todos.add")
      eventually(fn -> has_element?(view, "#palette-prompt", "What needs doing?") end)
      view |> form("#palette-form", %{query: "from the palette"}) |> render_change()
      view |> form("#palette-form") |> render_submit()

      eventually(fn ->
        File.read(Path.join(Bee.Workspace.root(), "TODO.md")) ==
          {:ok, "- TODO: from the palette\n"}
      end)

      # commands for view items stay out of the palette
      run(view, "workbench.action.showCommands")
      view |> form("#palette-form", %{query: "todos"}) |> render_change()
      assert has_element?(view, "#palette [data-command='todos.goTo']")
      refute has_element?(view, "#palette [data-command='todos.open']")
    end

    test "the browser part's requests are answered by the server part", %{conn: conn} do
      File.write!(Path.join(Bee.Workspace.root(), "notes.txt"), "TODO: a\nTODO: b\n")
      install(["todos"])
      {:ok, view, _html} = live(conn, ~p"/")
      eventually(fn -> Bee.Plugins.get("todos").status == :active end)

      path = Path.join(Bee.Workspace.root(), "notes.txt")

      render_hook(view, "plugin_request", %{
        "plugin" => "todos",
        "method" => "count",
        "params" => %{"path" => path},
        "ref" => "r1"
      })

      assert_push_event(view, "plugin:reply", %{ref: "r1", result: %{file: 2, total: 2}}, 3_000)

      render_hook(view, "plugin_request", %{
        "plugin" => "todos",
        "method" => "nope",
        "ref" => "r2"
      })

      assert_push_event(view, "plugin:reply", %{ref: "r2", error: error}, 3_000)
      assert error =~ "handle_request/4"

      render_hook(view, "plugin_request", %{
        "plugin" => "insert-date",
        "method" => "x",
        "ref" => "r3"
      })

      assert_push_event(view, "plugin:reply", %{ref: "r3", error: _})
    end

    test "the asset route serves a plugin's browser module only", %{conn: conn} do
      install(["insert-date"])

      conn = get(conn, "/plugins/insert-date/browser.js")
      assert response(conn, 200) =~ "export function activate"
      assert get_resp_header(conn, "content-type") |> hd() =~ "javascript"

      assert build_conn() |> get("/plugins/insert-date/plugin.json") |> response(404)
      assert build_conn() |> get("/plugins/insert-date/../../settings.json") |> response(404)
      assert build_conn() |> get("/plugins/nope/browser.js") |> response(404)
    end
  end

  defp open_menu(view, menu), do: view |> element("#menu-#{menu}-button") |> render_click()

  defp menu_click(view, menu, command) do
    unless has_element?(view, "#menu-#{menu}"), do: open_menu(view, menu)
    view |> element("#menu-#{menu} [data-command='#{command}']") |> render_click()
  end

  # What a keybinding does: the hook pushes run_command.
  defp run(view, command), do: render_hook(view, "run_command", %{"command" => command})

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

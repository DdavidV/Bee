defmodule BeeWeb.ExtensionsTest do
  # A VS Code extension's commands, menus, keybindings and settings in the
  # window (the hello fixture, test/fixtures/extensions/hello). Its commands
  # run in the extension host (the tests tagged :node).
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :capture_log

  setup do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "notes.txt"), "some notes\n")
    File.write!(Path.join(root, "mix.exs"), "defmodule M do\nend\n")

    File.rm_rf!(Bee.Plugins.user_dir())
    Bee.Output.forget_workspace(root)
    Bee.Test.Extensions.install("hello")

    on_exit(fn ->
      File.rm_rf!(Bee.Plugins.user_dir())
      Bee.Plugins.reload()
      File.rm_rf!(Path.join(Bee.Settings.user_dir(), "extension-state"))
      File.rm(Bee.Settings.user_path())
      Bee.Settings.reload()
      File.rm_rf!(root)
    end)

    :ok
  end

  defp json_data(view, selector, attr) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(attr)
    |> hd()
    |> Jason.decode!()
  end

  defp open_file(view, rel),
    do: view |> element("#explorer button[phx-value-path='#{rel}']") |> render_click()

  # What the ContextMenus hook sends for a right-click on `selector`.
  defp right_click(view, selector, context \\ %{}) do
    render_hook(view, "open_context_menu", %{
      "menu" => view |> element(selector) |> render() |> attribute("data-menu"),
      "x" => 10,
      "y" => 20,
      "args" => json_data(view, selector, "data-menu-args"),
      "context" => context
    })
  end

  # The extension host answers asynchronously.
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(30) && eventually(fun, tries - 1)
    end
  end

  defp run(view, command, args \\ nil) do
    params = if args, do: %{"command" => command, "args" => args}, else: %{"command" => command}
    render_hook(view, "run_command", params)
  end

  defp attribute(html, name),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.attribute(name) |> hd()

  # Commands (or submenus) of the open menu, in order; of `inside` only.
  defp menu(view, inside \\ "#context-menu") do
    view
    |> element("#context-menu")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{inside} > [data-command], #{inside} > [data-submenu], #{inside} > hr")
    |> Enum.map(fn node ->
      case {LazyHTML.attribute(node, "data-command"), LazyHTML.attribute(node, "data-submenu")} do
        {[command], _} -> command
        {_, [submenu]} -> {:submenu, submenu}
        _ -> :separator
      end
    end)
  end

  test "the extension loads from its package.json, with what Bee left out" do
    assert %{kind: :vscode, status: :inactive, errors: [], warnings: warnings} =
             Bee.Plugins.get("hello")

    assert length(warnings) == 8
  end

  test "its commands are in the palette, by category and title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "run_command", %{"command" => "workbench.action.showCommands"})
    view |> element("#palette-form") |> render_change(%{"query" => ">hello"})

    html = view |> element("#palette-items") |> render()
    assert html =~ "Hello: Say Hello"
    assert html =~ "Hello: Pick a Greeting"
    assert html =~ "Ctrl+Alt+H"
    # Hidden from the palette by its commandPalette entry.
    refute html =~ "Greet This File"
    # Needs a selection.
    refute html =~ "Shout Selection"
  end

  @tag :node
  test "running one runs the extension's code", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert %{status: :inactive} = Bee.Plugins.get("hello", Bee.Workspace.root())

    run(view, "hello.sayHello")
    eventually(fn -> render(view) =~ "Hello from the hello extension" end)
    assert %{status: :active, errors: []} = Bee.Plugins.get("hello", Bee.Workspace.root())
  end

  test "the editor's right-click menu: Bee's items, the extension's, its submenu", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    # No file shown: no menu of Bee's (the browser's shows).
    refute has_element?(view, "#editor-area[data-menu]")

    open_file(view, "notes.txt")
    path = Path.join(Bee.Workspace.root(), "notes.txt")
    assert json_data(view, "#editor-area", "data-menu-args") == [path]

    right_click(view, "#editor-area")

    # "navigation" first, then the groups by name; hello.shout needs a
    # selection, hello.pick another language, and the empty submenu isn't shown.
    assert menu(view) == [
             "hello.sayHello",
             :separator,
             {:submenu, "hello.more"},
             :separator,
             "editor.action.clipboardCutAction",
             "editor.action.clipboardCopyAction",
             "editor.action.clipboardPasteAction",
             :separator,
             "workbench.action.showCommands"
           ]

    assert has_element?(view, "#context-menu [data-submenu='hello.more']", "More Greetings")

    assert menu(view, "[data-submenu='hello.more'] > [role=menu]") == [
             "hello.pick",
             :separator,
             "hello.insert"
           ]

    assert has_element?(view, "#context-menu [data-command='hello.sayHello']", "Ctrl+Alt+H")

    # With a selection (the editor's own keys come with the right-click).
    right_click(view, "#editor-area", %{"editorHasSelection" => true})
    assert "hello.shout" in menu(view)

    # An item of a submenu runs like any other.
    view |> element("#context-menu [data-command='hello.pick']") |> render_click()
    refute has_element?(view, "#context-menu")
  end

  @tag :node
  test "an extension's quick pick is asked in the palette, its answer goes back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    run(view, "hello.pick")
    eventually(fn -> has_element?(view, "#palette-items [role=option]", "Howdy") end)
    assert view |> element("#palette-input") |> render() =~ "Pick a greeting"

    view |> element("#palette-items [role=option]", "Howdy") |> render_click()
    refute has_element?(view, "#palette")

    # The extension writes the pick to the user's settings…
    eventually(fn -> Bee.Settings.get("hello.greeting") == "Howdy" end)
    # …and reads it back.
    run(view, "hello.sayHello")
    eventually(fn -> render(view) =~ "Howdy from the hello extension" end)

    # Escape: the extension gets no pick, and changes nothing.
    run(view, "hello.pick")
    eventually(fn -> has_element?(view, "#palette-items [role=option]", "Hi") end)
    view |> element("#palette-input") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#palette")
    run(view, "hello.sayHello")
    eventually(fn -> render(view) =~ "Howdy from the hello extension" end)
  end

  @tag :node
  test "a file's right-click menu gives the extension its Uri", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    right_click(view, "#explorer button[phx-value-path='notes.txt']", %{
      "explorerResourceIsFolder" => false
    })

    view |> element("#context-menu [data-command='hello.reveal']") |> render_click()
    path = Path.join(Bee.Workspace.root(), "notes.txt")
    eventually(fn -> render(view) =~ "Hello, #{path}" end)
  end

  test "the Explorer's right-click menu and the editor's buttons", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    right_click(view, "#explorer button[phx-value-path='notes.txt']", %{
      "explorerResourceIsFolder" => false
    })

    assert "hello.reveal" in menu(view)

    right_click(view, "#explorer button[phx-value-path='lib']", %{
      "explorerResourceIsFolder" => true
    })

    refute "hello.reveal" in menu(view)

    # editor/title: a codicon, and images of the extension (disabled
    # without a selection); only for .txt files.
    open_file(view, "notes.txt")
    say = view |> element("button[data-command='hello.sayHello'][title^='Say Hello']") |> render()
    assert say =~ "<svg"
    assert say =~ ~s(viewBox="0 0 16 16")

    shout = view |> element("button[data-command='hello.shout'][disabled]") |> render()
    assert shout =~ ~s(src="/plugins/hello/media/shout-light.svg")
    assert shout =~ ~s(src="/plugins/hello/media/shout-dark.svg")

    open_file(view, "mix.exs")
    refute has_element?(view, "button[data-command='hello.shout']")
  end

  test "its images are served", %{conn: conn} do
    assert conn |> get("/plugins/hello/media/shout-dark.svg") |> response(200) =~ "<svg"
    assert conn |> get("/plugins/hello/extension.js") |> response(404)
  end

  test "its keybindings reach the browser, per platform and with arguments", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    bindings = json_data(view, "#workbench", "data-keybindings")
    of = fn command -> Enum.filter(bindings, &(&1["command"] == command)) end

    assert [%{"key" => ["ctrl+alt+h"], "mac" => ["alt+meta+h"], "linux" => ["ctrl+alt+h"]} = say] =
             of.("hello.sayHello")

    refute Map.has_key?(say, "args")

    assert [
             %{
               "key" => ["ctrl+alt+u"],
               "linux" => ["ctrl+shift+alt+u"],
               "win" => ["ctrl+alt+u"],
               "when" => ["key", "editorTextFocus"]
             }
           ] = of.("hello.shout")

    assert [%{"key" => ["ctrl+alt+i"], "args" => [%{"text" => "inserted"}]}] = of.("hello.insert")
    assert [%{"key" => nil, "linux" => nil, "mac" => ["alt+meta+p"]}] = of.("hello.pick")

    # A key for one of Bee's commands.
    assert Enum.any?(of.("workbench.action.togglePanel"), &(&1["key"] == ["ctrl+alt+`"]))
  end

  @tag :node
  test "a keybinding's arguments reach the command, which edits the open file", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    open_file(view, "notes.txt")
    path = Path.join(Bee.Workspace.root(), "notes.txt")
    render_hook(view, "selection_changed", %{"path" => path, "ranges" => [[5, 5]]})

    # What the Keybindings hook pushes for a binding with arguments.
    run(view, "hello.insert", [%{"text" => "inserted "}])
    assert_push_event(view, "cm:edit", %{path: ^path, text: "some inserted notes\n"}, 3_000)
    assert Bee.Editor.Buffer.get(path).text == "some inserted notes\n"
  end

  test "its settings: defaults, validation, and defaults for other settings" do
    # Settings reloads on its own when contributions change: not waiting for that.
    Bee.Settings.reload()

    assert Bee.Settings.get("hello.greeting") == "Hello"
    # configurationDefaults, over the schema's 5.
    assert Bee.Settings.get("hello.volume") == 7
    assert Bee.Settings.get("editor.tabSize") == 3
    assert %{"**/.hello-cache" => true, "**/.git" => true} = Bee.Settings.get("files.exclude")
    assert Bee.Settings.schema()["hello.greeting"]["description"] == "What it says."

    File.mkdir_p!(Path.dirname(Bee.Settings.user_path()))

    File.write!(
      Bee.Settings.user_path(),
      ~s({"hello.volume": 12, "hello.style": "fancy", "hello.colors": {"any": "thing"}})
    )

    Bee.Settings.reload()

    assert [%{message: ~s("hello.volume": ) <> _}] = Bee.Settings.errors()
    assert Bee.Settings.get("hello.volume") == 7
    assert Bee.Settings.get("hello.style") == "fancy"
    assert Bee.Settings.get("hello.colors") == %{"any" => "thing"}

    # Gone with the extension.
    Bee.Plugins.uninstall("hello")
    File.rm!(Bee.Settings.user_path())
    Bee.Settings.reload()
    assert Bee.Settings.get("editor.tabSize") == 2
    assert Bee.Settings.get("hello.greeting") == nil
  end

  @tag :node
  test "a language extension's diagnostics: underlined in the editor, counted", %{conn: conn} do
    root = Bee.Workspace.root()
    path = Path.join(root, "a.hl")
    File.write!(path, "ok\nthis is BAD\n# TODO later\n")
    Bee.Test.Extensions.install("hello-lang")

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#problems")
    open_file(view, "a.hl")

    # Found by the extension once the file is open: sent to its editor.
    assert_push_event(
      view,
      "cm:language_diagnostics",
      %{path: ^path, diagnostics: [_ | _] = diagnostics},
      5_000
    )

    assert [
             %{
               from: %{line: 1, character: 8},
               to: %{line: 1, character: 11},
               severity: :error,
               message: "BAD is bad" <> _,
               source: "hello",
               code: "H001"
             },
             %{from: %{line: 2, character: 2}, severity: :warning, message: "something to do"}
           ] = diagnostics

    # The status bar counts them (errors first), a moment later.
    eventually(fn -> has_element?(view, "#problems", "2 problems") end)
    title = view |> element("#problems") |> render()
    assert title =~ "a.hl: line 2: BAD is bad"
    assert title =~ "a.hl: line 3: something to do"

    # Fixed in the editor: gone.
    render_hook(view, "doc_changed", %{"path" => path, "text" => "all GOOD\n"})
    assert_push_event(view, "cm:language_diagnostics", %{path: ^path, diagnostics: []}, 5_000)
    eventually(fn -> not has_element?(view, "#problems") end)

    # A file opened later gets what is known of it at once.
    render_hook(view, "doc_changed", %{"path" => path, "text" => "BAD\n"})
    eventually(fn -> has_element?(view, "#problems", "1 problem") end)
    {:ok, other, _html} = live(conn, ~p"/")
    open_file(other, "a.hl")

    assert_push_event(
      other,
      "cm:language_diagnostics",
      %{diagnostics: [%{severity: :error}]},
      5_000
    )
  end

  @tag :node
  test "language features: asked by the editor, answered by ref; go to definition", %{
    conn: conn
  } do
    root = Bee.Workspace.root()
    path = Path.join(root, "a.hl")
    other = Path.join(root, "b.hl")
    File.write!(path, "def once\ndef twice\nonce twice none\n")
    File.write!(other, "\n\ndef twice\n")
    Bee.Test.Extensions.install("hello-lang")

    {:ok, view, _html} = live(conn, ~p"/")
    open_file(view, "a.hl")
    # Nothing for the file yet; then what the extension registered.
    assert_push_event(view, "cm:language_features", %{path: ^path, features: none})
    assert none == %{}

    assert_push_event(
      view,
      "cm:language_features",
      %{path: ^path, features: %{"completion" => %{triggerCharacters: ["."]}, "hover" => _}},
      5_000
    )

    eventually(fn ->
      BeeWeb.EditorLive.context(:sys.get_state(view.pid).socket.assigns)[
        "editorHasDefinitionProvider"
      ]
    end)

    position = fn line, character -> %{"line" => line, "character" => character} end

    render_hook(view, "language_request", %{
      "ref" => "l1",
      "feature" => "hover",
      "path" => path,
      "params" => %{"position" => position.(0, 5)}
    })

    assert_push_event(
      view,
      "language:reply",
      %{ref: "l1", result: %{"contents" => ["**once**: 4 letters"]}},
      5_000
    )

    # About the text the editor sent just before.
    render_hook(view, "doc_changed", %{"path" => path, "text" => "greet.\ndef once\ndef twice\n"})

    render_hook(view, "language_request", %{
      "ref" => "l2",
      "feature" => "completion",
      "path" => path,
      "params" => %{
        "position" => position.(0, 6),
        "context" => %{"triggerKind" => 1, "triggerCharacter" => "."}
      }
    })

    assert_push_event(
      view,
      "language:reply",
      %{ref: "l2", result: %{"items" => [%{"label" => "hello"}, %{"label" => "world"}]}},
      5_000
    )

    # A feature the editor doesn't ask for this way, a file that isn't open.
    render_hook(view, "language_request", %{
      "ref" => "l3",
      "feature" => "definition",
      "path" => path
    })

    assert_push_event(view, "language:reply", %{ref: "l3", result: nil})
    render_hook(view, "language_request", %{"ref" => "l4", "feature" => "hover", "path" => other})
    assert_push_event(view, "language:reply", %{ref: "l4", result: nil})

    # One place: there. ("once" in "def once", line 2 now.)
    goto = fn line, character ->
      render_hook(view, "language_goto", %{
        "feature" => "definition",
        "path" => path,
        "position" => position.(line, character)
      })
    end

    goto.(1, 5)
    assert_push_event(view, "cm:reveal", %{path: ^path, from: 11, to: 11}, 5_000)

    # None.
    goto.(0, 2)
    eventually(fn -> has_element?(view, "#status", "No definition found") end)

    # Several: picked in the palette; the other file opens at the place.
    goto.(2, 5)
    eventually(fn -> has_element?(view, "#palette-input[placeholder='Go to definition']") end)
    html = render(view)
    assert html =~ "a.hl:3"
    assert html =~ "b.hl:3"

    index =
      Enum.find_index(
        :sys.get_state(view.pid).socket.assigns.palette.items,
        &(&1.label == "b.hl:3")
      )

    render_hook(view, "palette_pick", %{"index" => to_string(index)})
    assert_push_event(view, "cm:open", %{path: ^other}, 5_000)
    assert_push_event(view, "cm:reveal", %{path: ^other, from: 6, to: 6})
    assert has_element?(view, "#tabs [data-path='#{other}'][data-active='true']")
  end

  @tag :node
  test "Quick Fix: a problem's code actions, picked and done; the Problems section", %{
    conn: conn
  } do
    root = Bee.Workspace.root()
    path = Path.join(root, "a.hl")
    File.write!(path, "this is BAD here\n# TODO later\nfrozen\n")
    Bee.Test.Extensions.install("hello-lang")

    {:ok, view, _html} = live(conn, ~p"/")
    open_file(view, "a.hl")
    eventually(fn -> has_element?(view, "#problems", "2 problems") end)

    # The Problems section: by file, with who found each and where.
    run(view, "workbench.actions.view.problems")
    assert has_element?(view, "#problems-filter-error", "Errors 1")
    assert has_element?(view, "#problems-filter-warning", "Warnings 1")
    assert has_element?(view, "[data-problem-file='#{path}'] h3", "a.hl")

    assert has_element?(view, "[data-problem='0'][data-severity='error']", "BAD is bad")
    assert has_element?(view, "[data-problem='0']", "hello (H001)")
    assert has_element?(view, "[data-problem='0']", "[Ln 1, Col 9]")
    refute has_element?(view, "[data-problem='0']", "Use GOOD instead")
    assert has_element?(view, "[data-problem='1'][data-severity='warning']", "something to do")

    view |> element("#problems-filter-warning") |> render_click()
    refute has_element?(view, "[data-severity='warning']")
    assert has_element?(view, "[data-severity='error']")

    # A problem: its place in the file.
    view |> element("[data-problem='0']") |> render_click()
    assert_push_event(view, "cm:reveal", %{path: ^path, from: 8, to: 8})

    # Quick Fix there: what can be done, the preferred first.
    range = fn line ->
      %{
        "from" => %{"line" => line, "character" => 0},
        "to" => %{"line" => line, "character" => 20}
      }
    end

    render_hook(view, "language_code_actions", %{"path" => path, "range" => range.(0)})
    eventually(fn -> has_element?(view, "#palette-input[placeholder='Quick Fix…']") end)
    assert has_element?(view, "#palette li:nth-child(1) [data-pick]", "Replace with GOOD")
    assert has_element?(view, "#palette li:nth-child(1)", "preferred")
    assert has_element?(view, "#palette li:nth-child(2) [data-pick]", "Shout the line")
    render_hook(view, "palette_run", %{})

    assert_push_event(
      view,
      "cm:edit",
      %{path: ^path, text: "this is GOOD here\n# TODO later\nfrozen\n"},
      5_000
    )

    eventually(fn -> has_element?(view, "#problems", "1 problem") end)

    # One that can't be done says why.
    render_hook(view, "language_code_actions", %{"path" => path, "range" => range.(2)})
    eventually(fn -> has_element?(view, "#palette [data-pick]", "Thaw") end)
    assert render(view) =~ "can&#39;t be done: too cold"

    index =
      Enum.find_index(
        :sys.get_state(view.pid).socket.assigns.palette.items,
        &(&1.label == "Thaw")
      )

    render_hook(view, "palette_pick", %{"index" => to_string(index)})
    assert render(view) =~ "Thaw: too cold"

    # Nothing to do on an empty line.
    render_hook(view, "doc_changed", %{"path" => path, "text" => "\n"})
    render_hook(view, "language_code_actions", %{"path" => path, "range" => range.(0)})
    eventually(fn -> has_element?(view, "#status", "No code actions available") end)
  end

  @tag :node
  test "references in the panel, Rename Symbol, and Go to Symbol", %{conn: conn} do
    root = Bee.Workspace.root()
    path = Path.join(root, "a.hl")
    other = Path.join(root, "b.hl")
    File.write!(path, "def once\n  var inner\n    once and once\ndef last\n")
    File.write!(other, "def elsewhere\nuses once\n")
    Bee.Test.Extensions.install("hello-lang")

    {:ok, view, _html} = live(conn, ~p"/")
    open_file(view, "a.hl")

    eventually(fn ->
      BeeWeb.EditorLive.context(:sys.get_state(view.pid).socket.assigns)[
        "editorHasRenameProvider"
      ]
    end)

    position = fn line, character -> %{"line" => line, "character" => character} end

    # Find All References: the panel's section, by file, each with its line.
    render_hook(view, "language_goto", %{
      "feature" => "references",
      "path" => path,
      "position" => position.(0, 5)
    })

    eventually(fn ->
      has_element?(view, "#panel-body-references:not(.invisible) #references-count")
    end)

    assert has_element?(view, "#references-count", "4 references in 2 files")
    assert has_element?(view, "[data-reference-file='#{path}'] h3", "a.hl")
    assert has_element?(view, "[data-reference-file='#{path}'] [data-reference='0']", "def once")
    assert has_element?(view, "[data-reference-file='#{path}'] [data-reference='1'] mark", "once")

    assert has_element?(
             view,
             "[data-reference-file='#{other}'] [data-reference='3']",
             "uses once"
           )

    # (Its line's indentation is left out.)
    html = view |> element("[data-reference='2']") |> render()
    assert html =~ ~r/>once and <mark[^>]*>once<\/mark></

    # A row: there, in its file.
    view |> element("[data-reference='3']") |> render_click()
    assert_push_event(view, "cm:open", %{path: ^other}, 5_000)
    assert_push_event(view, "cm:reveal", %{path: ^other, from: 19, to: 19})
    view |> element("#tabs [data-path='#{path}']") |> render_click()

    # Rename Symbol: asked for the new name, the old one filled in.
    render_hook(view, "language_rename", %{"path" => path, "position" => position.(2, 5)})
    eventually(fn -> has_element?(view, "#palette-input[value='once']") end)
    assert render(view) =~ "Rename Symbol: a new name for once"
    render_hook(view, "palette_filter", %{"query" => "twice"})
    render_hook(view, "palette_run", %{})

    # Open files get the edits in their editors (undoable); the status says how much.
    assert_push_event(
      view,
      "cm:edit",
      %{path: ^path, text: "def twice\n  var inner\n    twice and twice\ndef last\n"},
      5_000
    )

    assert_push_event(view, "cm:edit", %{path: ^other, text: "def elsewhere\nuses twice\n"})

    eventually(fn ->
      has_element?(view, "#status", "Renamed once to twice: 4 places in 2 files")
    end)

    # Dismissed, or the same name: nothing.
    render_hook(view, "language_rename", %{"path" => path, "position" => position.(0, 5)})
    eventually(fn -> has_element?(view, "#palette-input[value='twice']") end)
    render_click(view, "close_palette", %{})
    refute_push_event(view, "cm:edit", %{}, 200)

    # Go to Symbol in Editor: the file's outline, nested ones indented.
    run(view, "workbench.action.gotoSymbol")
    eventually(fn -> has_element?(view, "#palette [data-symbol='inner']") end)
    assert has_element?(view, "#palette li:nth-child(1) [data-symbol='twice']", "function")
    assert has_element?(view, "#palette [data-symbol='inner']", "line 2")
    assert has_element?(view, "#palette [data-symbol='last']")
    render_hook(view, "palette_filter", %{"query" => "@la"})
    refute has_element?(view, "#palette [data-symbol='inner']")
    render_hook(view, "palette_run", %{})
    assert_push_event(view, "cm:reveal", %{path: ^path, from: 46, to: 46})

    # In Workspace: asked for each query; picked from another file.
    run(view, "workbench.action.showAllSymbols")
    render_hook(view, "palette_filter", %{"query" => "#else"})
    eventually(fn -> has_element?(view, "#palette [data-symbol='elsewhere']", "b.hl:1") end)
    refute has_element?(view, "#palette [data-symbol='last']")
    render_hook(view, "palette_run", %{})
    assert_push_event(view, "cm:reveal", %{path: ^other, from: 4, to: 4})
    assert has_element?(view, "#tabs [data-path='#{other}'][data-active='true']")
  end

  @tag :node
  test "formatting: by command, of the selection, and on save", %{conn: conn} do
    root = Bee.Workspace.root()
    path = Path.join(root, "f.hl")
    File.write!(path, "one   two\nthree    four\n")
    Bee.Test.Extensions.install("hello-lang")

    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "run_command", %{
      "command" => "bee.openFile",
      "args" => Jason.encode!([path])
    })

    assert_push_event(view, "cm:open", %{path: ^path})

    eventually(fn ->
      BeeWeb.EditorLive.context(:sys.get_state(view.pid).socket.assigns)[
        "editorHasDocumentFormattingProvider"
      ]
    end)

    # Format Selection: the lines of the selection (the second, here).
    render_hook(view, "selection_changed", %{"path" => path, "ranges" => [[12, 15]]})
    run(view, "editor.action.formatSelection")

    assert_push_event(
      view,
      "cm:edit",
      %{path: ^path, text: "one   two\nthree four\n", edits: [[10, 23, "three four"]]},
      5_000
    )

    # Format Document: the edits go to the editor, undoable; unsaved.
    run(view, "editor.action.formatDocument")
    assert_push_event(view, "cm:edit", %{path: ^path, text: "one two\nthree four\n"}, 5_000)
    assert File.read!(path) == "one   two\nthree    four\n"

    # Saving doesn't format, unless asked to.
    render_hook(view, "save", %{"path" => path, "text" => "a   b\n"})
    assert File.read!(path) == "a   b\n"

    Bee.Settings.update(:user, "editor.formatOnSave", fn _ -> true end)
    eventually(fn -> :sys.get_state(view.pid).socket.assigns.settings["editor.formatOnSave"] end)
    render_hook(view, "save", %{"path" => path, "text" => "c   d  \n"})
    assert_push_event(view, "cm:edit", %{path: ^path, text: "c d\n"}, 5_000)
    eventually(fn -> File.read!(path) == "c d\n" end)
    eventually(fn -> has_element?(view, "#status", "Saved f.hl") end)

    # For one language only: its block in the settings.
    File.write!(
      Bee.Settings.user_path(),
      ~s({"editor.formatOnSave": false, "[hellolang]": {"editor.formatOnSave": true, "editor.tabSize": 7}})
    )

    Bee.Settings.reload()
    render_hook(view, "save", %{"path" => path, "text" => "e   f\n"})
    assert_push_event(view, "cm:edit", %{path: ^path, text: "e f\n"}, 5_000)
    eventually(fn -> File.read!(path) == "e f\n" end)
    # (The formatter is told the language's tab size.)
    eventually(fn -> "formatting with tabSize 7" in Bee.Extensions.Host.log(root) end)

    # A file nobody formats is saved as it is, at once.
    notes = Path.join(root, "notes.txt")
    open_file(view, "notes.txt")
    render_hook(view, "save", %{"path" => notes, "text" => "x   y\n"})
    assert File.read!(notes) == "x   y\n"
  end

  @tag :node
  test "a webview panel: its tab and frame, messages both ways, closing", %{conn: conn} do
    root = Bee.Workspace.root()
    Bee.Test.Extensions.install("hello-webview")
    on_exit(fn -> Bee.Webviews.clear(root) end)

    {:ok, view, _html} = live(conn, ~p"/")
    run(view, "helloWebview.open")
    eventually(fn -> has_element?(view, "#tabs [data-path^='webview:'][data-active='true']") end)
    [panel] = Bee.Webviews.list(root)
    path = "webview:" <> panel.id

    # Its frame: the panel's page by its token, apart from Bee's page.
    eventually(fn ->
      has_element?(
        view,
        "#webview-#{panel.id}:not(.hidden) iframe[src='/webview/#{panel.token}/?v=1'][sandbox^='allow-scripts']"
      )
    end)

    refute render(view) =~ "allow-same-origin"
    # (Posted by the extension as it opened the panel.)
    assert_push_event(view, "webview:message", %{message: %{"type" => "hello"}}, 5_000)

    # From its page to the extension, and back; the tab is renamed.
    render_hook(view, "webview_message", %{
      "id" => panel.id,
      "message" => %{"type" => "ping", "n" => 2}
    })

    id = panel.id

    assert_push_event(
      view,
      "webview:message",
      %{id: ^id, message: %{"type" => "pong", "n" => 2}},
      5_000
    )

    eventually(fn -> has_element?(view, "#tabs [data-path='#{path}']", "Pong 2") end)

    # What its page keeps is there for the page loaded again.
    render_hook(view, "webview_state", %{"id" => id, "state" => %{"pings" => 2}})
    eventually(fn -> Bee.Webviews.get(root, id).state == %{"pings" => 2} end)
    run(view, "helloWebview.update")
    eventually(fn -> has_element?(view, "#webview-#{id} iframe[src$='?v=2']") end)

    # Another window of the workspace shows the panel too.
    {:ok, other, _html} = live(conn, ~p"/")
    assert has_element?(other, "#tabs [data-path='#{path}']", "Pong 2")

    # Another tab: the frame stays, hidden; its extension is told.
    open_file(view, "notes.txt")
    assert has_element?(view, "#webview-#{id}.hidden iframe")
    eventually(fn -> "webview active false" in Bee.Extensions.Host.log(root) end)

    # Closed: the extension's panel is disposed of, everywhere.
    run(view, "workbench.action.closeEditor", [path])
    eventually(fn -> Bee.Webviews.list(root) == [] end)
    refute has_element?(view, "#webview-#{id}")
    eventually(fn -> not has_element?(other, "#tabs [data-path='#{path}']") end)
    assert "webview disposed" in Bee.Extensions.Host.log(root)

    # An address for the user's browser.
    run(view, "helloWebview.external")
    assert_push_event(view, "open-external", %{url: "https://example.com/from-extension"}, 5_000)
  end

  @tag :node
  test "the panel's Output section shows what extensions write, a channel at a time", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    # Nothing yet.
    run(view, "workbench.action.output.toggleOutput")
    assert has_element?(view, "#panel-body-output #output-channel[disabled]", "No output yet")
    render_hook(view, "output_ready", %{})
    assert_push_event(view, "output:set", %{channel: nil, text: ""})
    run(view, "workbench.action.closePanel")

    # (hello.output isn't in its package.json: registered once its code runs.)
    run(view, "hello.sayHello")
    eventually(fn -> render(view) =~ "from the hello extension" end)

    # channel.show() of an extension opens the section on its channel.
    run(view, "hello.output")
    assert_push_event(view, "output:set", %{channel: "Hello", text: "first line\n"}, 5_000)

    assert has_element?(
             view,
             "#panel-body-output:not(.invisible) #output-text[data-channel='Hello']"
           )

    assert has_element?(view, "#output-channel option[selected]", "Hello")

    # What comes then is added to it.
    run(view, "hello.output", ["second", false])
    assert_push_event(view, "output:append", %{channel: "Hello", text: "second\n"}, 5_000)

    # Another channel: picked, its text so far is sent; the other's isn't any more.
    run(view, "hello.log")
    eventually(fn -> has_element?(view, "#output-channel option", "Hello Log") end)
    view |> element("#output-channels") |> render_change(%{"channel" => "Extension Host"})

    assert_push_event(view, "output:set", %{channel: "Extension Host", text: "printed by hello\n"})

    run(view, "hello.output", ["third", false])
    refute_push_event(view, "output:append", %{text: "third\n"}, 300)

    # Clear Output (the section's button) empties the shown channel.
    view |> element("#output-channels") |> render_change(%{"channel" => "Hello"})

    assert_push_event(view, "output:set", %{channel: "Hello", text: "first line\nsecond\nthird\n"})

    assert has_element?(view, "#panel button[data-command='workbench.output.action.clearOutput']")
    run(view, "workbench.output.action.clearOutput")
    assert_push_event(view, "output:set", %{channel: "Hello", text: ""}, 2_000)
    assert Bee.Output.get(Bee.Workspace.root(), "Hello Log") != ""
  end

  test "its details page lists commands, settings and what isn't used", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "run_command", %{"command" => "extension.open", "args" => ["hello"]})

    html = render(view)
    assert html =~ "Hello Extension"
    assert html =~ "8 part(s) of this extension aren&#39;t used"
    assert html =~ "hello bad id"
  end
end

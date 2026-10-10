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

  test "its details page lists commands, settings and what isn't used", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "run_command", %{"command" => "extension.open", "args" => ["hello"]})

    html = render(view)
    assert html =~ "Hello Extension"
    assert html =~ "8 part(s) of this extension aren&#39;t used"
    assert html =~ "hello bad id"
  end
end

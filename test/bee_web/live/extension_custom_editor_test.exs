defmodule BeeWeb.ExtensionCustomEditorTest do
  # Custom editors of VS Code extensions (window.registerCustomEditorProvider):
  # the hello-editor fixture (test/fixtures/extensions/hello-editor), whose
  # code runs in the extension host (Node.js), in the window.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bee.CustomEditors
  alias Bee.Editor.Buffer

  @moduletag :capture_log

  setup do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "deck.cards"), "ace\nking\n")
    File.write!(Path.join(root, "score.tally"), "3\n")
    File.write!(Path.join(root, "notes.md"), "# Notes\n")
    File.write!(Path.join(root, "x.broken"), "x")

    File.rm_rf!(Bee.Plugins.user_dir())
    Bee.Test.Extensions.install("hello-editor")

    on_exit(fn ->
      Bee.Webviews.clear(root)
      File.rm_rf!(Bee.Plugins.user_dir())
      Bee.Plugins.reload()

      for {path, pid} <-
            Registry.select(Bee.Registry, [
              {{{:buffer, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
            ]),
          String.starts_with?(path, root <> "/"),
          do: DynamicSupervisor.terminate_child(Bee.BufferSup, pid)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp eventually(fun, tries \\ 250) do
    cond do
      result = fun.() -> result
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp click_file(view, rel),
    do: view |> element("#explorer button[phx-value-path='#{rel}']") |> render_click()

  defp run(view, command, args \\ []) do
    render_hook(view, "run_command", %{"command" => command, "args" => Jason.encode!(args)})
  end

  defp picks(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#palette [role=option]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp pick(view, label),
    do: view |> element("#palette [role=option]", label) |> render_click()

  defp tab(path), do: "[data-tabs] [data-tab][data-path='#{path}']"

  # The panel that is the page of `path`'s custom editor, once its
  # extension drew it.
  defp panel(root, path) do
    eventually(fn ->
      Enum.find(
        Bee.Webviews.list(root),
        &((&1.custom && &1.custom.path == path) and &1.html != "")
      )
    end)
  end

  # A message from the page, as the Webview hook sends it.
  defp from_page(view, id, type),
    do: render_hook(view, "webview_message", %{"id" => id, "message" => %{"type" => type}})

  test "an extension's customEditors: the files they are for, their names" do
    assert CustomEditors.extension_editor("helloEditor.cards") ==
             %{plugin: "hello-editor", view_type: "helloEditor.cards"}

    assert CustomEditors.for_file("/ws/deck.cards") == "helloEditor.cards"
    assert CustomEditors.for_file("/ws/score.TALLY") == "helloEditor.tally"
    # Only an option.
    assert CustomEditors.for_file("/ws/notes.md") == nil

    assert CustomEditors.choices("/ws/notes.md") == [
             %{id: "default", label: "Text Editor"},
             %{id: "helloEditor.cards", label: "Cards"}
           ]

    # An entry without files is left out, with a note.
    refute CustomEditors.available?("helloEditor.nothing")
    assert Enum.any?(Bee.Plugins.get("hello-editor").warnings, &(&1 =~ "customEditors"))
  end

  @tag :node
  test "a text file in its editor: drawn from its document, edited through it, saved", %{
    conn: conn,
    root: root
  } do
    path = Path.join(root, "deck.cards")
    {:ok, view, _html} = live(conn, ~p"/")
    click_file(view, "deck.cards")

    assert has_element?(view, tab(path) <> "[data-active=true]", "deck.cards")
    refute_push_event(view, "cm:open", %{path: ^path})

    %{id: id, token: token} = panel = panel(root, path)
    assert %{custom: %{view_type: "helloEditor.cards", text?: true}, scripts?: true} = panel

    # Its page, in the file's tab.
    eventually(fn ->
      has_element?(
        view,
        "[data-custom-editor='helloEditor.cards'] #webview-#{id}:not(.hidden) iframe[src^='/webview/#{token}/']"
      )
    end)

    from_page(view, id, "ready")

    assert_push_event(
      view,
      "webview:message",
      %{
        id: ^id,
        message: %{"name" => "cards of deck.cards", "cards" => "ace\nking", "count" => "2 cards"}
      },
      5_000
    )

    # Its button: the extension edits the document, which is Bee's buffer.
    from_page(view, id, "add")
    assert_push_event(view, "webview:message", %{message: %{"count" => "3 cards"}}, 5_000)
    assert Buffer.get(path).text == "ace\nking\ncard 3\n"
    eventually(fn -> has_element?(view, tab(path) <> "[data-dirty=true]") end)
    assert File.read!(path) == "ace\nking\n"

    # Save: with no text editor shown, the hook asks the window.
    render_hook(view, "save_active", %{})
    assert File.read!(path) == "ace\nking\ncard 3\n"
    refute has_element?(view, tab(path) <> "[data-dirty=true]")

    # Typed in a text editor of the same file, beside it: the page follows.
    run(view, "workbench.action.reopenWithEditor")
    assert picks(view) |> Enum.take(2) == ["Text Editor", "Cards Active and Default"]
    render_hook(view, "close_palette", %{})

    Buffer.update(path, "ace\n")
    assert_push_event(view, "webview:message", %{message: %{"count" => "1 cards"}}, 5_000)
  end

  @tag :node
  test "closing the tab disposes of the editor; Open With… brings the text editor", %{
    conn: conn,
    root: root
  } do
    path = Path.join(root, "deck.cards")
    {:ok, view, _html} = live(conn, ~p"/")
    click_file(view, "deck.cards")
    %{id: id} = panel(root, path)

    run(view, "workbench.action.reopenWithEditor")
    pick(view, "Text Editor")
    assert_push_event(view, "cm:open", %{path: ^path, text: "ace\nking\n"})
    refute has_element?(view, "[data-custom-editor]")
    eventually(fn -> Bee.Webviews.get(root, id) == nil end)

    # And back: a new page.
    run(view, "workbench.action.reopenWithEditor")
    pick(view, "Cards")
    %{id: again} = panel(root, path)
    assert again != id
    eventually(fn -> has_element?(view, "#webview-#{again} iframe") end)

    run(view, "workbench.action.closeActiveEditor")
    refute has_element?(view, "[data-tab]")
    eventually(fn -> Bee.Webviews.get(root, again) == nil end)
    eventually(fn -> Registry.lookup(Bee.Registry, {:buffer, path}) == [] end)
  end

  @tag :node
  test "an option: a markdown file opens as text, and in the editor when asked", %{
    conn: conn,
    root: root
  } do
    path = Path.join(root, "notes.md")
    {:ok, view, _html} = live(conn, ~p"/")
    click_file(view, "notes.md")
    assert_push_event(view, "cm:open", %{path: ^path})

    run(view, "workbench.action.reopenWithEditor")
    pick(view, "Cards")
    %{id: id} = panel(root, path)
    from_page(view, id, "ready")
    assert_push_event(view, "webview:message", %{message: %{"cards" => "# Notes"}}, 5_000)
  end

  @tag :node
  test "a document of the provider's: changed, saved by it, gone with its editor", %{
    conn: conn,
    root: root
  } do
    path = Path.join(root, "score.tally")
    {:ok, view, _html} = live(conn, ~p"/")
    click_file(view, "score.tally")
    %{id: id} = panel = panel(root, path)
    assert %{custom: %{view_type: "helloEditor.tally", text?: false}} = panel

    from_page(view, id, "ready")
    assert_push_event(view, "webview:message", %{message: %{"count" => "tally 3"}}, 5_000)

    from_page(view, id, "bump")
    assert_push_event(view, "webview:message", %{message: %{"count" => "tally 4"}}, 5_000)
    eventually(fn -> has_element?(view, tab(path) <> "[data-dirty=true]") end)
    assert File.read!(path) == "3\n"

    render_hook(view, "save_active", %{})
    eventually(fn -> File.read!(path) == "4\n" end)
    eventually(fn -> not has_element?(view, tab(path) <> "[data-dirty=true]") end)

    # The extension disposes of its panel: the tab closes, the document too.
    from_page(view, id, "close")
    eventually(fn -> not has_element?(view, tab(path)) end)
    eventually(fn -> File.exists?(path <> ".closed") end)
  end

  @tag :node
  test "an editor that can't open the file says so in its page", %{conn: conn, root: root} do
    path = Path.join(root, "x.broken")
    {:ok, view, _html} = live(conn, ~p"/")
    click_file(view, "x.broken")
    panel = panel(root, path)

    assert panel.html =~ "The editor could not open this file: can't &lt;read&gt; it"
    assert has_element?(view, "#webview-#{panel.id} iframe")
  end
end

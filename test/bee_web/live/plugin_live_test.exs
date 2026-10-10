defmodule BeeWeb.PluginLiveTest do
  # Plugins' own LiveViews (Bee.Plugin.LiveView) in the window: the
  # todos-live example's view and editor tab.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bee.Plugins

  @moduletag :capture_log
  @examples Path.expand("../../../examples/plugins", __DIR__)

  setup do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "# TODO: write the docs\n# FIXME: off by one\n")
    File.write!(Path.join(root, "notes.md"), "- TODO buy milk\n")

    File.rm_rf!(Plugins.user_dir())
    File.mkdir_p!(Plugins.user_dir())
    File.cp_r!(Path.join(@examples, "todos-live"), Path.join(Plugins.user_dir(), "todos-live"))
    Plugins.reload()

    on_exit(fn ->
      File.rm_rf!(Plugins.user_dir())
      Plugins.reload()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  defp eventually(fun, tries \\ 150) do
    cond do
      result = fun.() -> result
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp run(view, command, args \\ nil) do
    params = if args, do: %{"command" => command, "args" => args}, else: %{"command" => command}
    render_hook(view, "run_command", params)
  end

  # The plugin's LiveView of view or editor `id`, once it is mounted.
  defp child(view, id) do
    eventually(fn ->
      render(view)
      Enum.find(live_children(view), &(render(&1) =~ id))
    end)
  end

  defp show_view(view) do
    render_hook(view, "show_view", %{"container" => "todos-live"})
    child(view, "todos-live-list")
  end

  test "the manifest's LiveViews are the plugin's own modules" do
    plugin = Plugins.get("todos-live")
    # Not loaded yet: its code starts with the plugin.
    assert :error = Plugins.live_module(plugin, "TodosLive.ListLive")

    :ok = Plugins.activate("todos-live", Bee.Workspace.root())
    {:ok, _} = Bee.Workspace.open(Bee.Workspace.root())
    eventually(fn -> Plugins.get("todos-live", Bee.Workspace.root()).status == :active end)

    assert {:ok, TodosLive.ListLive} = Plugins.live_module(plugin, "TodosLive.ListLive")
    # Its module, but not a LiveView; someone else's module; no module at all.
    assert :error = Plugins.live_module(plugin, "TodosLive")
    assert :error = Plugins.live_module(plugin, "BeeWeb.EditorLive")
    assert :error = Plugins.live_module(plugin, "TodosLive.Nope")
  end

  test "a view drawn by the plugin's LiveView", %{conn: conn, root: root} do
    {:ok, view, _html} = live(conn, ~p"/")
    list = show_view(view)

    html = render(list)
    assert html =~ "write the docs"
    assert html =~ "off by one"
    assert html =~ "buy milk"
    assert html =~ ~s(phx-hook="TodosLiveFilter")
    # The window draws it in the view's pane, not from Bee.API.set_view data.
    assert has_element?(view, "#view-todosLive\\.list [data-plugin-live='todosLive.list']")

    # Its own events and state.
    html = list |> element("form") |> render_change(%{"filter" => "MILK"})
    assert html =~ "buy milk"
    refute html =~ "off by one"
    assert list |> element("form") |> render_change(%{"filter" => "zzz"}) =~ "No TODO matches."
    list |> element("form") |> render_change(%{"filter" => ""})

    # A click runs a command of the plugin's in the window: the file opens.
    list |> element("li", "off by one") |> render_click()
    path = Path.join(root, "lib/a.ex")
    eventually(fn -> has_element?(view, "#tabs [data-path='#{path}']") end)
    assert_push_event(view, "cm:reveal", %{path: ^path, line: 2})
  end

  test "the server part's messages reach the LiveView", %{conn: conn, root: root} do
    {:ok, view, _html} = live(conn, ~p"/")
    list = show_view(view)
    refute render(list) =~ "call mum"

    File.write!(Path.join(root, "notes.md"), "- TODO buy milk\n- TODO call mum\n")
    run(view, "todosLive.refresh")
    eventually(fn -> render(list) =~ "call mum" end)
  end

  test "an editor tab drawn by the plugin's LiveView", %{conn: conn, root: root} do
    {:ok, view, _html} = live(conn, ~p"/")
    run(view, "todosLive.openBoard")

    eventually(fn ->
      has_element?(view, "#tabs [data-path='live:todos-live/todosLive.board']")
    end)

    assert has_element?(view, "#tabs [data-active=true]", "TODO Board")
    board = child(view, "todos-live-board")

    # Its template is the .html.heex file next to the module.
    html = render(board)
    assert html =~ "3 in #{Path.basename(root)}, 0 ticked off"
    assert board |> element("[data-column=TODO] h2") |> render() =~ "2"
    assert board |> element("[data-column=FIXME]") |> render() =~ "off by one"

    assert board |> element("input[phx-value-id='lib/a.ex:1']") |> render_click() =~
             "1 ticked off"

    # Another tab over it: it stays mounted, with its state.
    view |> element("#explorer button[phx-value-path='notes.md']") |> render_click()
    assert has_element?(view, "[data-live-editor='todosLive.board'].hidden")
    assert render(board) =~ "1 ticked off"

    # Running the command again shows the open tab.
    run(view, "todosLive.openBoard")
    assert has_element?(view, "#tabs [data-active=true]", "TODO Board")
    refute has_element?(view, "[data-live-editor='todosLive.board'].hidden")
    assert length(live_children(view)) == 1

    # Closing the tab ends it.
    run(view, "workbench.action.closeEditor", ["live:todos-live/todosLive.board"])
    refute has_element?(view, "[data-live-editor]")
    eventually(fn -> live_children(view) == [] end)
  end

  test "its stylesheet is loaded by the page, and served", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = view |> element("link[data-plugin-style='todos-live']") |> render()
    [_, href] = Regex.run(~r/href="([^"]+)"/, html)
    assert href =~ ~r{^/plugins/todos-live/style\.css\?v=\d+$}

    response = get(conn, href)
    assert response(response, 200) =~ ".todos-live"
    assert get_resp_header(response, "content-type") == ["text/css; charset=utf-8"]
    # Its sources aren't.
    assert conn |> get("/plugins/todos-live/lib/todos_live.ex") |> response(404)
  end

  test "a reloaded plugin's LiveView is mounted afresh", %{conn: conn, root: root} do
    {:ok, view, _html} = live(conn, ~p"/")
    list = show_view(view)
    old = list.pid

    file = Path.join([Plugins.user_dir(), "todos-live", "lib/todos_live/list_live.ex"])
    File.write!(file, String.replace(File.read!(file), "Filter TODOs", "Find a TODO"))
    Plugins.reload("todos-live")

    new =
      eventually(fn ->
        render(view)
        Enum.find(live_children(view), &(&1.pid != old and render(&1) =~ "Find a TODO"))
      end)

    assert render(new) =~ "write the docs"
    assert %{status: :active} = Plugins.get("todos-live", root)
  end

  test "a manifest's LiveView needs a server part, and must be the plugin's" do
    dir = Path.join(Plugins.user_dir(), "no-server")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "plugin.json"),
      Jason.encode!(%{
        name: "no-server",
        contributes: %{editors: [%{id: "x.editor", title: "X", live: "X.Live"}]}
      })
    )

    Plugins.reload("no-server")
    assert %{status: :invalid, errors: [%{message: message}]} = Plugins.get("no-server")
    assert message =~ ~s|a LiveView ("live") needs a plugin with a "server" part|
  end
end

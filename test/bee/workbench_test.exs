defmodule Bee.WorkbenchTest do
  use ExUnit.Case, async: true

  alias Bee.Workbench

  @root "/ws"

  defp wb, do: Workbench.new(@root)

  defp with_editors(paths) do
    Enum.reduce(paths, wb(), fn rel, wb ->
      path = Path.join(@root, rel)
      lang = Bee.Languages.detect(path, root: @root, associations: %{})
      Workbench.editor_opened(wb, path, false, lang)
    end)
  end

  describe "editors" do
    test "opening a closed file asks for it; opening an open one activates it" do
      assert {%{tabs: []}, [{:open_file, "/ws/a"}]} = Workbench.open_editor(wb(), "/ws/a")

      wb = with_editors(["a", "b"])
      assert wb.active == "/ws/b"

      assert {%{active: "/ws/a"}, [{:push, "cm:activate", %{path: "/ws/a"}}]} =
               Workbench.open_editor(wb, "/ws/a")
    end

    test "closing the active editor activates its right neighbour, else the left one" do
      wb = with_editors(["a", "b", "c"]) |> Workbench.activate_editor("/ws/b") |> elem(0)

      assert {%{tabs: [%{path: "/ws/a"}, %{path: "/ws/c"}], active: "/ws/c"}, effects} =
               Workbench.close_editor(wb, "/ws/b")

      assert effects == [
               {:close_buffer, "/ws/b"},
               {:push, "cm:close", %{path: "/ws/b"}},
               {:push, "cm:activate", %{path: "/ws/c"}}
             ]

      {wb, _} = Workbench.close_editor(with_editors(["a", "b"]), "/ws/b")
      assert wb.active == "/ws/a"

      {wb, _} = Workbench.close_editor(with_editors(["a"]), "/ws/a")
      assert wb.active == nil
    end

    test "closing an inactive editor keeps the active one; unknown paths are ignored" do
      wb = with_editors(["a", "b"])
      assert {%{active: "/ws/b"}, [_, _]} = Workbench.close_editor(wb, "/ws/a")
      assert Workbench.close_editor(wb, "/ws/zzz") == wb
    end

    test "dirty flags" do
      wb = with_editors(["a"]) |> Workbench.set_dirty("/ws/a", true)
      assert [%{dirty: true}] = wb.tabs
    end
  end

  describe "panel and terminals" do
    test "opening an empty panel asks for a terminal; closing keeps shells" do
      assert {%{panel_open: true, panel_view: "terminal"}, [:new_terminal]} =
               Workbench.toggle_panel(wb())

      wb = Workbench.terminal_started(wb(), 1, "sh")
      assert %{panel_open: true, active_term: 1} = wb
      assert {%{panel_open: false, terminals: [_]}, [:panel_hidden]} = Workbench.toggle_panel(wb)
    end

    test "killing vs. exiting terminals" do
      wb = wb() |> Workbench.terminal_started(1, "sh") |> Workbench.terminal_started(2, "sh")

      assert {%{terminals: [%{id: 1}], active_term: 1}, [{:stop_terminal, 2}]} =
               Workbench.kill_terminal(wb, 2)

      assert {%{terminals: [%{id: 2}], active_term: 2}, [{:forget_terminal, 1}]} =
               Workbench.terminal_exited(wb, 1)

      assert Workbench.kill_terminal(wb, 99) == wb
    end
  end

  describe "menus and palette" do
    test "menus toggle and switch" do
      wb = Workbench.toggle_menu(wb(), "file")
      assert wb.open_menu == "file"
      assert Workbench.toggle_menu(wb, "view").open_menu == "view"
      assert Workbench.toggle_menu(wb, "file").open_menu == nil
    end

    test "palette selection stays within the items" do
      # The command palette is Quick Open with ">" typed in.
      wb = Workbench.open_palette(wb())
      assert %{mode: :quick_open, query: ">"} = wb.palette

      # Already open: the input's text is replaced.
      assert {_wb, [{:push, "palette:query", %{query: ""}}]} = Workbench.open_quick_open(wb)
      assert Workbench.move_palette(wb, -1, 3).palette.index == 0

      assert wb
             |> Workbench.move_palette(1, 3)
             |> Workbench.move_palette(5, 3)
             |> then(& &1.palette.index) == 2

      assert Workbench.filter_palette(wb, "x").palette == %{
               mode: :quick_open,
               query: "x",
               index: 0
             }
    end

    test "quick pick and input box use the palette" do
      wb = Workbench.open_quick_pick(wb(), %{items: [%{label: "a", value: 1}], command: "x.pick"})
      assert %{mode: :pick, command: "x.pick", arguments: [], query: ""} = wb.palette
      assert Workbench.filter_palette(wb, "a").palette.items == [%{label: "a", value: 1}]

      wb = Workbench.open_input_box(wb(), %{command: "x.in", value: "draft", prompt: "Name?"})
      assert %{mode: :input, query: "draft", prompt: "Name?"} = wb.palette
    end
  end

  test "when context" do
    wb =
      with_editors(["lib/a.ex"])
      |> Workbench.set_dirty("/ws/lib/a.ex", true)
      |> Workbench.terminal_started(1, "sh")

    assert %{
             "activeEditor" => "lib/a.ex",
             "activeEditorIsDirty" => true,
             "resourceFilename" => "a.ex",
             "resourceExtname" => ".ex",
             "editorLangId" => "elixir",
             "editorIsOpen" => true,
             "panelVisible" => true,
             "activeViewlet" => "workbench.view.explorer",
             "terminalCount" => 1,
             "inQuickOpen" => false,
             "config.editor.fontSize" => 14
           } = Workbench.context(wb, %{"editor.fontSize" => 14})
  end

  describe "sidebar views" do
    test "show_view opens a view, or hides the sidebar when it is already shown" do
      wb = wb()

      assert %{sidebar_open: true, sidebar_view: "extensions"} =
               wb = Workbench.show_view(wb, "extensions")

      assert %{sidebar_open: false} = wb = Workbench.show_view(wb, "extensions")
      assert %{sidebar_open: true, sidebar_view: "explorer"} = Workbench.show_view(wb, "explorer")
      assert Workbench.context(Workbench.toggle_sidebar(wb()))["activeViewlet"] == false
    end
  end

  test "resizing the sidebar and panel clamps, nil restores the default" do
    wb = wb()
    assert Workbench.resize(wb, :sidebar, 300.4).sidebar_width == 300
    assert Workbench.resize(wb, :sidebar, 10).sidebar_width == 170
    assert Workbench.resize(wb, :sidebar, 5000).sidebar_width == 800
    assert Workbench.resize(wb, :panel, 50).panel_height == 80

    resized = Workbench.resize(wb, :panel, 400)
    assert Workbench.resize(resized, :panel, nil).panel_height == wb.panel_height
  end

  test "the activity bar's order: dragged ones first, unknown ones after in their order" do
    containers = for id <- ~w(explorer search scm extensions), do: %{id: id}
    wb = Workbench.reorder_activity(wb(), ["scm", 1, "explorer", "gone", "scm"])
    assert wb.activity_order == ["scm", "explorer", "gone"]

    assert Workbench.sort_containers(containers, wb.activity_order) |> Enum.map(& &1.id) ==
             ~w(scm explorer search extensions)

    assert Workbench.sort_containers(containers, []) == containers
  end

  describe "tabs" do
    defp with_tabs(paths, dirty \\ []) do
      tabs = for p <- paths, do: %{path: p, dirty: p in dirty, lang: "plaintext"}
      %{wb() | tabs: tabs, active: List.last(paths)}
    end

    test "reorder_tabs: the given order, the rest after" do
      wb = with_tabs(["/a", "/b", "/c"]) |> Workbench.reorder_tabs(["/c", "/a", "/gone"])
      assert Workbench.tab_paths(wb) == ["/c", "/a", "/b"]
    end

    test "close_editors closes several; dirty_paths finds unsaved ones" do
      wb = with_tabs(["/a", "/b", "/c"], ["/b"])
      assert Workbench.dirty_paths(wb, ["/a", "/b"]) == ["/b"]

      {wb, effects} = Workbench.close_editors(wb, ["/a", "/c"])
      assert Workbench.tab_paths(wb) == ["/b"]
      assert wb.active == "/b"
      assert {:close_buffer, "/a"} in effects and {:close_buffer, "/c"} in effects
    end
  end

  describe "panel sections and terminals" do
    test "a section prepares what it shows: a shell, the console" do
      assert {%{panel_view: "console"}, [:start_console]} = Workbench.show_panel(wb(), "console")
      wb = Workbench.console_started(wb(), 7)
      assert Workbench.term_view?(wb, 7)

      assert {%{panel_view: "console"}, [{:panel_shown, "console"}]} =
               Workbench.show_panel(wb, "console")

      assert {_, [{:panel_shown, "plugin.panel"}]} = Workbench.show_panel(wb, "plugin.panel")

      assert {%{panel_open: true, panel_maximized: true}, _} =
               Workbench.toggle_maximized_panel(wb())
    end

    test "names, icons, colours and order" do
      wb = wb() |> Workbench.terminal_started(1, "sh") |> Workbench.terminal_started(2, "sh")
      assert [%{icon: "command-line", color: nil} | _] = wb.terminals

      wb =
        wb
        |> Workbench.rename_terminal(1, " server ")
        |> Workbench.rename_terminal(2, "  ")
        |> Workbench.set_terminal_icon(1, "rocket-launch")
        |> Workbench.set_terminal_color(1, "green")
        |> Workbench.set_terminal_color(2, "chartreuse")
        |> Workbench.reorder_terminals([2, 1])

      assert [
               %{id: 2, name: "sh", color: nil},
               %{id: 1, name: "server", icon: "rocket-launch", color: "green"}
             ] =
               wb.terminals
    end
  end
end

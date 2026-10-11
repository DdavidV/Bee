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

    test "a preview takes the place of the one before it; a kept or edited one stays" do
      assert {_, [{:open_file, "/ws/a", :preview}]} =
               Workbench.open_editor(wb(), "/ws/a", preview: true)

      wb = with_editors(["a"])
      {wb, []} = Workbench.wrap(Workbench.editor_opened(wb, "/ws/b", false, "plaintext", true))
      assert [%{path: "/ws/a"}, %{path: "/ws/b", preview: true}] = wb.tabs

      # The next preview replaces it, where it was; its file is closed.
      {wb, effects} = Workbench.editor_opened(wb, "/ws/c", false, "plaintext", true)
      assert [%{path: "/ws/a"}, %{path: "/ws/c", preview: true}] = wb.tabs
      assert wb.active == "/ws/c"
      assert {:close_buffer, "/ws/b"} in effects
      assert {:push, "cm:close", %{path: "/ws/b", group: 1}} in effects

      # Kept: the next one is added.
      wb = Workbench.keep_editor(wb, "/ws/c")
      wb = Workbench.editor_opened(wb, "/ws/d", false, "plaintext", true)
      assert Enum.map(wb.tabs, & &1.path) == ["/ws/a", "/ws/c", "/ws/d"]

      # Edited: kept. Opened to stay (not as a preview): kept.
      assert %{preview: false} =
               wb |> Workbench.set_dirty("/ws/d", true) |> Workbench.tab("/ws/d")

      {kept, _} = Workbench.open_editor(wb, "/ws/d")
      assert %{preview: false} = Workbench.tab(kept, "/ws/d")
      # Previewed again while open: still a preview, only shown.
      {shown, _} = Workbench.open_editor(wb, "/ws/d", preview: true)
      assert %{preview: true} = Workbench.tab(shown, "/ws/d")

      # Kept before it was open (a quick double click): where the preview is.
      {replaced, _} = Workbench.editor_opened(wb, "/ws/f", false, "plaintext", :replace)
      assert Enum.map(replaced.tabs, & &1.path) == ["/ws/a", "/ws/c", "/ws/f"]
      assert %{preview: false} = Workbench.tab(replaced, "/ws/f")

      # A file with unsaved changes is never a preview.
      wb = Workbench.editor_opened(wb(), "/ws/e", true, "plaintext", true)
      assert [%{preview: false}] = wb.tabs
    end

    test "split: a new group beside the focused one, focused, asking for the same file" do
      wb = with_editors(["a", "b"])
      {wb, effects} = Workbench.split(wb, :right)
      assert wb.group == 2
      assert wb.tabs == []
      assert wb.editor_layout == {:row, [{:leaf, 1}, {:leaf, 2}]}
      assert effects == [{:push, "cm:focus", %{group: 2}}, {:open_file, "/ws/b"}]
      assert [%{id: 1, active: "/ws/b"}, %{id: 2, tabs: []}] = Workbench.groups(wb)

      wb = Workbench.editor_opened(wb, "/ws/b", false, "plaintext")

      assert [%{id: 1}, %{id: 2, tabs: [%{path: "/ws/b"}], active: "/ws/b"}] =
               Workbench.groups(wb)

      assert Enum.map(Workbench.all_tabs(wb), & &1.path) == ["/ws/b", "/ws/a", "/ws/b"]

      # Down from the second: a column in its place. Right again from the
      # first: into the row.
      {wb, _} = Workbench.split(wb, :down)
      assert wb.editor_layout == {:row, [{:leaf, 1}, {:col, [{:leaf, 2}, {:leaf, 3}]}]}
      {wb, _} = Workbench.focus_group(wb, 1)
      {wb, _} = Workbench.split(wb, :right)

      assert wb.editor_layout ==
               {:row, [{:leaf, 1}, {:leaf, 4}, {:col, [{:leaf, 2}, {:leaf, 3}]}]}

      # Nothing to split without a file shown.
      assert Workbench.split(wb(), :right) == wb()
    end

    test "a file open in two groups: closed in one, its buffer stays; the empty group goes" do
      {wb, _} = with_editors(["a"]) |> Workbench.split(:right)
      wb = Workbench.editor_opened(wb, "/ws/a", false, "plaintext")

      # Unsaved in one is unsaved in both.
      wb = Workbench.set_dirty(wb, "/ws/a", true)
      assert [%{tabs: [%{dirty: true}]}, %{tabs: [%{dirty: true}]}] = Workbench.groups(wb)

      {wb, effects} = Workbench.close_editor(wb, "/ws/a")
      refute {:close_buffer, "/ws/a"} in effects
      assert {:push, "cm:close", %{path: "/ws/a", group: 2}} in effects
      assert {:push, "cm:focus", %{group: 1}} in effects
      assert wb.editor_layout == {:leaf, 1}
      assert wb.group == 1 and wb.others == []

      {wb, effects} = Workbench.close_editor(wb, "/ws/a")
      assert {:close_buffer, "/ws/a"} in effects
      # The last group stays, empty.
      assert wb.editor_layout == {:leaf, 1} and wb.tabs == []
    end

    test "Close doesn't ask about unsaved changes another group still shows" do
      {wb, _} = with_editors(["a"]) |> Workbench.split(:right)

      wb =
        wb
        |> Workbench.editor_opened("/ws/a", false, "plaintext")
        |> Workbench.set_dirty("/ws/a", true)

      {wb, effects} = Bee.Workbench.Actions.close_active_editor(wb)
      assert wb.palette == nil and wb.others == []
      refute {:close_buffer, "/ws/a"} in effects

      # The last one showing it: asked first.
      assert %{palette: %{}} = Bee.Workbench.Actions.close_active_editor(wb)
    end

    test "closing a tab of a group that isn't focused leaves the focus where it is" do
      {wb, _} = with_editors(["a", "b"]) |> Workbench.split(:right)
      wb = Workbench.editor_opened(wb, "/ws/b", false, "plaintext")

      {wb, effects} = Workbench.close_editor(wb, 1, "/ws/a")
      assert wb.group == 2
      assert {:close_buffer, "/ws/a"} in effects
      assert [%{id: 1, tabs: [%{path: "/ws/b"}]}, %{id: 2}] = Workbench.groups(wb)

      # Its last one: the group goes, the focused one stays focused.
      {wb, _} = Workbench.close_editor(wb, 1, "/ws/b")
      assert wb.group == 2 and wb.editor_layout == {:leaf, 2}
    end

    test "move_tab: to another group at a place, to a new group, leaving none empty" do
      {wb, _} = with_editors(["a", "b"]) |> Workbench.split(:right)
      wb = Workbench.editor_opened(wb, "/ws/b", false, "plaintext")
      wb = Workbench.editor_opened(wb, "/ws/c", false, "plaintext")

      # a: from group 1 to the front of group 2 (its buffer isn't closed).
      {wb, effects} = Workbench.move_tab(wb, "/ws/a", 1, 2, 0)
      refute Enum.any?(effects, &match?({:close_buffer, _}, &1))
      assert {:push, "cm:close", %{path: "/ws/a", group: 1}} in effects
      assert List.last(effects) == {:open_file, "/ws/a"}
      wb = Workbench.editor_opened(wb, "/ws/a", false, "plaintext")
      assert Enum.map(wb.tabs, & &1.path) == ["/ws/a", "/ws/b", "/ws/c"]
      assert wb.group == 2 and wb.active == "/ws/a"

      # b is in both: moved from group 1, group 2's is shown; group 1 is empty and goes.
      {wb, effects} = Workbench.move_tab(wb, "/ws/b", 1, 2)
      refute Enum.any?(effects, &match?({:open_file, _}, &1))
      assert wb.editor_layout == {:leaf, 2}
      assert wb.active == "/ws/b"

      # To the right edge of its own group: a new group there.
      {wb, effects} = Workbench.move_tab(wb, "/ws/c", 2, 2, nil, :right)
      assert wb.editor_layout == {:row, [{:leaf, 2}, {:leaf, 3}]}
      assert wb.group == 3
      assert List.last(effects) == {:open_file, "/ws/c"}

      # A group's only tab stays where it is; so does a tab dropped on its own group.
      wb = Workbench.editor_opened(wb, "/ws/c", false, "plaintext")
      assert Workbench.move_tab(wb, "/ws/c", 3, 3, nil, :down) == wb
      assert Workbench.move_tab(wb, "/ws/c", 3, 3) == wb
      assert Workbench.move_tab(wb, "/ws/nope", 3, 2) == wb
    end

    test "closing the active editor activates its right neighbour, else the left one" do
      wb = with_editors(["a", "b", "c"]) |> Workbench.activate_editor("/ws/b") |> elem(0)

      assert {%{tabs: [%{path: "/ws/a"}, %{path: "/ws/c"}], active: "/ws/c"}, effects} =
               Workbench.close_editor(wb, "/ws/b")

      assert effects == [
               {:close_buffer, "/ws/b"},
               {:push, "cm:close", %{path: "/ws/b", group: 1}},
               {:push, "cm:activate", %{path: "/ws/c", group: 1}}
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
      tabs = for p <- paths, do: %{path: p, kind: :file, dirty: p in dirty, lang: "plaintext"}
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

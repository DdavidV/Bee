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
      assert {%{panel_open: false}, [:new_terminal]} = Workbench.toggle_panel(wb())

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
      wb = Workbench.open_palette(wb())
      assert Workbench.move_palette(wb, -1, 3).palette.index == 0

      assert wb
             |> Workbench.move_palette(1, 3)
             |> Workbench.move_palette(5, 3)
             |> then(& &1.palette.index) == 2

      assert Workbench.filter_palette(wb, "x").palette == %{query: "x", index: 0}
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
end

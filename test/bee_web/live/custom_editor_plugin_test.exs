defmodule BeeWeb.CustomEditorPluginTest do
  # A plugin's own editor for files (contributes.customEditors with a
  # LiveView): the hex-view example, in the window.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bee.Plugins

  @moduletag :capture_log
  @examples Path.expand("../../../examples/plugins", __DIR__)

  setup %{conn: conn} do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "data.bin"), <<0, 1, 2, 0xFF>> <> "Bee!")
    File.write!(Path.join(root, "notes.txt"), "hello\n")
    File.write!(Path.join(root, "long.dat"), :binary.copy(<<0xAB>>, 1000))

    File.rm_rf!(Plugins.user_dir())
    File.mkdir_p!(Plugins.user_dir())
    File.cp_r!(Path.join(@examples, "hex-view"), Path.join(Plugins.user_dir(), "hex-view"))
    Plugins.reload()

    on_exit(fn ->
      File.rm_rf!(Plugins.user_dir())
      Plugins.reload()
      File.rm_rf!(root)
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view, root: root}
  end

  defp eventually(fun, tries \\ 150) do
    cond do
      result = fun.() -> result
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  # The plugin's LiveView showing `name`, once it is mounted.
  defp hex(view, name) do
    eventually(fn ->
      render(view)
      Enum.find(live_children(view), &(render(&1) =~ ~s(class="hex-view-name">#{name}<)))
    end)
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

  test "a file the editor is for opens in it: the plugin starts and draws it", %{
    view: view,
    root: root
  } do
    path = Path.join(root, "data.bin")
    click_file(view, "data.bin")

    assert has_element?(view, tab(path) <> "[data-active=true]", "data.bin")
    assert has_element?(view, "[data-custom-editor='hexView.editor'][data-path='#{path}']")
    refute_push_event(view, "cm:open", %{path: ^path})

    html = render(hex(view, "data.bin"))
    assert html =~ "00000000"
    assert html =~ "00 01 02 FF 42 65 65 21"
    assert html =~ "....Bee!"
    assert html =~ "bytes 0–7 of 8"
  end

  test "its pages", %{view: view} do
    click_file(view, "long.dat")
    editor = hex(view, "long.dat")
    assert render(editor) =~ "bytes 0–511 of 1000"

    assert editor |> element("button", "Next") |> render_click() =~ "bytes 512–999 of 1000"
    assert render(editor) =~ "00000200"
    assert editor |> element("button", "First") |> render_click() =~ "bytes 0–511 of 1000"
    assert editor |> element("form") |> render_submit(%{"offset" => "0x3E0"}) =~ "bytes 512–999"
  end

  test "Open With… offers it for any file; the file opens as text again too", %{
    view: view,
    root: root
  } do
    path = Path.join(root, "notes.txt")
    click_file(view, "notes.txt")
    assert_push_event(view, "cm:open", %{path: ^path})

    run(view, "workbench.action.reopenWithEditor")
    assert picks(view) |> Enum.take(2) == ["Text Editor Active and Default", "Hex Viewer"]
    pick(view, "Hex Viewer")

    assert render(hex(view, "notes.txt")) =~ "68 65 6C 6C 6F 0A"
    assert has_element?(view, "[data-custom-editor='hexView.editor']")

    run(view, "workbench.action.reopenWithEditor")
    assert "Hex Viewer Active" in picks(view)
    pick(view, "Text Editor")
    assert_push_event(view, "cm:open", %{path: ^path, text: "hello\n"})
    refute has_element?(view, "[data-custom-editor]")
  end

  test "the plugin's command opens a file in it (Bee.API.open_file/3, with:)", %{
    view: view,
    root: root
  } do
    run(view, "hexView.open", [Path.join(root, "notes.txt")])
    assert render(hex(view, "notes.txt")) =~ "hello."
  end

  test "without the plugin its files are what they were", %{view: view, root: root} do
    click_file(view, "data.bin")
    hex(view, "data.bin")

    File.rm_rf!(Path.join(Plugins.user_dir(), "hex-view"))
    Plugins.reload()
    eventually(fn -> render(view) =~ "Its plugin isn&#39;t loaded any more." end)

    run(view, "workbench.action.closeActiveEditor")
    click_file(view, "data.bin")
    assert has_element?(view, "[data-binary-editor]")
    refute has_element?(view, "[data-custom-editor]")
    _ = root
  end
end

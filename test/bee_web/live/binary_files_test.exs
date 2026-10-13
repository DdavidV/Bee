defmodule BeeWeb.BinaryFilesTest do
  # Files that aren't text, as VS Code opens them: an image shown, audio
  # and video played, any other binary file said to be one – and all of
  # them opened as text when asked (Open Anyway).
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # A PNG's first bytes (not an image a browser shows: nothing here draws it).
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, "IHDR">>

  @svg ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>\n)

  setup %{conn: conn} do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "text\n")
    File.write!(Path.join(root, "logo.png"), @png)
    File.write!(Path.join(root, "Song.MP3"), <<0xFF, 0xFB, 0x90, 0x00>>)
    File.write!(Path.join(root, "clip.webm"), <<0x1A, 0x45, 0xDF, 0xA3>>)
    File.write!(Path.join(root, "data.bin"), "ok" <> <<0xFF, 0x00>> <> "end")
    File.write!(Path.join(root, "logo.svg"), @svg)
    File.write!(Path.join(root, "big.log"), String.duplicate("0123456789abcde\n", 100_000))

    on_exit(fn ->
      stop_buffers_under(root)
      File.rm_rf!(root)
    end)

    put_user_settings(%{})
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view, root: root}
  end

  defp put_user_settings(settings) do
    path = Bee.Settings.user_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(settings))
    Bee.Settings.reload()

    on_exit(fn ->
      File.rm(path)
      Bee.Settings.reload()
    end)
  end

  defp user_settings, do: Bee.Settings.user_path() |> File.read!() |> Jason.decode!()

  # A right click on what `selector` finds: its menu.
  defp right_click(view, selector) do
    render_hook(view, "open_context_menu", %{
      "menu" => attr(view, selector, "data-menu"),
      "x" => 1,
      "y" => 1,
      "args" => view |> attr(selector, "data-menu-args") |> Jason.decode!(),
      "context" => view |> attr(selector, "data-menu-context") |> Jason.decode!()
    })
  end

  defp menu_click(view, command),
    do: view |> element("#context-menu [data-command='#{command}']") |> render_click()

  defp explorer(rel), do: "#explorer button[phx-value-path='#{rel}']"

  # The pick's items: each one's label and what is said of it.
  defp picks(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#palette [role=option]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp pick(view, label),
    do: view |> element("#palette [role=option]", label) |> render_click()

  defp stop_buffers_under(root) do
    for {path, pid} <-
          Registry.select(Bee.Registry, [{{{:buffer, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}]),
        String.starts_with?(path, root <> "/") do
      DynamicSupervisor.terminate_child(Bee.BufferSup, pid)
    end
  end

  defp click_file(view, rel),
    do: view |> element("#explorer button[phx-value-path='#{rel}']") |> render_click()

  defp run(view, command, args \\ []) do
    render_hook(view, "run_command", %{"command" => command, "args" => Jason.encode!(args)})
  end

  defp attr(view, selector, name) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> hd()
  end

  defp tab(path), do: "[data-tabs] [data-tab][data-path='#{path}']"

  test "an image is shown, not opened as text", %{view: view, root: root, conn: conn} do
    path = Path.join(root, "logo.png")
    click_file(view, "logo.png")

    assert has_element?(view, tab(path) <> "[data-active=true][data-preview=true]", "logo.png")
    assert has_element?(view, "[data-media-preview=image][data-current=true][data-size='16']")
    refute_push_event(view, "cm:open", %{path: ^path})
    assert_push_event(view, "cm:deactivate", %{})
    # No language: it is no text.
    refute has_element?(view, "#status-lang")
    assert render(view) =~ "logo.png — #{Path.basename(root)}"

    # The page gets the file itself from the address it was given.
    src = attr(view, "[data-media-preview=image]", "data-src")
    conn = get(conn, src)
    assert response(conn, 200) == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]
  end

  test "audio and video are played", %{view: view} do
    click_file(view, "Song.MP3")
    assert has_element?(view, "[data-media-preview=audio][data-current=true]")

    # (A preview: the next file takes its tab.)
    click_file(view, "clip.webm")
    assert has_element?(view, "[data-media-preview=video][data-current=true]")
    refute has_element?(view, "[data-media-preview=audio]")
  end

  test "an image stays while another editor is shown; it is shown again when it changed", %{
    view: view,
    root: root
  } do
    path = Path.join(root, "logo.png")
    click_file(view, "logo.png")
    run(view, "workbench.action.keepEditor")
    before = attr(view, "[data-media-preview=image]", "data-src")

    click_file(view, "a.txt")
    assert has_element?(view, "[data-media-preview=image][data-current=false].hidden")

    File.write!(path, @png <> "more")
    send(view.pid, {:fs_changed, path})
    assert has_element?(view, "[data-media-preview=image][data-size='20']")
    assert attr(view, "[data-media-preview=image]", "data-src") != before
  end

  test "a binary file isn't shown: Open Anyway shows what can be read of it", %{
    view: view,
    root: root
  } do
    path = Path.join(root, "data.bin")
    click_file(view, "data.bin")

    assert has_element?(view, tab(path) <> "[data-active=true]", "data.bin")
    assert has_element?(view, "[data-binary-editor]", "either binary or uses an unsupported")
    refute_push_event(view, "cm:open", %{path: ^path})

    view |> element("[data-binary-editor] button", "Open Anyway") |> render_click()

    assert_push_event(view, "cm:open", %{path: ^path, text: "ok�\0end"})
    refute has_element?(view, "[data-binary-editor]")
    # In the same tab.
    assert has_element?(view, tab(path) <> "[data-active=true][data-preview=true]")

    assert view
           |> element("[data-tabs]")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[data-tab]")
           |> Enum.count() == 1

    assert has_element?(view, "#status-lang")

    # Nothing changed: nothing to save, and the file is as it was.
    refute has_element?(view, tab(path) <> "[data-dirty=true]")
    assert File.read!(path) == "ok" <> <<0xFF, 0x00>> <> "end"
  end

  test "Reopen Editor With Text Editor: an image as text", %{view: view, root: root} do
    path = Path.join(root, "logo.png")
    click_file(view, "logo.png")
    run(view, "workbench.action.reopenTextEditor")

    assert_push_event(view, "cm:open", %{path: ^path})
    refute has_element?(view, "[data-media-preview]")

    # While that is open, it is the text editor that has the file.
    run(view, "workbench.action.keepEditor")
    click_file(view, "a.txt")
    click_file(view, "logo.png")
    assert_push_event(view, "cm:activate", %{path: ^path})
    refute has_element?(view, "[data-media-preview]")
  end

  test "an image in a split group, and closed", %{view: view, root: root} do
    path = Path.join(root, "logo.png")
    click_file(view, "logo.png")
    run(view, "workbench.action.splitEditor")

    assert has_element?(view, "#group-1 [data-media-preview=image][data-current=false]")
    assert has_element?(view, "#group-2 [data-media-preview=image][data-current=true]")

    run(view, "workbench.action.closeEditor", [path, 2])
    run(view, "workbench.action.closeEditor", [path, 1])
    refute has_element?(view, "[data-media-preview]")
    refute has_element?(view, "[data-tab]")
  end

  test "a file that is gone can't be opened", %{view: view, root: root} do
    File.rm!(Path.join(root, "logo.png"))
    click_file(view, "logo.png")
    assert render(view) =~ "Cannot open logo.png"
    refute has_element?(view, "[data-tab]")
  end

  describe "an SVG" do
    test "is shown as an image; Open With… (the Explorer's menu) opens it as text", %{
      view: view,
      root: root
    } do
      path = Path.join(root, "logo.svg")
      click_file(view, "logo.svg")
      assert has_element?(view, "[data-media-preview=image][data-current=true]")

      right_click(view, explorer("logo.svg"))
      menu_click(view, "explorer.openWith")

      assert picks(view) == [
               "Text Editor",
               "Image Preview Active and Default",
               "Configure default editor for '*.svg'…"
             ]

      pick(view, "Text Editor")
      assert_push_event(view, "cm:open", %{path: ^path, text: @svg})
      refute has_element?(view, "[data-media-preview]")
      assert has_element?(view, "#status-lang")
    end

    test "edited in one group and seen in another: as saved", %{view: view, root: root} do
      path = Path.join(root, "logo.svg")
      click_file(view, "logo.svg")
      run(view, "workbench.action.keepEditor")
      before = attr(view, "[data-media-preview=image]", "data-src")

      # The same file in a second group, there as text.
      run(view, "workbench.action.splitEditor")
      right_click(view, "#group-2 " <> tab(path))
      menu_click(view, "workbench.action.reopenWithEditor")
      pick(view, "Text Editor")

      assert_push_event(view, "cm:open", %{path: ^path, group: 2})
      assert has_element?(view, "#group-1 [data-media-preview=image]")
      refute has_element?(view, "#group-2 [data-media-preview]")

      changed = String.replace(@svg, "8", "16")
      render_hook(view, "doc_changed", %{"path" => path, "text" => changed})
      render_hook(view, "save", %{"path" => path, "text" => changed})

      assert File.read!(path) == changed
      assert attr(view, "#group-1 [data-media-preview=image]", "data-src") != before
    end

    test "with unsaved changes it isn't taken out of its editor", %{view: view, root: root} do
      path = Path.join(root, "logo.svg")
      click_file(view, "logo.svg")
      run(view, "workbench.action.reopenTextEditor")
      render_hook(view, "doc_changed", %{"path" => path, "text" => "<svg/>"})

      run(view, "workbench.action.reopenWithEditor")
      assert "Text Editor Active" in picks(view)
      pick(view, "Image Preview")

      assert render(view) =~ "Save logo.svg to open it with another editor"
      refute has_element?(view, "[data-media-preview]")
      assert has_element?(view, tab(path) <> "[data-dirty=true]")
    end

    test "Configure default editor: kept in the settings, and used from then on", %{
      view: view,
      root: root
    } do
      path = Path.join(root, "logo.svg")
      right_click(view, explorer("logo.svg"))
      menu_click(view, "explorer.openWith")
      pick(view, "Configure default editor")
      assert picks(view) == ["Text Editor", "Image Preview Default"]
      pick(view, "Text Editor")

      assert user_settings()["workbench.editorAssociations"] == %{"*.svg" => "default"}

      click_file(view, "logo.svg")
      assert_push_event(view, "cm:open", %{path: ^path})
      refute has_element?(view, "[data-media-preview]")

      # Still an image for the asking.
      run(view, "workbench.action.reopenWithEditor")
      assert picks(view) |> Enum.take(2) == ["Text Editor Active and Default", "Image Preview"]
      pick(view, "Image Preview")
      assert has_element?(view, "[data-media-preview=image][data-current=true]")
    end
  end

  test "Open With… is for files; a text file has the text editor alone", %{view: view} do
    click_file(view, "a.txt")
    right_click(view, explorer("a.txt"))
    menu_click(view, "explorer.openWith")

    assert picks(view) == [
             "Text Editor Active and Default",
             "Configure default editor for '*.txt'…"
           ]
  end

  describe "a very large file" do
    setup do
      # (1.6 MB is large here.)
      put_user_settings(%{"workbench.editorLargeFileConfirmation" => 1})
    end

    test "isn't opened as text before Open Anyway", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/")
      path = Path.join(root, "big.log")
      click_file(view, "big.log")

      assert has_element?(
               view,
               "[data-binary-editor][data-reason=large]",
               "The file is not displayed in the text editor because it is very large (1.53MB)."
             )

      refute_push_event(view, "cm:open", %{path: ^path})
      assert Registry.lookup(Bee.Registry, {:buffer, path}) == []

      view |> element("[data-binary-editor] button", "Open Anyway") |> render_click()
      assert_push_event(view, "cm:open", %{path: ^path, text: "0123456789abcde\n" <> _})
      refute has_element?(view, "[data-binary-editor]")
    end

    test "Configure Limit shows its setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      click_file(view, "big.log")
      view |> element("[data-binary-editor] button", "Configure Limit") |> render_click()

      assert has_element?(
               view,
               "#settings-search input[value='workbench.editorLargeFileConfirmation']"
             )

      assert render(view) =~ "Editor Large File Confirmation"
    end

    test "a small file, and an image of any size, open as ever", %{conn: conn, root: root} do
      File.write!(Path.join(root, "logo.png"), String.duplicate(<<0>>, 1_200_000))
      {:ok, view, _html} = live(conn, ~p"/")

      click_file(view, "a.txt")
      refute has_element?(view, "[data-binary-editor]")
      click_file(view, "logo.png")
      assert has_element?(view, "[data-media-preview=image]")
    end
  end
end

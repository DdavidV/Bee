defmodule Bee.CustomEditorsTest do
  # The customEditors contribution point: which files open as an image,
  # audio or video. Contributions are global.
  use ExUnit.Case, async: false

  alias Bee.Contributions
  alias Bee.CustomEditors

  defp contribute(name, editors) do
    source = {:plugin, name}
    manifest = %{"name" => name, "contributes" => %{"customEditors" => editors}}
    assert :ok = Contributions.register(source, manifest)
    on_exit(fn -> Contributions.unregister(source) end)
  end

  test "Bee's own: the files of VS Code's media previews, whatever their case" do
    assert CustomEditors.for_file("/ws/a/logo.png") == "imagePreview.previewEditor"
    assert CustomEditors.for_file("/ws/PHOTO.JPG") == "imagePreview.previewEditor"
    assert CustomEditors.for_file("/ws/song.mp3") == "vscode.audioPreview"
    assert CustomEditors.for_file("/ws/clip.webm") == "vscode.videoPreview"

    assert CustomEditors.for_file("/ws/logo.svg") == "imagePreview.previewEditor"

    # Everything else is text.
    assert CustomEditors.for_file("/ws/png") == nil
    assert CustomEditors.for_file("/ws/a.png.txt") == nil

    assert CustomEditors.viewer("imagePreview.previewEditor") == :image
    assert CustomEditors.viewer("vscode.audioPreview") == :audio
    assert CustomEditors.viewer("vscode.videoPreview") == :video
    assert CustomEditors.display_name("imagePreview.previewEditor") == "Image Preview"
  end

  test "a plugin adds files to an editor Bee has" do
    assert CustomEditors.for_file("/ws/scan.tiff") == nil

    contribute("more-images", [
      %{
        "viewType" => "imagePreview.previewEditor",
        "selector" => [%{"filenamePattern" => "*.TIFF"}, %{"filenamePattern" => "art/*.raw"}]
      }
    ])

    assert CustomEditors.for_file("/ws/scan.tiff") == "imagePreview.previewEditor"
    assert CustomEditors.for_file("/ws/art/one.raw") == "imagePreview.previewEditor"
    assert CustomEditors.for_file("/ws/other/one.raw") == nil
  end

  test "an editor Bee doesn't have, or one that is only an option, opens nothing" do
    contribute("others", [
      %{"viewType" => "hex.editor", "selector" => [%{"filenamePattern" => "*.png"}]},
      %{
        "viewType" => "imagePreview.previewEditor",
        "priority" => "option",
        "selector" => [%{"filenamePattern" => "*.pdf"}]
      }
    ])

    assert CustomEditors.for_file("/ws/logo.png") == "imagePreview.previewEditor"
    assert CustomEditors.for_file("/ws/paper.pdf") == nil

    # An option is still one of the editors to open the file with.
    assert CustomEditors.choices("/ws/paper.pdf") == [
             %{id: "default", label: "Text Editor"},
             %{id: "imagePreview.previewEditor", label: "Image Preview"}
           ]

    assert CustomEditors.viewer("hex.editor") == nil
  end

  test "a default editor wins over a built-in one" do
    contribute("play-gifs", [
      %{"viewType" => "vscode.videoPreview", "selector" => [%{"filenamePattern" => "*.gif"}]}
    ])

    assert CustomEditors.for_file("/ws/a.gif") == "vscode.videoPreview"
  end

  test "workbench.editorAssociations decide first" do
    associations = %{
      "*.SVG" => "default",
      "*.txt" => "imagePreview.previewEditor",
      "docs/*.png" => "default"
    }

    assert CustomEditors.for_file("/ws/logo.svg", associations) == nil
    assert CustomEditors.for_file("/ws/a.txt", associations) == "imagePreview.previewEditor"
    assert CustomEditors.for_file("/ws/docs/a.png", associations) == nil
    assert CustomEditors.for_file("/ws/a.png", associations) == "imagePreview.previewEditor"

    # An editor Bee doesn't have, or what is no setting at all, decides nothing.
    assert CustomEditors.for_file("/ws/a.png", %{"*.png" => "hex.editor"}) ==
             "imagePreview.previewEditor"

    assert CustomEditors.for_file("/ws/a.png", %{"*.png" => 1}) == "imagePreview.previewEditor"
    assert CustomEditors.for_file("/ws/a.png", nil) == "imagePreview.previewEditor"
  end

  test "what a file can be opened with, and the pattern for files like it" do
    assert CustomEditors.choices("/ws/logo.svg") == [
             %{id: "default", label: "Text Editor"},
             %{id: "imagePreview.previewEditor", label: "Image Preview"}
           ]

    assert CustomEditors.choices("/ws/a.txt") == [%{id: "default", label: "Text Editor"}]

    assert CustomEditors.pattern("/ws/logo.svg") == "*.svg"
    assert CustomEditors.pattern("/ws/Makefile") == "Makefile"
  end

  describe "a plugin's own editor (live)" do
    defp manifest(name, editors, server \\ %{"module" => "Hex"}) do
      %{"name" => name, "contributes" => %{"customEditors" => editors}}
      |> Map.merge(if server, do: %{"server" => server}, else: %{})
    end

    defp register(name, editors) do
      source = {:plugin, name}
      assert :ok = Contributions.register(source, manifest(name, editors))
      on_exit(fn -> Contributions.unregister(source) end)
    end

    @hex %{
      "viewType" => "hex.editor",
      "displayName" => "Hex",
      "live" => "Hex.EditorLive",
      "selector" => [%{"filenamePattern" => "*.bin"}]
    }

    test "opens the files it is for, and is one to open others with" do
      register("hex", [
        @hex,
        %{
          "viewType" => "hex.editor",
          "priority" => "option",
          "selector" => [%{"filenamePattern" => "*"}]
        }
      ])

      assert CustomEditors.live_editor("hex.editor") ==
               %{plugin: "hex", live: "Hex.EditorLive", view_type: "hex.editor"}

      assert CustomEditors.live_editors() == [CustomEditors.live_editor("hex.editor")]
      assert CustomEditors.available?("hex.editor")
      assert CustomEditors.viewer("hex.editor") == nil

      assert CustomEditors.for_file("/ws/a.bin") == "hex.editor"
      # Only an option for the rest – unless the user says otherwise.
      assert CustomEditors.for_file("/ws/a.txt") == nil
      assert CustomEditors.for_file("/ws/a.txt", %{"*.txt" => "hex.editor"}) == "hex.editor"

      assert CustomEditors.choices("/ws/a.png") == [
               %{id: "default", label: "Text Editor"},
               %{id: "imagePreview.previewEditor", label: "Image Preview"},
               %{id: "hex.editor", label: "Hex"}
             ]
    end

    test "another plugin adds files to it, but can't draw it too" do
      register("hex", [@hex])

      register("more-hex", [
        %{"viewType" => "hex.editor", "selector" => [%{"filenamePattern" => "*.rom"}]}
      ])

      assert CustomEditors.for_file("/ws/a.rom") == "hex.editor"

      assert {:error, message} =
               Contributions.register({:plugin, "hex-two"}, manifest("hex-two", [@hex]))

      assert message =~ ~s(custom editor "hex.editor" is already defined)
    end

    test "it needs a server part, and a viewType of its own" do
      assert {:error, message} =
               Contributions.register({:plugin, "hex"}, manifest("hex", [@hex], nil))

      assert message =~ "needs a plugin with a \"server\" part"

      mine = %{@hex | "viewType" => "imagePreview.previewEditor"}
      assert {:error, message} = Contributions.register({:plugin, "hex"}, manifest("hex", [mine]))
      assert message =~ "is Bee's own editor"
    end
  end

  test "a manifest's customEditors must name their files" do
    manifest = %{
      "name" => "broken",
      "contributes" => %{"customEditors" => [%{"viewType" => "x"}]}
    }

    assert {:error, "invalid manifest: " <> _} =
             Contributions.register({:plugin, "broken"}, manifest)
  end
end

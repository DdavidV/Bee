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

  test "a manifest's customEditors must name their files" do
    manifest = %{
      "name" => "broken",
      "contributes" => %{"customEditors" => [%{"viewType" => "x"}]}
    }

    assert {:error, "invalid manifest: " <> _} =
             Contributions.register({:plugin, "broken"}, manifest)
  end
end

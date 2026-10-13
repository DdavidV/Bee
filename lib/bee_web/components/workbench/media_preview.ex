defmodule BeeWeb.Workbench.MediaPreview do
  @moduledoc """
  A file shown as it is instead of as text, like VS Code's media previews:
  an image (zoomed with clicks and the wheel), audio or video (played).
  Which files these are: `Bee.CustomEditors`.

  The `MediaPreview` hook draws it (assets/js/hooks/media_preview.js) from
  the file's address (`BeeWeb.MediaController`), again when the file
  changed on disk (the tab's `version`), and says what it shows in the
  status bar: an image's zoom and size in pixels, the file's size.
  """

  use BeeWeb, :html

  attr :tab, :map,
    required: true,
    doc: "the tab: `%{kind: :media, media, path, src, size, version}`"

  attr :group, :integer, required: true
  attr :active, :boolean, required: true, doc: "whether it is the editor its group shows"
  attr :focused, :boolean, required: true, doc: "whether its group is the focused one"

  def media_preview(assigns) do
    ~H"""
    <div
      id={"media-#{@group}-#{:erlang.phash2(@tab.path)}"}
      phx-hook="MediaPreview"
      data-media-preview={@tab.media}
      data-path={@tab.path}
      data-group={@group}
      data-src={"#{@tab.src}?v=#{@tab.version}"}
      data-size={@tab.size}
      data-current={to_string(@active and @focused)}
      class={["absolute inset-0 bg-editor text-editor-fg", !@active && "hidden"]}
    >
      <div
        id={"media-box-#{@group}-#{:erlang.phash2(@tab.path)}"}
        phx-update="ignore"
        data-media-box
        class="media-box"
      >
      </div>
    </div>
    """
  end
end

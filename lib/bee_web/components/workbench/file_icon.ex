defmodule BeeWeb.Workbench.FileIcon do
  @moduledoc """
  The icon of a file or folder from the file icon theme
  (`workbench.iconTheme`, see `Bee.IconThemes`): in the Explorer, tabs,
  search results and plugin view items naming a file (`resource`).

  Without a theme, or when it has no icon for the entry, files get Bee's
  own document icon and folders none (their chevron says enough).
  """
  use BeeWeb, :html

  alias Bee.IconThemes.Theme

  attr :theme, :any, required: true, doc: "%Bee.IconThemes.Theme{} or nil"
  attr :path, :string, required: true, doc: "the file's or folder's path (its name is enough)"
  attr :folder, :boolean, default: false
  attr :expanded, :boolean, default: false, doc: "an open folder"
  attr :language, :string, default: nil, doc: "the file's language id, when already known"
  attr :class, :any, default: nil

  def file_icon(assigns) do
    assigns = assign(assigns, :src, src(assigns))

    ~H"""
    <img
      :if={@src}
      src={@src}
      alt=""
      draggable="false"
      class={["size-4 shrink-0 object-contain", @class]}
    />
    <BeeWeb.Icons.named_icon
      :if={!@src and !@folder}
      name="document"
      class={["size-4 shrink-0 opacity-70", @class]}
    />
    """
  end

  defp src(%{theme: nil}), do: nil

  defp src(%{theme: theme, path: path, folder: true, expanded: expanded}),
    do: Theme.folder_icon(theme, Path.basename(path), expanded: expanded)

  defp src(%{theme: theme, path: path, language: language}) do
    name = Path.basename(path)

    language =
      if is_nil(language) and Theme.needs_language?(theme, name),
        do: Bee.Languages.detect(path),
        else: language

    Theme.file_icon(theme, name, language)
  end

  @doc "Whether the theme hides the Explorer's folder chevrons."
  def hides_arrows?(%Theme{hides_explorer_arrows: hides}), do: hides
  def hides_arrows?(nil), do: false
end

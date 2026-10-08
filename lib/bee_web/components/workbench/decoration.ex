defmodule BeeWeb.Workbench.Decoration do
  @moduledoc """
  The colours of decorations (`Bee.UI.Decorations`: Explorer, tabs, plugin
  view items) as CSS classes, from the theme's palette.
  """

  def color_class(%{color: color}), do: color_class(color)
  def color_class("modified"), do: "text-git-modified"
  def color_class("added"), do: "text-git-added"
  def color_class("untracked"), do: "text-git-untracked"
  def color_class("deleted"), do: "text-git-deleted"
  def color_class("conflict"), do: "text-git-conflict"
  def color_class("ignored"), do: "opacity-50"
  def color_class(_), do: nil
end

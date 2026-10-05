defmodule BeeWeb.Workbench.Decoration do
  @moduledoc """
  The colours of decorations (`Bee.UI.Decorations`: Explorer, tabs, plugin
  view items) as CSS classes, from the theme's palette.
  """

  def color_class(%{color: color}), do: color_class(color)
  def color_class("modified"), do: "text-warning"
  def color_class(color) when color in ["added", "untracked"], do: "text-success"
  def color_class(color) when color in ["deleted", "conflict"], do: "text-error"
  def color_class("ignored"), do: "opacity-50"
  def color_class(_), do: nil
end

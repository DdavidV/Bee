defmodule BeeWeb.Logo do
  @moduledoc """
  Bee's logo (`priv/static/images/bee.svg`, the desktop app's icon too),
  drawn inline: it doesn't depend on an emoji font, which a desktop
  webview may not have (WebKitGTK on a bare Linux). The SVG has no ids, so
  it can be on a page more than once.
  """
  use Phoenix.Component

  @path Path.expand("../../../priv/static/images/bee.svg", __DIR__)
  @external_resource @path
  @svg File.read!(@path)

  @doc "The SVG markup, for pages rendered without components."
  def svg(class \\ nil) do
    attrs = if class, do: ~s( class="#{class}" aria-hidden="true"), else: ~s( aria-hidden="true")
    String.replace(@svg, "<svg ", "<svg" <> attrs <> " ", global: false)
  end

  attr :class, :string, default: "size-5"

  def logo(assigns) do
    ~H"""
    {Phoenix.HTML.raw(svg(@class))}
    """
  end
end

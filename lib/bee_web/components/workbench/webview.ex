defmodule BeeWeb.Workbench.Webview do
  @moduledoc """
  A webview panel of a VS Code extension (`Bee.Webviews`) in an editor
  tab: a frame loading the panel's page from `BeeWeb.WebviewController`.

  The frame is sandboxed without `allow-same-origin`: the extension's HTML
  and scripts run apart from Bee's page, and reach it only by messages,
  which the `Webview` hook passes on (`assets/js/hooks/webview.js`). It is
  a new frame – the page loads afresh – when the extension sets the
  panel's HTML or the color theme changes; otherwise it stays as it is
  while its tab is open, shown or not.
  """
  use BeeWeb, :html

  attr :panel, :map, required: true, doc: "the panel (Bee.Webviews)"
  attr :theme, :string, required: true, doc: "the color theme's id"
  attr :active, :boolean, default: false

  def webview(assigns) do
    ~H"""
    <div
      id={"webview-#{@panel.id}"}
      phx-hook="Webview"
      data-webview={@panel.id}
      data-active={to_string(@active)}
      class={["absolute inset-0 bg-editor", !@active && "hidden"]}
    >
      <iframe
        id={"webview-frame-#{@panel.id}-#{@panel.version}-#{:erlang.phash2(@theme)}"}
        src={"/webview/#{@panel.token}/?v=#{@panel.version}"}
        sandbox={BeeWeb.WebviewController.sandbox(@panel)}
        title={@panel.title}
        class="size-full border-0"
      ></iframe>
    </div>
    """
  end
end

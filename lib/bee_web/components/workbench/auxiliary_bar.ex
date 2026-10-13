defmodule BeeWeb.Workbench.AuxiliaryBar do
  @moduledoc """
  The secondary side bar, VS Code style: a bar on the right of the
  editors, beside the panel, shown and hidden by its button in the title
  bar, the View menu and `Ctrl+Alt+B` (`workbench.action.toggleAuxiliaryBar`).
  Its left edge is a sash (the `Sash` hook, part "auxiliarybar"): dragged,
  it sets the bar's width, which is remembered like the sidebar's.

  It shows what VS Code extensions put there
  (`viewsContainers.secondarySidebar`): one container at a time, its
  webview views (`Bee.Webviews`) – with tabs to pick when there are
  several. Their pages stay loaded while the bar is closed. Without any it
  is empty.
  """
  use BeeWeb, :html

  attr :open, :boolean, required: true
  attr :containers, :list, default: [], doc: "the containers here (Bee.Views)"
  attr :active, :string, default: nil, doc: "the one shown"

  attr :webview_views, :list,
    default: [],
    doc: "the pages of the webview views here: [{panel, shown?}]"

  attr :webview_origin, :string, default: nil
  attr :color_theme_id, :string, default: nil

  def auxiliary_bar(assigns) do
    assigns = assign(assigns, :shown, Enum.find(assigns.containers, &(&1.id == assigns.active)))

    ~H"""
    <aside
      id="auxiliarybar"
      aria-label="Secondary Side Bar"
      class={[
        "relative min-w-0 min-h-0 overflow-hidden bg-sidebar text-sidebar-fg border-l border-sidebar-border flex flex-col",
        !@open && "hidden"
      ]}
    >
      <div
        :if={@open}
        id="sash-auxiliarybar"
        phx-hook="Sash"
        data-part="auxiliarybar"
        class="sash absolute inset-y-0 left-0 w-1 z-30 cursor-col-resize"
      >
      </div>
      <header
        :if={@containers != []}
        class="flex items-center gap-1 h-8 shrink-0 pl-4 pr-2 text-xs uppercase tracking-wide select-none"
      >
        <span id="auxiliarybar-title" class="flex-1 truncate opacity-70">
          {@shown && @shown.title}
        </span>
        <button
          :for={container <- @containers}
          :if={length(@containers) > 1}
          type="button"
          id={"auxiliary-#{container.id}"}
          title={container.title}
          aria-label={container.title}
          aria-pressed={to_string(container.id == @active)}
          class={[
            "btn btn-ghost btn-square btn-xs",
            container.id != @active && "opacity-60"
          ]}
          phx-click="show_container"
          phx-value-container={container.id}
        >
          <BeeWeb.Icons.named_icon name={container.icon} class="size-4" />
        </button>
      </header>
      <div
        :for={{panel, shown} <- @webview_views}
        id={"webview-view-#{panel.view}"}
        data-webview-view={panel.view}
        class={["relative flex-1 min-h-0", !shown && "hidden"]}
      >
        <BeeWeb.Workbench.Webview.webview
          panel={panel}
          theme={@color_theme_id}
          active
          origin={@webview_origin}
        />
      </div>
    </aside>
    """
  end
end

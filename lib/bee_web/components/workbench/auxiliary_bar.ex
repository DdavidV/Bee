defmodule BeeWeb.Workbench.AuxiliaryBar do
  @moduledoc """
  The secondary side bar, VS Code style: a bar on the right of the
  editors, beside the panel, shown and hidden by its button in the title
  bar, the View menu and `Ctrl+Alt+B` (`workbench.action.toggleAuxiliaryBar`).
  Its left edge is a sash (the `Sash` hook, part "auxiliarybar"): dragged,
  it sets the bar's width, which is remembered like the sidebar's.

  It shows nothing yet – as VS Code's does before a view is put there.
  """
  use BeeWeb, :html

  def auxiliary_bar(assigns) do
    ~H"""
    <aside
      id="auxiliarybar"
      aria-label="Secondary Side Bar"
      class="relative min-w-0 min-h-0 overflow-hidden bg-sidebar text-sidebar-fg border-l border-sidebar-border flex flex-col"
    >
      <div
        id="sash-auxiliarybar"
        phx-hook="Sash"
        data-part="auxiliarybar"
        class="sash absolute inset-y-0 left-0 w-1 z-30 cursor-col-resize"
      >
      </div>
    </aside>
    """
  end
end

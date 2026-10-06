defmodule BeeWeb.Workbench.TitleBar do
  @moduledoc """
  VS Code–style title bar: menus on the left, the command center (window
  title / command palette, `BeeWeb.Workbench.CommandPalette`) in the middle and layout
  toggles on the right.

  Menus come from `Bee.Commands.Registry` contributions, already resolved by the
  LiveView into items with label, shortcut, disabled and checked state.
  Which menu is open is server state (`open_menu`). Every item and toggle
  runs a command via `run_command`.
  """
  use BeeWeb, :html

  attr :title, :string, required: true
  attr :palette, :map, default: nil
  attr :palette_items, :list, default: []
  attr :palette_shortcut, :string, default: nil
  attr :menus, :list, required: true, doc: "[%{id, label, items: [item | :separator]}]"
  attr :open_menu, :string, default: nil
  attr :sidebar_open, :boolean, required: true
  attr :panel_open, :boolean, required: true

  def title_bar(assigns) do
    ~H"""
    <header
      id="titlebar"
      class="col-span-full h-9 grid grid-cols-[1fr_auto_1fr] items-center bg-base-300 border-b border-base-content/10 text-xs select-none"
    >
      <%!-- Click-away covers the whole menu bar, so moving from one menu
           button to another switches menus instead of closing first. --%>
      <nav
        id="menubar"
        class="flex items-center gap-0.5 pl-2"
        phx-click-away={@open_menu && "close_menu"}
        phx-window-keydown={@open_menu && "close_menu"}
        phx-key="Escape"
      >
        <span class="px-2"><BeeWeb.Logo.logo class="size-4" /></span>
        <.menu :for={menu <- @menus} menu={menu} open={@open_menu == menu.id} />
      </nav>

      <div class="flex justify-center px-4 min-w-0">
        <BeeWeb.Workbench.CommandPalette.command_center
          title={@title}
          palette={@palette}
          items={@palette_items}
          shortcut={@palette_shortcut}
        />
      </div>

      <div class="flex items-center justify-end gap-0.5 pr-2">
        <.layout_toggle
          id="layout-sidebar"
          title="Toggle Primary Side Bar"
          pressed={@sidebar_open}
          command="workbench.action.toggleSidebarVisibility"
        >
          <rect x="2.5" y="3.5" width="11" height="9" rx="1" fill="none" stroke="currentColor" />
          <rect
            x="3"
            y="4"
            width="3.5"
            height="8"
            fill={if @sidebar_open, do: "currentColor", else: "none"}
          />
          <line x1="6.5" y1="3.5" x2="6.5" y2="12.5" stroke="currentColor" />
        </.layout_toggle>
        <.layout_toggle
          id="layout-panel"
          title="Toggle Panel"
          pressed={@panel_open}
          command="workbench.action.togglePanel"
        >
          <rect x="2.5" y="3.5" width="11" height="9" rx="1" fill="none" stroke="currentColor" />
          <rect
            x="3"
            y="9"
            width="10"
            height="3"
            fill={if @panel_open, do: "currentColor", else: "none"}
          />
          <line x1="2.5" y1="9" x2="13.5" y2="9" stroke="currentColor" />
        </.layout_toggle>
      </div>
    </header>
    """
  end

  attr :menu, :map, required: true
  attr :open, :boolean, required: true

  defp menu(assigns) do
    ~H"""
    <div class="relative">
      <button
        id={"menu-#{@menu.id}-button"}
        aria-expanded={to_string(@open)}
        class={[
          "px-2 py-1 rounded cursor-pointer hover:bg-base-content/10",
          @open && "bg-base-content/10"
        ]}
        phx-click="toggle_menu"
        phx-value-menu={@menu.id}
      >
        {@menu.label}
      </button>
      <div
        :if={@open}
        id={"menu-#{@menu.id}"}
        role="menu"
        class="absolute left-0 top-full mt-1 z-40 min-w-64 w-max py-1 rounded-md bg-base-200 border border-base-content/10 shadow-lg"
      >
        <%= for item <- @menu.items do %>
          <hr :if={item == :separator} class="my-1 border-base-content/10" />
          <button
            :if={item != :separator}
            data-command={item.command}
            role="menuitem"
            disabled={item.disabled}
            class="w-full flex items-center gap-2 px-3 py-1 text-left cursor-pointer hover:bg-primary hover:text-primary-content disabled:opacity-40 disabled:pointer-events-none"
            phx-click="run_command"
            phx-value-command={item.command}
          >
            <span class="w-4 shrink-0">
              <.icon :if={item.checked} name="hero-check-micro" class="size-3.5" />
            </span>
            <span class="flex-1 whitespace-nowrap">{item.label}</span>
            <span :if={item.shortcut} class="opacity-60 pl-4">{item.shortcut}</span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :pressed, :boolean, required: true
  attr :command, :string, required: true
  slot :inner_block, required: true

  defp layout_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      title={@title}
      aria-pressed={to_string(@pressed)}
      class="size-7 grid place-items-center rounded cursor-pointer hover:bg-base-content/10"
      phx-click="run_command"
      phx-value-command={@command}
    >
      <svg viewBox="0 0 16 16" class="size-4" aria-hidden="true">
        {render_slot(@inner_block)}
      </svg>
    </button>
    """
  end
end

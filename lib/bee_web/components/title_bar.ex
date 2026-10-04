defmodule BeeWeb.TitleBar do
  @moduledoc """
  VS Code–style title bar: menus on the left, the window title in the
  middle and layout toggles on the right.

  Which menu is open is server state (`open_menu`), driven by the
  `toggle_menu` / `close_menu` events. Menu items push the same events as
  the keyboard shortcuts, then close the menu.
  """
  use BeeWeb, :html

  attr :title, :string, required: true
  attr :open_menu, :string, default: nil
  attr :has_editor, :boolean, required: true
  attr :has_terminal, :boolean, required: true
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
        <span class="px-2 text-base" aria-hidden="true">🐝</span>

        <.menu id="file" label="File" open_menu={@open_menu}>
          <.menu_item
            id="menu-file-save"
            label="Save"
            shortcut="Ctrl+S"
            disabled={!@has_editor}
            click={JS.dispatch("bee:save", to: "#editor")}
          />
          <.menu_item
            id="menu-file-close"
            label="Close Editor"
            disabled={!@has_editor}
            click={JS.push("close_active_tab")}
          />
        </.menu>

        <.menu id="view" label="View" open_menu={@open_menu}>
          <.menu_item
            id="menu-view-explorer"
            label="Explorer"
            shortcut="Ctrl+B"
            checked={@sidebar_open}
            click={JS.push("toggle_sidebar")}
          />
          <.menu_item
            id="menu-view-terminal"
            label="Terminal"
            shortcut="Ctrl+J"
            checked={@panel_open}
            click={JS.push("toggle_panel")}
          />
        </.menu>

        <.menu id="terminal" label="Terminal" open_menu={@open_menu}>
          <.menu_item id="menu-terminal-new" label="New Terminal" click={JS.push("new_terminal")} />
          <.menu_item
            id="menu-terminal-kill"
            label="Kill Terminal"
            disabled={!@has_terminal}
            click={JS.push("close_active_terminal")}
          />
        </.menu>
      </nav>

      <div id="window-title" class="truncate opacity-70 px-4">{@title}</div>

      <div class="flex items-center justify-end gap-0.5 pr-2">
        <.layout_toggle
          id="layout-sidebar"
          title="Toggle Primary Side Bar (Ctrl+B)"
          pressed={@sidebar_open}
          event="toggle_sidebar"
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
          title="Toggle Panel (Ctrl+J)"
          pressed={@panel_open}
          event="toggle_panel"
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

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :open_menu, :string, default: nil
  slot :inner_block, required: true

  defp menu(assigns) do
    ~H"""
    <div class="relative">
      <button
        id={"menu-#{@id}-button"}
        aria-expanded={to_string(@open_menu == @id)}
        class={[
          "px-2 py-1 rounded cursor-pointer hover:bg-base-content/10",
          @open_menu == @id && "bg-base-content/10"
        ]}
        phx-click="toggle_menu"
        phx-value-menu={@id}
      >
        {@label}
      </button>
      <div
        :if={@open_menu == @id}
        id={"menu-#{@id}"}
        role="menu"
        class="absolute left-0 top-full mt-1 z-40 min-w-56 py-1 rounded-md bg-base-200 border border-base-content/10 shadow-lg"
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :click, JS, required: true
  attr :shortcut, :string, default: nil
  attr :checked, :boolean, default: nil
  attr :disabled, :boolean, default: false

  defp menu_item(assigns) do
    ~H"""
    <button
      id={@id}
      role="menuitem"
      disabled={@disabled}
      class="w-full flex items-center gap-2 px-3 py-1 text-left cursor-pointer hover:bg-primary hover:text-primary-content disabled:opacity-40 disabled:pointer-events-none"
      phx-click={JS.push(@click, "close_menu")}
    >
      <span class="w-4 shrink-0">
        <.icon :if={@checked} name="hero-check-micro" class="size-3.5" />
      </span>
      <span class="flex-1">{@label}</span>
      <span :if={@shortcut} class="opacity-60">{@shortcut}</span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :pressed, :boolean, required: true
  attr :event, :string, required: true
  slot :inner_block, required: true

  defp layout_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      title={@title}
      aria-pressed={to_string(@pressed)}
      class="size-7 grid place-items-center rounded cursor-pointer hover:bg-base-content/10"
      phx-click={@event}
    >
      <svg viewBox="0 0 16 16" class="size-4" aria-hidden="true">
        {render_slot(@inner_block)}
      </svg>
    </button>
    """
  end
end

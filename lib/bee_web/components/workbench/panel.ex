defmodule BeeWeb.Workbench.Panel do
  @moduledoc """
  The bottom panel, VS Code style: its sections' tabs on the left (TERMINAL,
  BEE CONSOLE, plugins'), the shown section's buttons and the panel's own
  (maximize, close) on the right, the section below.

  Sections are panel views containers (`viewsContainers.panel` in a
  manifest, `Bee.Views.containers(:panel)`), each with its views. All of
  them stay rendered while the panel is open – the hidden ones invisible –
  so terminals keep their screens when another section is shown.

  How a view is drawn: Bee's own by `view_body/1` (one clause each – a new
  built-in section is a container and a view in
  `priv/contributions/bee.json` and a clause there), plugins' from their
  data like in the sidebar (`BeeWeb.Workbench.ContributedView`).

  The Terminal section lists its terminals on the right once there are two
  (`#terminal-list`): click to show one, drag to reorder (the TerminalList
  hook), hover for its kill button, right-click for
  `terminal/title/context` (rename, icon, colour, kill). With one, its name
  stands in the header instead. The sections' tabs can be dragged too
  (PanelSections; their order is remembered per workspace).
  """
  use BeeWeb, :html

  alias BeeWeb.Workbench.{ContributedView, Toolbar}

  attr :maximized, :boolean, required: true
  attr :active, :string, required: true, doc: "the shown section (container id)"

  attr :sections, :list,
    required: true,
    doc: "[%{container, views: [%{view, title_actions, item_actions}]}]"

  attr :actions, :list, required: true, doc: "the panel's own buttons (panel/title menu)"
  attr :terminals, :list, required: true
  attr :active_term, :any, required: true
  attr :console, :any, required: true, doc: "the Bee Console's terminal id, or nil"
  attr :terminal_settings, :map, required: true
  attr :view_contents, :map, required: true
  attr :view_inputs, :map, required: true
  attr :collapsed, :any, required: true
  attr :icon_theme, :any, default: nil

  def panel(assigns) do
    assigns =
      assign(assigns, :shown, Enum.find(assigns.sections, &(&1.container.id == assigns.active)))

    ~H"""
    <section
      id="panel"
      data-maximized={to_string(@maximized)}
      class={[
        "relative shrink-0 overflow-hidden border-t border-base-300 flex flex-col bg-base-100",
        if(@maximized,
          do: "h-[calc(100%-2.5rem)]",
          else: "h-[var(--drag-panel-height,var(--panel-height))] max-h-[calc(100%-4rem)]"
        )
      ]}
    >
      <div
        :if={!@maximized}
        id="sash-panel"
        phx-hook="Sash"
        data-part="panel"
        class="sash absolute inset-x-0 top-0 h-1 z-30 cursor-row-resize"
      >
      </div>
      <header class="flex items-center gap-1 h-9 pr-2 text-xs shrink-0 select-none border-b border-base-300">
        <%!-- The sections' tabs: click to show, drag to reorder (PanelSections). --%>
        <nav
          id="panel-sections"
          phx-hook="PanelSections"
          role="tablist"
          class="flex self-stretch mr-2"
        >
          <button
            :for={section <- @sections}
            id={"panel-section-#{section.container.id}"}
            data-section={section.container.id}
            type="button"
            role="tab"
            aria-selected={to_string(section.container.id == @active)}
            class={[
              "flex items-center gap-1.5 px-3 -mb-px border-b-2 cursor-pointer",
              "text-[11px] font-semibold uppercase tracking-wide",
              if(section.container.id == @active,
                do: "border-primary text-base-content bg-base-content/5",
                else:
                  "border-transparent text-base-content/50 hover:text-base-content hover:bg-base-content/5"
              )
            ]}
            phx-click="run_command"
            phx-value-command="workbench.action.showPanel"
            phx-value-args={Jason.encode!([section.container.id])}
          >
            <BeeWeb.Icons.named_icon name={section.container.icon} class="size-3.5 shrink-0" />
            {section.container.title}
          </button>
        </nav>
        <div class="flex-1" />
        <%!-- One terminal: its name here (with two or more, the list). --%>
        <.terminal_item
          :if={@active == "terminal" and length(@terminals) == 1}
          terminal={hd(@terminals)}
          class="px-2 py-0.5 rounded hover:bg-base-content/10"
        />
        <Toolbar.toolbar :for={v <- (@shown && @shown.views) || []} actions={v.title_actions} />
        <span class="w-px h-4 mx-1 bg-base-content/15" />
        <Toolbar.toolbar id="panel-actions" actions={@actions} />
      </header>
      <div class="flex-1 min-h-0 relative">
        <div
          :for={section <- @sections}
          id={"panel-body-#{section.container.id}"}
          class={[
            "absolute inset-0 flex",
            section.container.id != @active && "invisible"
          ]}
        >
          <.view_body
            :for={v <- section.views}
            view={v.view}
            item_actions={v.item_actions}
            terminals={@terminals}
            active_term={@active_term}
            console={@console}
            terminal_settings={@terminal_settings}
            view_contents={@view_contents}
            view_inputs={@view_inputs}
            collapsed={@collapsed}
            icon_theme={@icon_theme}
          />
        </div>
      </div>
    </section>
    """
  end

  ## Views

  # Room around an xterm view: insets, not padding – xterm's fit measures
  # the element it is in, padding included, and would overflow it by that.
  @term_inset "absolute left-3 right-2 top-2 bottom-2"

  # Bee's own panel views, by id; the rest are plugins'.
  defp view_body(%{view: %{id: "workbench.panel.terminal"}} = assigns) do
    assigns = assign(assigns, :term_inset, @term_inset)

    ~H"""
    <div class="flex-1 min-w-0 relative">
      <div
        :for={term <- @terminals}
        id={"term-#{term.id}"}
        phx-hook="Terminal"
        phx-update="ignore"
        data-id={term.id}
        data-active={to_string(term.id == @active_term)}
        data-settings={Jason.encode!(@terminal_settings)}
        class={[@term_inset, "data-[active=false]:invisible"]}
      >
      </div>
    </div>
    <ul
      :if={length(@terminals) > 1}
      id="terminal-list"
      phx-hook="TerminalList"
      role="listbox"
      class="w-44 shrink-0 overflow-y-auto border-l border-base-300 py-1 text-xs"
    >
      <li
        :for={term <- @terminals}
        data-term={term.id}
        role="option"
        aria-selected={to_string(term.id == @active_term)}
        class={[
          "group flex items-center pr-1",
          if(term.id == @active_term, do: "bg-base-content/10", else: "hover:bg-base-content/5")
        ]}
      >
        <.terminal_item terminal={term} class="flex-1 min-w-0 px-2 py-1" />
        <%!-- On hover, like VS Code's. Not a drag handle. --%>
        <button
          type="button"
          data-kill
          title="Kill Terminal"
          aria-label={"Kill #{term.name}"}
          class="size-5 shrink-0 place-items-center rounded cursor-pointer hidden group-hover:grid hover:bg-base-content/15"
          phx-click="run_command"
          phx-value-command="workbench.action.terminal.kill"
          phx-value-args={Jason.encode!([term.id])}
        >
          <.icon name="hero-trash" class="size-3.5" />
        </button>
      </li>
    </ul>
    """
  end

  defp view_body(%{view: %{id: "workbench.panel.console"}} = assigns) do
    assigns = assign(assigns, :term_inset, @term_inset)

    ~H"""
    <div class="flex-1 min-w-0 relative">
      <div
        :if={@console}
        id="bee-console"
        phx-hook="Terminal"
        phx-update="ignore"
        data-id={@console}
        data-active="true"
        data-settings={Jason.encode!(@terminal_settings)}
        class={@term_inset}
      >
      </div>
    </div>
    """
  end

  defp view_body(assigns) do
    ~H"""
    <div class="flex-1 min-w-0 overflow-auto">
      <ContributedView.contributed_view
        view={@view}
        content={@view_contents[@view.id]}
        input={Map.get(@view_inputs, @view.id, "")}
        collapsed={@collapsed}
        item_actions={@item_actions}
        icon_theme={@icon_theme}
      />
    </div>
    """
  end

  ## Terminals

  attr :terminal, :map, required: true
  attr :class, :any, default: nil

  # A terminal's icon and name: shows it, right-click for its menu.
  defp terminal_item(assigns) do
    ~H"""
    <button
      id={"term-tab-#{@terminal.id}"}
      type="button"
      title={@terminal.name}
      class={["flex items-center gap-1.5 text-left cursor-pointer", @class]}
      phx-click="activate_terminal"
      phx-value-id={@terminal.id}
      data-menu="terminal/title/context"
      data-menu-args={Jason.encode!([@terminal.id])}
      data-icon={@terminal.icon}
      data-color={@terminal.color}
    >
      <BeeWeb.Icons.named_icon
        name={@terminal.icon}
        class={["size-4 shrink-0", color_class(@terminal.color)]}
      />
      <span class="truncate">{@terminal.name}</span>
    </button>
    """
  end

  @doc "The text colour class of a terminal colour (`Bee.Workbench.terminal_colors/0`)."
  def color_class("red"), do: "text-red-400"
  def color_class("green"), do: "text-green-400"
  def color_class("yellow"), do: "text-yellow-400"
  def color_class("blue"), do: "text-blue-400"
  def color_class("magenta"), do: "text-fuchsia-400"
  def color_class("cyan"), do: "text-cyan-400"
  def color_class(_none), do: nil
end

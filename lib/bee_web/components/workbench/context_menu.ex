defmodule BeeWeb.Workbench.ContextMenu do
  @moduledoc """
  A right-click menu: the items of a contributed menu (`explorer/context`,
  …, see `BeeWeb.EditorLive.context_menu_items/1`) at the pointer, grouped
  with separators. An item runs its command with the arguments of the
  element right-clicked (client commands run in the page, still in the
  click). Closes on a click elsewhere or Escape; the
  ContextMenu hook keeps it inside the window.
  """
  use BeeWeb, :html

  attr :menu, :map, required: true, doc: "the workbench's context_menu"
  attr :items, :list, required: true, doc: "%{command, label, shortcut, disabled} or :separator"

  def context_menu(assigns) do
    ~H"""
    <div
      :if={@items != []}
      id="context-menu"
      role="menu"
      data-menu={@menu.menu}
      phx-hook="ContextMenu"
      phx-click-away="close_context_menu"
      phx-window-keydown="close_context_menu"
      phx-key="Escape"
      style={"left: #{@menu.x}px; top: #{@menu.y}px"}
      class="fixed z-50 min-w-52 w-max py-1 rounded-md bg-menu text-menu-fg border border-menu-border shadow-lg text-sm"
    >
      <%= for item <- @items do %>
        <hr :if={item == :separator} class="my-1 border-menu-border" />
        <button
          :if={item != :separator}
          type="button"
          role="menuitem"
          data-command={item.command}
          disabled={item.disabled}
          class="w-full flex items-center gap-2 px-3 py-1 text-left cursor-pointer hover:bg-menu-selection hover:text-menu-selection-fg disabled:opacity-40 disabled:pointer-events-none"
          phx-click={click(item, @menu)}
          phx-value-command={item.command}
          phx-value-args={Jason.encode!(@menu.args)}
        >
          <span class="flex-1 whitespace-nowrap">{item.label}</span>
          <span :if={item.shortcut} class="opacity-60 pl-6">{item.shortcut}</span>
        </button>
      <% end %>
    </div>
    """
  end

  # Client commands run in the page at once (`bee:run`, assets/js/app.js):
  # still in the click, as the clipboard wants. Others go to the server.
  defp click(%{runtime: :client, command: command}, menu) do
    JS.dispatch("bee:run", detail: %{command: command, args: menu.args})
    |> JS.push("close_context_menu")
  end

  defp click(_item, _menu), do: "run_command"
end

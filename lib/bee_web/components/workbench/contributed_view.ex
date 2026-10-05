defmodule BeeWeb.Workbench.ContributedView do
  @moduledoc """
  Renders a plugin's view from its data (`Bee.UI`): a message with buttons,
  an input box with an action, and a tree of items with inline buttons
  (`view/item/context` menu, group `inline`).

  Clicking an item with children folds it (`toggle_view_item`, state kept
  per window); clicking a leaf runs its command. The input box submits with
  Ctrl+Enter or its action button (`view_submit`).
  """
  use BeeWeb, :html

  alias BeeWeb.Workbench.Toolbar

  attr :view, :map, required: true
  attr :content, :map, default: nil, doc: "nil until the plugin sets it"
  attr :input, :string, default: ""
  attr :collapsed, :any, required: true, doc: "MapSet of {view_id, item_id}"
  attr :item_actions, :map, required: true, doc: "item context → inline actions"

  def contributed_view(%{content: nil} = assigns) do
    ~H"""
    <div class="px-4 py-2 text-xs opacity-50">Loading…</div>
    """
  end

  def contributed_view(assigns) do
    ~H"""
    <div class="text-sm pb-2">
      <form
        :if={@content.input}
        id={"view-input-#{@view.id}"}
        class="px-3 pt-1 pb-2 space-y-1.5"
        phx-change="view_input"
        phx-submit="view_submit"
      >
        <input type="hidden" name="view" value={@view.id} />
        <textarea
          name="value"
          rows="1"
          phx-hook="ViewInput"
          id={"view-input-#{@view.id}-text"}
          placeholder={@content.input.placeholder}
          class="textarea textarea-sm w-full min-h-8 field-sizing-content resize-none leading-snug"
        >{@input}</textarea>
        <button
          :if={@content.input.action}
          type="submit"
          class="btn btn-primary btn-sm w-full"
        >
          {@content.input.action}
        </button>
      </form>

      <div :if={@content.message} class="px-4 py-1 text-xs opacity-70 whitespace-pre-line">
        {@content.message}
      </div>
      <div :if={@content.buttons != []} class="px-4 py-2 space-y-2">
        <button
          :for={button <- @content.buttons}
          type="button"
          class="btn btn-primary btn-sm w-full"
          phx-click="run_command"
          phx-value-command={button.command}
          phx-value-args={Jason.encode!(button.arguments)}
        >
          {button.label}
        </button>
      </div>

      <ul role="tree">
        <.item
          :for={item <- @content.items}
          item={item}
          depth={0}
          view={@view}
          collapsed={@collapsed}
          item_actions={@item_actions}
        />
      </ul>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :depth, :integer, required: true
  attr :view, :map, required: true
  attr :collapsed, :any, required: true
  attr :item_actions, :map, required: true

  defp item(assigns) do
    assigns =
      assign(assigns,
        open: open?(assigns.item, assigns.view.id, assigns.collapsed),
        actions: Map.get(assigns.item_actions, assigns.item.context, [])
      )

    ~H"""
    <li role="treeitem" aria-expanded={@item.children != [] && to_string(@open)}>
      <div
        id={"view-item-#{@view.id}-#{@item.id}"}
        data-item={@item.id}
        class="group flex items-center gap-1 pr-2 py-0.5 cursor-pointer hover:bg-base-content/10"
        style={"padding-left: #{0.5 + @depth * 0.75}rem"}
        title={@item.tooltip}
        phx-click={click(@item, @view.id)}
        phx-value-view={@view.id}
        phx-value-item={@item.id}
        phx-value-command={@item.command && @item.command.command}
        phx-value-args={@item.command && Jason.encode!(@item.command.arguments)}
      >
        <span class="w-4 shrink-0 grid place-items-center opacity-70">
          <.icon
            :if={@item.children != []}
            name={if @open, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
            class="size-4"
          />
        </span>
        <BeeWeb.Icons.named_icon :if={@item.icon} name={@item.icon} class="size-4 opacity-80" />
        <span class={["truncate", color(@item.decoration)]}>{@item.label}</span>
        <span :if={@item.description} class="truncate shrink-[4] text-xs opacity-50">
          {@item.description}
        </span>
        <span class="flex-1" />
        <Toolbar.toolbar
          actions={@actions}
          args={@item.arguments}
          class="hidden group-hover:flex"
        />
        <span
          :if={@item.decoration}
          class={["w-4 text-center text-xs font-semibold shrink-0", color(@item.decoration)]}
        >
          {@item.decoration.text}
        </span>
      </div>
      <ul :if={@item.children != [] and @open} role="group">
        <.item
          :for={child <- @item.children}
          item={child}
          depth={@depth + 1}
          view={@view}
          collapsed={@collapsed}
          item_actions={@item_actions}
        />
      </ul>
    </li>
    """
  end

  # `expanded` is the initial state; the user's folding flips it.
  defp open?(item, view_id, collapsed),
    do: item.expanded != MapSet.member?(collapsed, {view_id, item.id})

  defp click(%{children: [_ | _]}, _view), do: "toggle_view_item"
  defp click(%{command: %{}}, _view), do: "run_command"
  defp click(_item, _view), do: nil

  defp color(decoration), do: BeeWeb.Workbench.Decoration.color_class(decoration)
end

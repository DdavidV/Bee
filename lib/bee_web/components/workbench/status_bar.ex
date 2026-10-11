defmodule BeeWeb.Workbench.StatusBar do
  @moduledoc """
  Parts of the status bar.
  """

  use BeeWeb, :html

  attr :item, :map, required: true

  # A plugin's status bar item (Bee.UI).
  def status_item(assigns) do
    ~H"""
    <button
      id={"status-item-#{@item.owner}-#{@item.id}"}
      type="button"
      class={[
        "flex items-center gap-1 px-1 rounded shrink-0",
        @item.command && "cursor-pointer hover:bg-statusbar-fg/15"
      ]}
      title={@item.tooltip}
      disabled={!@item.command}
      phx-click={@item.command && "run_command"}
      phx-value-command={@item.command}
      phx-value-args={@item.command && Jason.encode!(@item.arguments)}
    >
      <BeeWeb.Icons.named_icon :if={@item.icon} name={@item.icon} class="size-3.5" />
      <span>{@item.text}</span>
    </button>
    """
  end
end

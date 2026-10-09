defmodule BeeWeb.Workbench.Toolbar do
  @moduledoc """
  Icon buttons for the commands of an icon menu (`editor/title`,
  `view/title`, `view/item/context`), as built by
  `BeeWeb.EditorLive.toolbar/3`: `%{command, label, icon, disabled}`.
  A command without an icon is a text button (its title), like VS Code's
  Install button on a marketplace result (`text_class` styles those).
  """
  use BeeWeb, :html

  attr :actions, :list, required: true
  attr :args, :list, default: nil, doc: "arguments for the commands (view items)"
  attr :class, :any, default: nil
  attr :id, :string, default: nil
  attr :text_class, :any, default: "btn-ghost", doc: "for text buttons"

  def toolbar(assigns) do
    ~H"""
    <span :if={@actions != []} id={@id} class={["flex items-center gap-0.5", @class]}>
      <button
        :for={action <- @actions}
        type="button"
        class={[
          "btn btn-xs",
          if(BeeWeb.Icons.exists?(action.icon || ""),
            do: "btn-ghost btn-square",
            else: ["px-1 font-normal", @text_class]
          )
        ]}
        title={action.label}
        aria-label={action.label}
        disabled={action.disabled}
        data-command={action.command}
        phx-click="run_command"
        phx-value-command={action.command}
        phx-value-args={@args && Jason.encode!(@args)}
      >
        <BeeWeb.Icons.named_icon name={action.icon} class="size-4" />
        <span :if={!BeeWeb.Icons.exists?(action.icon || "")} class="text-xs">
          {action.label}
        </span>
      </button>
    </span>
    """
  end
end

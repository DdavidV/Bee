defmodule BeeWeb.Workbench.CommandPalette do
  @moduledoc """
  The command center in the middle of the title bar, as in VS Code.

  Closed, it shows the window title; clicking it (or Ctrl+Shift+P / F1)
  turns it into the palette input in place, with the matching commands and
  their keybindings dropping down below. Plugins use the same widget to ask
  the user (`Bee.API.quick_pick/4`, `input_box/3`): see
  `Bee.Workbench.open_palette/1` for the modes. Enter submits the form
  (`palette_run`); arrow keys and Escape are handled by the LiveView
  (`palette_key`). The `Palette` hook focuses the input and gives focus back
  to where it was when the palette closes.
  """
  use BeeWeb, :html

  attr :title, :string, required: true
  attr :palette, :map, default: nil, doc: "nil when closed, else %{mode, query, index, …}"
  attr :items, :list, default: []
  attr :shortcut, :string, default: nil, doc: "label of the showCommands keybinding"

  def command_center(%{palette: nil} = assigns) do
    ~H"""
    <button
      id="command-center"
      title={"Show All Commands#{@shortcut && " (#{@shortcut})"}"}
      class="w-[32rem] max-w-full h-6 flex items-center justify-center gap-2 px-3 rounded-md border border-base-content/15 bg-base-100/50 hover:bg-base-100 cursor-pointer"
      phx-click="run_command"
      phx-value-command="workbench.action.showCommands"
    >
      <.icon name="hero-magnifying-glass-micro" class="size-3.5 opacity-60 shrink-0" />
      <span id="window-title" class="truncate opacity-80">{@title}</span>
    </button>
    """
  end

  def command_center(assigns) do
    ~H"""
    <div
      id="palette"
      phx-hook="Palette"
      class="relative w-[32rem] max-w-full"
      phx-click-away="close_palette"
    >
      <form id="palette-form" phx-change="palette_filter" phx-submit="palette_run">
        <input
          id="palette-input"
          name="query"
          value={@palette.query}
          autocomplete="off"
          spellcheck="false"
          placeholder={placeholder(@palette)}
          phx-keydown="palette_key"
          class="w-full h-6 px-3 rounded-md text-xs bg-base-100 border border-primary outline-none select-text"
        />
      </form>
      <ul
        id="palette-items"
        role="listbox"
        class="absolute left-0 right-0 top-full mt-1 z-50 max-h-[60vh] overflow-auto py-1 rounded-md bg-base-200 border border-base-content/10 shadow-2xl text-sm"
      >
        <li :if={@palette.mode == :input} id="palette-prompt" class="px-4 py-1.5 opacity-80">
          {if @palette.prompt != "", do: @palette.prompt <> " ", else: ""}(Press 'Enter' to confirm or 'Escape' to cancel)
        </li>
        <li :if={@items == [] and @palette.mode != :input} class="px-4 py-2 opacity-60">
          {if @palette.mode == :pick, do: "No matching items", else: "No matching commands"}
        </li>
        <li :for={{item, i} <- Enum.with_index(@items)}>
          <button
            :if={item.id == nil}
            data-pick={item.key}
            role="option"
            aria-selected={to_string(i == @palette.index)}
            class={[
              "w-full flex gap-3 px-4 py-1 text-left cursor-pointer",
              if(i == @palette.index,
                do: "bg-primary text-primary-content",
                else: "hover:bg-base-content/10"
              )
            ]}
            phx-click="palette_pick"
            phx-value-index={i}
          >
            <span class="truncate">{item.label}</span>
            <span :if={item.description != ""} class="truncate opacity-60">{item.description}</span>
          </button>
          <button
            :if={item.id != nil}
            data-command={item.id}
            role="option"
            aria-selected={to_string(i == @palette.index)}
            class={[
              "w-full flex justify-between gap-4 px-4 py-1 text-left cursor-pointer",
              if(i == @palette.index,
                do: "bg-primary text-primary-content",
                else: "hover:bg-base-content/10"
              )
            ]}
            phx-click="run_command"
            phx-value-command={item.id}
          >
            <span class="truncate">{item.label}</span>
            <span :if={item.shortcut} class="opacity-70 shrink-0">{item.shortcut}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp placeholder(%{mode: :commands}), do: "Type the name of a command"
  defp placeholder(%{placeholder: placeholder}), do: placeholder
end

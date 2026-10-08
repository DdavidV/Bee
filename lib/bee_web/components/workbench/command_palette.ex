defmodule BeeWeb.Workbench.CommandPalette do
  @moduledoc """
  The command center in the middle of the title bar, as in VS Code.

  Closed, it shows the window title; clicking it (or Ctrl+P) turns it into
  Quick Open in place: the recently opened files, files by name as you
  type, commands after `>` (Ctrl+Shift+P / F1 open it that way), with the
  matches dropping down below (`Bee.Workbench.QuickOpen`). Plugins use the
  same widget to ask the user (`Bee.API.quick_pick/4`, `input_box/3`): see
  `Bee.Workbench.open_quick_open/2` for the modes. Enter submits the form
  (`palette_run`); arrow keys and Escape are handled by the LiveView
  (`palette_key`). The `Palette` hook focuses the input, gives focus back to
  where it was when the palette closes, and sets the query when Bee does
  (`palette:query`).

  Items have a `kind`: `:command` (`id`, `label`, `shortcut`), `:pick`
  (`label`, `description`), `:file` (`path`, `label`, `description`) or
  `:mode` (`prefix`, `label`); any may have a `section` title, shown on the
  first item of a group, and an `icon` (a Heroicons outline name) with a
  `color` (a terminal colour, `BeeWeb.Workbench.Panel.color_class/1`).
  """
  use BeeWeb, :html

  attr :title, :string, required: true
  attr :palette, :map, default: nil, doc: "nil when closed, else %{mode, query, index, …}"
  attr :items, :list, default: []
  attr :shortcut, :string, default: nil, doc: "label of the quickOpen keybinding"
  attr :icon_theme, :any, default: nil
  attr :busy, :boolean, default: false, doc: "Quick Open is still looking for files"

  def command_center(%{palette: nil} = assigns) do
    ~H"""
    <button
      id="command-center"
      title={"Search files by name, > for commands#{@shortcut && " (#{@shortcut})"}"}
      class="w-[32rem] max-w-full h-6 flex items-center justify-center gap-2 px-3 rounded-md border border-input-border bg-input/50 text-input-fg hover:bg-input cursor-pointer"
      phx-click="run_command"
      phx-value-command="workbench.action.quickOpen"
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
          class="w-full h-6 px-3 rounded-md text-xs bg-input text-input-fg border border-focus outline-none select-text"
        />
        <span
          :if={@busy}
          id="palette-busy"
          class="absolute right-2 top-1 text-xs opacity-60 pointer-events-none"
        >
          Searching…
        </span>
      </form>
      <ul
        id="palette-items"
        role="listbox"
        class="absolute left-0 right-0 top-full mt-1 z-50 max-h-[60vh] overflow-auto py-1 rounded-md bg-quickinput text-quickinput-fg border border-widget-border shadow-2xl text-sm"
      >
        <li :if={@palette.mode == :input} id="palette-prompt" class="px-4 py-1.5 opacity-80">
          {if @palette.prompt != "", do: @palette.prompt <> " ", else: ""}(Press 'Enter' to confirm or 'Escape' to cancel)
        </li>
        <li :if={@items == [] and @palette.mode != :input} class="px-4 py-2 opacity-60">
          {if @busy, do: "Searching…", else: empty(@palette)}
        </li>
        <li :for={{item, i} <- Enum.with_index(@items)}>
          <button
            role="option"
            aria-selected={to_string(i == @palette.index)}
            class={[
              "w-full flex items-center gap-2 px-4 py-1 text-left cursor-pointer",
              if(i == @palette.index,
                do: "bg-quickinput-focus text-quickinput-focus-fg",
                else: "hover:bg-list-hover"
              )
            ]}
            phx-click="palette_pick"
            phx-value-index={i}
            {item_data(item)}
          >
            <BeeWeb.Icons.named_icon
              :if={item[:icon]}
              name={item.icon}
              class={["size-4 shrink-0", BeeWeb.Workbench.Panel.color_class(item[:color])]}
            />
            <BeeWeb.Workbench.FileIcon.file_icon
              :if={item.kind == :file}
              theme={@icon_theme}
              path={item.path}
              class="shrink-0"
            />
            <span class="truncate shrink-0 max-w-[60%]">{item.label}</span>
            <span :if={item[:description] not in [nil, ""]} class="truncate opacity-60 text-xs">
              {item.description}
            </span>
            <span class="flex-1"></span>
            <span :if={item[:section]} class="opacity-60 text-xs shrink-0">{item.section}</span>
            <span :if={item[:shortcut]} class="opacity-70 shrink-0">{item.shortcut}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp placeholder(%{mode: :quick_open}), do: "Search files by name (type > for commands)"
  defp placeholder(%{placeholder: placeholder}), do: placeholder

  defp empty(%{mode: :pick}), do: "No matching items"

  defp empty(%{query: query}) do
    case Bee.Workbench.QuickOpen.mode(query) do
      {:commands, _} -> "No matching commands"
      :recent -> "No recently opened files"
      {:files, _} -> "No matching files"
    end
  end

  # What tests and scripts find an item by.
  defp item_data(%{kind: :command, id: id}), do: %{"data-command" => id}
  defp item_data(%{kind: :pick, key: key}), do: %{"data-pick" => key}
  defp item_data(%{kind: :file, path: path}), do: %{"data-file" => path}
  defp item_data(%{kind: :mode, prefix: prefix}), do: %{"data-mode" => prefix}
end

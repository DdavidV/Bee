defmodule BeeWeb.Workbench.DiffView do
  @moduledoc """
  Two documents an extension compares (`vscode.diff`), in an editor tab:
  the lines that differ (`Bee.Diff`) with the lines around them, each with
  its number in the original and in the modified document – removed lines
  red, added ones green, like an inline diff in VS Code. It is for
  reading: what is done with it (accepted, rejected) is the extension's
  buttons in the tab's bar (`editor/title`).
  """
  use BeeWeb, :html

  attr :diff, :map, required: true, doc: "%{id, title, original, modified, rows}"
  attr :active, :boolean, default: false

  def diff_view(assigns) do
    ~H"""
    <div
      id={"diff-#{@diff.id}"}
      data-diff={@diff.id}
      class={[
        "absolute inset-0 overflow-auto bg-editor text-editor-fg font-mono text-[13px] leading-5 select-text",
        !@active && "hidden"
      ]}
    >
      <p :if={@diff.rows == []} data-diff-same class="px-4 py-3 font-sans text-sm opacity-60">
        No differences.
      </p>
      <table :if={@diff.rows != []} class="min-w-full border-collapse">
        <tbody>
          <%= for row <- @diff.rows do %>
            <tr :if={row == :gap} data-diff-gap class="opacity-50 select-none">
              <td colspan="4" class="px-3 border-y border-base-content/10">⋯</td>
            </tr>
            <tr :if={row != :gap} data-diff-row={elem(row, 0)} class={row_class(elem(row, 0))}>
              <td class="w-12 px-2 text-right opacity-50 select-none">{elem(row, 1)}</td>
              <td class="w-12 px-2 text-right opacity-50 select-none">{elem(row, 2)}</td>
              <td class="w-5 text-center opacity-70 select-none">{sign(elem(row, 0))}</td>
              <td class="pr-4 whitespace-pre">{elem(row, 3)}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp row_class(:del), do: "bg-error/15"
  defp row_class(:ins), do: "bg-success/15"
  defp row_class(:eq), do: nil

  defp sign(:del), do: "−"
  defp sign(:ins), do: "+"
  defp sign(:eq), do: ""
end

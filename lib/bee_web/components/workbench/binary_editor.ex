defmodule BeeWeb.Workbench.BinaryEditor do
  @moduledoc """
  What an editor shows of a file that isn't opened as text (and is no
  image, audio or video either), as VS Code says it: that it is binary, or
  very large (`workbench.editorLargeFileConfirmation`) – and a way to open
  it as text all the same (Open Anyway: `workbench.action.reopenTextEditor`).
  """

  use BeeWeb, :html

  attr :tab, :map, required: true, doc: "the tab: `%{kind: :binary, reason, path, size}`"
  attr :group, :integer, required: true
  attr :limit, :any, default: nil, doc: "the size (MB) from which a file is very large"

  def binary_editor(assigns) do
    assigns = assign(assigns, large: assigns.tab[:reason] == :large)

    ~H"""
    <div
      data-binary-editor={@tab.path}
      data-reason={if @large, do: "large", else: "binary"}
      class="absolute inset-0 grid place-items-center overflow-auto bg-editor text-editor-fg text-sm"
    >
      <div class="max-w-md p-6 text-center space-y-3">
        <.icon name="hero-exclamation-triangle" class="size-12 opacity-60" />
        <p :if={@large}>
          The file is not displayed in the text editor because it is very large ({format_size(
            @tab.size
          )}).
        </p>
        <p :if={!@large}>
          The file is not displayed in the text editor because it is either binary or uses an unsupported text encoding.
        </p>
        <div class="flex flex-wrap justify-center gap-x-4 gap-y-1">
          <button
            type="button"
            class="link link-primary cursor-pointer"
            phx-click="run_command"
            phx-value-command="workbench.action.reopenTextEditor"
            phx-value-args={Jason.encode!([@tab.path, @group])}
          >
            Open Anyway
          </button>
          <button
            :if={@large}
            type="button"
            class="link link-primary cursor-pointer"
            title={@limit && "Now: #{@limit} MB"}
            phx-click="run_command"
            phx-value-command="workbench.action.openSettings"
            phx-value-args={Jason.encode!(["workbench.editorLargeFileConfirmation"])}
          >
            Configure Limit
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc "A file's size as VS Code writes it: `512B`, `1.50KB`, `2.25MB`."
  def format_size(bytes) when bytes < 1024, do: "#{bytes}B"
  def format_size(bytes), do: format_size(bytes / 1024, ~w(KB MB GB TB))

  defp format_size(value, [unit | units]) when value < 1024 or units == [],
    do: "#{:erlang.float_to_binary(value, decimals: 2)}#{unit}"

  defp format_size(value, [_unit | units]), do: format_size(value / 1024, units)
end

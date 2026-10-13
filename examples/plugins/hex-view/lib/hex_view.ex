defmodule HexView do
  @moduledoc """
  The server part: nothing but the command that opens a file in the
  plugin's editor. The editor itself is `HexView.EditorLive`, which the
  manifest names under `contributes.customEditors`.
  """
  use Bee.Plugin

  @editor "hexView.editor"

  @impl true
  def activate(_ctx), do: {:ok, %{}}

  # From the Explorer's right-click menu (the file's path is the
  # argument), or from the palette (the active editor's file).
  @command "hexView.open"
  def open(%{args: [path | _]} = ctx, _state) when is_binary(path),
    do: Bee.API.open_file(ctx, path, with: @editor)

  def open(%{active_editor: path} = ctx, _state) when is_binary(path),
    do: Bee.API.open_file(ctx, path, with: @editor)

  def open(ctx, _state), do: Bee.API.show_message(ctx, :error, "Open a file first")
end

defmodule Bee.API do
  @moduledoc """
  What plugin server code may use (from Erlang: `'Elixir.Bee.API':text(Path)`).

  Functions taking a context (`Bee.Plugins.Context`) act on the window that
  ran the command; with a context from `activate/1` or an event (no window),
  on every open window. They return at once: windows are separate processes
  and handle the request when they get to it.

  Text positions are UTF-8 byte offsets, as in Elixir binaries.
  """

  alias Bee.Editor.Buffer
  alias Bee.Plugins.Context

  @windows_topic "windows"

  @doc false
  def subscribe_window, do: Phoenix.PubSub.subscribe(Bee.PubSub, @windows_topic)

  ## Window

  @doc "Shows a notification. `level` is `:info` or `:error`."
  def show_message(%Context{} = ctx, level \\ :info, text) when level in [:info, :error],
    do: window(ctx, {:show_message, level, to_string(text)})

  @doc "Shows `text` in the status bar."
  def set_status(%Context{} = ctx, text), do: window(ctx, {:set_status, to_string(text)})

  @doc "Opens `path` (absolute, or relative to the workspace) in an editor."
  def open_file(%Context{} = ctx, path) do
    window(ctx, {:open_file, Path.expand(to_string(path), Bee.Workspace.root())})
  end

  @doc "Runs a command (Bee's or a plugin's), as if the user had."
  def execute_command(%Context{} = ctx, id), do: window(ctx, {:execute_command, to_string(id)})

  ## Text

  @doc "Current text of `path`: the open buffer's (with unsaved changes) or the file's."
  def text(nil), do: nil

  def text(path) do
    path = to_string(path)

    case Registry.lookup(Bee.Registry, {:buffer, path}) do
      [{_pid, _}] -> Buffer.get(path).text
      [] -> with {:ok, text} <- File.read(path), do: text, else: (_ -> nil)
    end
  catch
    :exit, _ -> nil
  end

  @doc "Selections of the active editor, `[{from, to}]`."
  def selections(%Context{selections: selections}), do: selections

  @doc "The active editor's selections with their text, `[{from, to, text}]`."
  def selected(%Context{active_editor: nil}), do: []

  def selected(%Context{active_editor: path, selections: selections}) do
    text = text(path) || ""

    for {from, to} <- selections,
        to <= byte_size(text),
        do: {from, to, binary_part(text, from, to - from)}
  end

  @doc """
  Changes an open file: `edits` are `[{from, to, new_text}]` against its
  current text (see `text/1`). The change shows up in every editor of the
  file and can be undone there. `{:error, :not_open}` for files no editor has open.
  """
  def edit(path, edits), do: with({:ok, _} <- Buffer.edit(to_string(path), edits), do: :ok)

  ## Settings, workspace

  @doc "The value of a setting (Bee's or a plugin's)."
  def setting(key), do: Bee.Settings.get(to_string(key))

  def workspace_root, do: Bee.Workspace.root()

  ## Internals

  defp window(%Context{window: nil}, request),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, @windows_topic, {:bee_api, request})

  defp window(%Context{window: pid}, request) do
    send(pid, {:bee_api, request})
    :ok
  end
end

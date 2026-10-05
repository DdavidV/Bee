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

  @doc """
  Opens `path` (absolute, or relative to the workspace) in an editor.
  Options: `line:` (1-based) to go to, or `selection: {from, to}` (UTF-8 byte
  offsets) to select.
  """
  def open_file(%Context{} = ctx, path, opts \\ []) do
    reveal =
      cond do
        line = opts[:line] -> %{line: line}
        sel = opts[:selection] -> %{from: elem(sel, 0), to: elem(sel, 1)}
        true -> nil
      end

    window(ctx, {:open_file, Path.expand(to_string(path), Bee.Workspace.root()), reveal})
  end

  ## Views and status bar (see Bee.UI for the data)

  @doc """
  Sets the content of one of the plugin's views (declared in its manifest
  under `contributes.views`). Every window shows it. Raises for bad content
  or a view of someone else.
  """
  def set_view(%Context{plugin: plugin}, view_id, content) do
    view_id = to_string(view_id)

    case Bee.Views.plugin(view_id) do
      ^plugin -> Bee.UI.put_view(plugin, view_id, content)
      _ -> raise ArgumentError, "#{plugin} has no view #{inspect(view_id)}"
    end
  end

  @doc "Empties the input box of a view (e.g. after a commit) in the context's window(s)."
  def clear_view_input(%Context{} = ctx, view_id),
    do: window(ctx, {:set_view_input, to_string(view_id), ""})

  @doc """
  Adds or updates a status bar item of the plugin, in every window: `%{text,
  icon, tooltip, command, arguments, alignment: :left | :right, priority}`.
  """
  def set_status_item(%Context{plugin: plugin}, id, item),
    do: Bee.UI.put_status_item(plugin, to_string(id), item)

  def remove_status_item(%Context{plugin: plugin}, id),
    do: Bee.UI.delete_status_item(plugin, to_string(id))

  @doc """
  Colours and badges for files in the Explorer and editor tabs, like a VS
  Code FileDecorationProvider: `%{path => %{badge: "M", color: "modified",
  tooltip: "Modified"}}`, paths absolute or workspace-relative; replaces
  the plugin's previous ones. Colours: `"modified"`, `"added"`,
  `"untracked"`, `"deleted"`, `"conflict"`, `"ignored"`. Folders take the
  colour of what they contain.
  """
  def set_file_decorations(%Context{plugin: plugin}, decorations),
    do: Bee.UI.put_decorations(plugin, decorations)

  @doc """
  Sets a context key for `when` clauses (enablement, menus, keybindings,
  views) in every window, like VS Code's `setContext`. `nil` removes it.
  Name keys after the plugin, e.g. `"git.repository"`.
  """
  def set_context(%Context{plugin: plugin}, key, value),
    do: Bee.UI.put_context(plugin, to_string(key), value)

  ## Asking the user

  @doc """
  Asks for a line of text in the title bar's input. When the user presses
  Enter, `command` runs with `arguments ++ [text]`; Escape cancels. Returns
  at once. Options: `:prompt`, `:placeholder`, `:value`, `:arguments`.
  """
  def input_box(%Context{} = ctx, command, opts \\ []) do
    window(ctx, {
      :input_box,
      %{
        command: to_string(command),
        arguments: opts[:arguments] || [],
        prompt: to_string(opts[:prompt] || ""),
        placeholder: to_string(opts[:placeholder] || ""),
        value: to_string(opts[:value] || "")
      }
    })
  end

  @doc """
  Lets the user pick one of `items` – `%{label, description, value}`, value
  being JSON-encodable – in the title bar. The pick runs `command` with
  `arguments ++ [value]`. Returns at once. Options: `:placeholder`, `:arguments`.
  """
  def quick_pick(%Context{} = ctx, items, command, opts \\ []) do
    items =
      for item <- items do
        label = Map.get(item, :label) || Map.get(item, "label")

        %{
          label: to_string(label),
          description:
            to_string(Map.get(item, :description) || Map.get(item, "description") || ""),
          value: Map.get(item, :value, Map.get(item, "value", label))
        }
      end

    window(ctx, {
      :quick_pick,
      %{
        command: to_string(command),
        arguments: opts[:arguments] || [],
        placeholder: to_string(opts[:placeholder] || ""),
        items: items
      }
    })
  end

  ## The plugin's browser part

  @doc "Sends `data` (JSON-encodable) to the plugin's browser part: `bee.onMessage(fn)`."
  def post_message(%Context{plugin: plugin} = ctx, data),
    do: window(ctx, {:post_message, plugin, data})

  @doc false
  # The answer to a bee.request() (see Bee.Plugins.request/5).
  def reply(%Context{} = ctx, ref, result), do: window(ctx, {:reply, ref, result})

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

  @doc "Every file of the workspace, relative to its root, without `files.exclude`d ones."
  def workspace_files, do: Bee.Workspace.files()

  ## Internals

  defp window(%Context{window: nil}, request),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, @windows_topic, {:bee_api, request})

  defp window(%Context{window: pid}, request) do
    send(pid, {:bee_api, request})
    :ok
  end
end

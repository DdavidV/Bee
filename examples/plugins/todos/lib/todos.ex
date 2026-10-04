defmodule Todos do
  @moduledoc """
  Finds TODO and FIXME comments in the workspace (files read in parallel)
  and shows them in a view of their own, with a count in the status bar.
  Rescans when files change. Its browser part highlights them in the editor
  and asks this module for counts on hover.
  """
  use Bee.Plugin

  @view "todos.list"
  @pattern ~r/\b(TODO|FIXME)\b:?\s*(.*)$/
  @max_size 1_000_000

  @impl true
  def activate(ctx) do
    state = %{ctx: ctx, todos: [], hidden: MapSet.new(), timer: nil}
    {:ok, publish(%{state | todos: scan()})}
  end

  ## Commands

  @command "todos.refresh"
  def refresh(_ctx, state), do: {:ok, publish(%{state | todos: scan()})}

  # From the view's input box or the palette (then it asks for the text).
  @command "todos.add"
  def add(%{args: [text | _]} = ctx, state) when text != "" do
    path = Path.join(Bee.API.workspace_root(), "TODO.md")
    File.write!(path, "- TODO: #{String.trim(text)}\n", [:append])
    Bee.API.clear_view_input(ctx, @view)
    Bee.API.show_message(ctx, :info, "Added to TODO.md")
    {:ok, publish(%{state | todos: scan()})}
  end

  def add(ctx, _state),
    do: Bee.API.input_box(ctx, "todos.add", prompt: "What needs doing?", placeholder: "TODO text")

  @command "todos.goTo"
  def go_to(ctx, state) do
    items =
      for todo <- visible(state) do
        %{label: todo.text, description: "#{todo.path}:#{todo.line}", value: [todo.path, todo.line]}
      end

    Bee.API.quick_pick(ctx, items, "todos.open", placeholder: "Go to a TODO")
  end

  # [path, line] from a view item, or [[path, line]] from the quick pick.
  @command "todos.open"
  def open(%{args: [[path, line]]} = ctx, _state), do: Bee.API.open_file(ctx, path, line: line)
  def open(%{args: [path, line]} = ctx, _state), do: Bee.API.open_file(ctx, path, line: line)

  @command "todos.hide"
  def hide(%{args: [id]}, state),
    do: {:ok, publish(%{state | hidden: MapSet.put(state.hidden, id)})}

  @command "todos.showHidden"
  def show_hidden(_ctx, state), do: {:ok, publish(%{state | hidden: MapSet.new()})}

  ## Browser part

  @impl true
  def handle_request("count", %{"path" => path}, _ctx, state) do
    rel = Path.relative_to(path, Bee.API.workspace_root())
    {:reply, %{file: Enum.count(state.todos, &(&1.path == rel)), total: length(state.todos)}}
  end

  ## Keeping up with the files

  @impl true
  def handle_event({:fs_changed, _path}, state), do: {:ok, rescan_soon(state)}
  def handle_event({:buffer_saved, _path}, state), do: {:ok, rescan_soon(state)}
  def handle_event(_event, _state), do: :ok

  @impl true
  def handle_info(:rescan, state), do: {:ok, publish(%{state | todos: scan(), timer: nil})}

  # Bursts of file events lead to one scan.
  defp rescan_soon(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(state.ctx.host, :rescan, 300)}

  defp rescan_soon(state), do: state

  ## Scanning

  defp scan do
    root = Bee.API.workspace_root()

    Bee.API.workspace_files()
    |> Task.async_stream(&scan_file(root, &1), ordered: true, timeout: 10_000)
    |> Enum.flat_map(fn {:ok, todos} -> todos end)
  end

  defp scan_file(root, rel) do
    with {:ok, %{size: size}} when size < @max_size <- File.stat(Path.join(root, rel)),
         {:ok, text} <- File.read(Path.join(root, rel)),
         true <- String.valid?(text) do
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        case Regex.run(@pattern, line) do
          [_, kind, text] -> [%{path: rel, line: n, kind: kind, text: "#{kind}: #{text}"}]
          nil -> []
        end
      end)
    else
      _ -> []
    end
  end

  ## Showing

  defp visible(state), do: Enum.reject(state.todos, &MapSet.member?(state.hidden, id(&1)))

  defp id(todo), do: "#{todo.path}:#{todo.line}"

  defp publish(state) do
    todos = visible(state)

    items =
      todos
      |> Enum.group_by(& &1.path)
      |> Enum.sort()
      |> Enum.map(fn {path, todos} ->
        %{
          id: path,
          label: Path.basename(path),
          description: if(Path.dirname(path) != ".", do: Path.dirname(path)),
          icon: "document-text",
          decoration: %{text: to_string(length(todos)), color: "modified"},
          children:
            for todo <- todos do
              %{
                id: id(todo),
                label: todo.text,
                description: "#{todo.line}",
                icon: if(todo.kind == "FIXME", do: "wrench", else: "check-circle"),
                context: "todo",
                command: %{command: "todos.open", arguments: [path, todo.line]}
              }
            end
        }
      end)

    hidden = MapSet.size(state.hidden)

    Bee.API.set_view(state.ctx, @view, %{
      items: items,
      message:
        cond do
          todos == [] and hidden > 0 -> "All TODOs are hidden."
          todos == [] -> "No TODOs in the workspace."
          hidden > 0 -> "#{hidden} hidden"
          true -> nil
        end,
      input: %{placeholder: "New TODO (Ctrl+Enter)", command: "todos.add", action: "Add"},
      badge: length(todos)
    })

    Bee.API.set_status_item(state.ctx, "count", %{
      text: "#{length(todos)} TODOs",
      icon: "check-circle",
      tooltip: "Go to a TODO",
      command: "todos.goTo",
      alignment: :right,
      priority: 10
    })

    # Tells the browser part to forget its cached counts.
    Bee.API.post_message(state.ctx, %{changed: true})
    state
  end
end

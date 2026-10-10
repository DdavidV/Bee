defmodule TodosLive do
  @moduledoc """
  The server part: finds the TODO and FIXME comments of the workspace,
  answers the LiveViews that draw them (`handle_request/4`) and tells them
  when the list changed (`Bee.API.push_live/3`).
  """
  use Bee.Plugin

  @pattern ~r/\b(TODO|FIXME)\b:?\s*(.*)$/
  @max_size 1_000_000
  # The view and the editor its LiveViews draw.
  @lives ["todosLive.list", "todosLive.board"]

  @impl true
  def activate(ctx), do: {:ok, %{ctx: ctx, todos: scan(), timer: nil}}

  ## Commands

  @command "todosLive.openBoard"
  def open_board(ctx, _state), do: Bee.API.open_editor(ctx, "todosLive.board")

  @command "todosLive.refresh"
  def refresh(_ctx, state), do: {:ok, publish(%{state | todos: scan()})}

  # [path, line], from a LiveView's click.
  @command "todosLive.open"
  def open(%{args: [path, line]} = ctx, _state), do: Bee.API.open_file(ctx, path, line: line)

  ## The LiveViews ask

  @impl true
  def handle_request("todos", _params, _ctx, state), do: {:reply, state.todos}

  ## Keeping up with the files

  @impl true
  def handle_event({:fs_changed, _path}, state), do: {:ok, rescan_soon(state)}
  def handle_event({:buffer_saved, _path}, state), do: {:ok, rescan_soon(state)}
  def handle_event(_event, _state), do: :ok

  @impl true
  def handle_info(:rescan, state), do: {:ok, publish(%{state | todos: scan(), timer: nil})}

  defp rescan_soon(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(state.ctx.host, :rescan, 300)}

  defp rescan_soon(state), do: state

  # The LiveViews of every window of the workspace get the new list.
  defp publish(state) do
    for id <- @lives, do: Bee.API.push_live(state.ctx, id, {:todos, state.todos})
    state
  end

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
          [_, kind, text] -> [%{id: "#{rel}:#{n}", path: rel, line: n, kind: kind, text: text}]
          nil -> []
        end
      end)
    else
      _ -> []
    end
  end
end

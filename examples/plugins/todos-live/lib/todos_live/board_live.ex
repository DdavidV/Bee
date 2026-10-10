defmodule TodosLive.BoardLive do
  @moduledoc """
  The TODO board, an editor tab: a LiveView whose template is the
  `.html.heex` file next to it (`board_live.html.heex`).
  """
  use Bee.Plugin.LiveView

  @impl true
  def mount(_params, _session, socket) do
    todos =
      case request(socket, "todos") do
        {:ok, todos} -> todos
        {:error, _message} -> []
      end

    {:ok, assign(socket, todos: todos, done: MapSet.new())}
  end

  @impl true
  def handle_event("open", %{"path" => path, "line" => line}, socket),
    do: {:noreply, run_command(socket, "todosLive.open", [path, String.to_integer(line)])}

  # Ticked off on the board only: its own state, kept while the tab is open.
  def handle_event("toggle", %{"id" => id}, socket) do
    done = socket.assigns.done

    {:noreply,
     assign(socket,
       done: if(id in done, do: MapSet.delete(done, id), else: MapSet.put(done, id))
     )}
  end

  def handle_event("refresh", _params, socket),
    do: {:noreply, run_command(socket, "todosLive.refresh")}

  @impl true
  def handle_info({:todos, todos}, socket), do: {:noreply, assign(socket, todos: todos)}

  # The board's columns: `{kind, todos}`.
  def columns(todos), do: for(kind <- ~w(TODO FIXME), do: {kind, Enum.filter(todos, &(&1.kind == kind))})
end

defmodule TodosLive.ListLive do
  @moduledoc """
  The TODOs view in the sidebar: a LiveView with its template inline (`~H`).
  It asks the server part for the list when it mounts, gets the changed
  list as a message, and keeps the filter typed into it itself.
  """
  use Bee.Plugin.LiveView

  @impl true
  def mount(_params, _session, socket) do
    todos =
      case request(socket, "todos") do
        {:ok, todos} -> todos
        {:error, _message} -> []
      end

    {:ok, assign(socket, todos: todos, filter: "")}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :shown, shown(assigns.todos, assigns.filter))

    ~H"""
    <div class="todos-live" id="todos-live-list">
      <form id="todos-live-filter-form" phx-change="filter" phx-submit="filter" class="todos-live-filter">
        <input
          type="text"
          name="filter"
          value={@filter}
          placeholder="Filter TODOs"
          autocomplete="off"
          id="todos-live-filter"
          phx-hook="TodosLiveFilter"
          phx-debounce="100"
        />
      </form>
      <p :if={@shown == []} class="todos-live-empty">
        {if @todos == [], do: "No TODOs in this folder.", else: "No TODO matches."}
      </p>
      <ul>
        <li
          :for={todo <- @shown}
          id={"todos-live-#{todo.id}"}
          class={"todos-live-item todos-live-#{String.downcase(todo.kind)}"}
          phx-click="open"
          phx-value-path={todo.path}
          phx-value-line={todo.line}
          title={"#{todo.path}:#{todo.line}"}
        >
          <span class="todos-live-kind">{todo.kind}</span>
          <span class="todos-live-text">{todo.text}</span>
          <span class="todos-live-where">{Path.basename(todo.path)}:{todo.line}</span>
        </li>
      </ul>
      <button type="button" class="todos-live-button" phx-click="board">Open Board</button>
    </div>
    """
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, filter: filter)}

  def handle_event("open", %{"path" => path, "line" => line}, socket),
    do: {:noreply, run_command(socket, "todosLive.open", [path, String.to_integer(line)])}

  def handle_event("board", _params, socket),
    do: {:noreply, run_command(socket, "todosLive.openBoard")}

  # From the server part (Bee.API.push_live/3).
  @impl true
  def handle_info({:todos, todos}, socket), do: {:noreply, assign(socket, todos: todos)}

  defp shown(todos, filter) do
    filter = String.downcase(String.trim(filter))
    Enum.filter(todos, &String.contains?(String.downcase(&1.text <> " " <> &1.path), filter))
  end
end

defmodule BeeWeb.EditorLive.Terminals do
  @moduledoc """
  The panel's terminals: `Bee.Terminal` processes owned by the window,
  shown by the `Terminal` hook. Output is forwarded only after the hook
  reported ready and replayed the scrollback (`term_seq/1`: the last
  sequence forwarded, per terminal – kept beside the assigns, as output
  isn't something the page renders).
  """

  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Terminal
  alias Bee.Workbench

  ## Events

  # A terminal was dragged to another place in the panel's list: their ids.
  def handle_event("reorder_terminals", %{"order" => order}, socket) when is_list(order) do
    ids = for id <- order, {int, ""} <- [Integer.parse(to_string(id))], do: int
    {:halt, change(socket, &Workbench.reorder_terminals(&1, ids))}
  end

  def handle_event("activate_terminal", %{"id" => id}, socket),
    do: {:halt, change(socket, &Workbench.activate_terminal(&1, String.to_integer(id)))}

  def handle_event("close_terminal", %{"id" => id}, socket),
    do: {:halt, change(socket, &Workbench.kill_terminal(&1, String.to_integer(id)))}

  def handle_event("term_ready", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    if Workbench.term_view?(workbench(socket), id) do
      Terminal.resize(id, cols, rows)
      {scrollback, seq} = Terminal.scrollback(id)

      {:halt, %{data: Base.encode64(scrollback)},
       put_term_seq(socket, Map.put(term_seq(socket), id, seq))}
    else
      {:halt, %{data: ""}, socket}
    end
  catch
    # The shell exited in the meantime; :term_exit removes the tab.
    :exit, _ -> {:halt, %{data: ""}, socket}
  end

  def handle_event("term_input", %{"id" => id, "data" => data}, socket) do
    if Workbench.term_view?(workbench(socket), id), do: Terminal.input(id, data)
    {:halt, socket}
  end

  def handle_event("term_resize", %{"id" => id, "cols" => cols, "rows" => rows}, socket) do
    if Workbench.term_view?(workbench(socket), id), do: Terminal.resize(id, cols, rows)
    {:halt, socket}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  def handle_info({:term_data, id, seq, data}, socket) do
    case term_seq(socket) do
      %{^id => last} = seqs when seq > last ->
        {:halt,
         socket
         |> push_event("term:data", %{id: id, data: Base.encode64(data)})
         |> put_term_seq(Map.put(seqs, id, seq))}

      # Not attached yet (replayed from scrollback on term_ready) or already sent.
      _ ->
        {:halt, socket}
    end
  end

  def handle_info({:term_exit, id, _reason}, socket),
    do: {:halt, change(socket, &Workbench.terminal_exited(&1, id))}

  def handle_info(_message, socket), do: {:cont, socket}

  # The last sequence forwarded to each attached terminal view: `%{id => seq}`.
  def term_seq(socket), do: socket.private[:term_seq] || %{}
  def put_term_seq(socket, seqs), do: put_private(socket, :term_seq, seqs)
end

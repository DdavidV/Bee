defmodule BeeWeb.EditorLive.SearchView do
  @moduledoc """
  The Search view (`Bee.Workbench.Search`): its form, its results as they
  come, and replacing.
  """

  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench
  alias Bee.Workspace
  alias Bee.Workbench.Search

  ## Events

  def handle_event("search_update", params, socket) do
    fields =
      for {key, value} <- params,
          key in ~w(query replace include exclude),
          into: %{},
          do: {String.to_existing_atom(key), value}

    {:halt, change(socket, &Search.update(&1, fields))}
  end

  def handle_event("search_toggle", %{"key" => key}, socket)
      when key in ~w(show_replace show_details),
      do: {:halt, change(socket, &Search.toggle(&1, String.to_existing_atom(key)))}

  def handle_event("search_refresh", _params, socket),
    do: {:halt, change(socket, &Search.refresh/1)}

  def handle_event("search_toggle_file", %{"path" => path}, socket),
    do: {:halt, change(socket, &Search.toggle_file(&1, path))}

  # A match: open its file and select it.
  def handle_event("search_open", %{"path" => rel, "from" => from, "to" => to}, socket) do
    case Workspace.resolve(socket.assigns.root, rel) do
      {:ok, path} ->
        socket = change(socket, &Workbench.open_editor(&1, path, preview: preview?(socket)))

        if Workbench.open?(workbench(socket), path),
          do:
            {:halt, push_event(socket, "cm:reveal", %{path: path, from: int(from), to: int(to)})},
          else: {:halt, socket}

      {:error, _} ->
        {:halt, socket}
    end
  end

  def handle_event("search_replace", %{"target" => "all"}, socket),
    do: {:halt, change(socket, &Search.replace(&1, :all))}

  def handle_event("search_replace", %{"target" => "file", "path" => path}, socket),
    do: {:halt, change(socket, &Search.replace(&1, {:file, path}))}

  def handle_event(
        "search_replace",
        %{"target" => "match", "path" => path, "from" => from},
        socket
      ),
      do: {:halt, change(socket, &Search.replace(&1, {:match, path, int(from)}))}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  def handle_info({:search_results, ref, files}, socket),
    do: {:halt, change(socket, &Search.results(&1, ref, files))}

  def handle_info({:search_done, ref, stats}, socket),
    do: {:halt, change(socket, &Search.done(&1, ref, stats))}

  def handle_info(_message, socket), do: {:cont, socket}
end

defmodule BeeWeb.EditorLive.Json do
  @moduledoc """
  JSON files: their schemas' completion and hover
  (`Bee.JSONValidation.Assist`), and their validation (`Bee.JSONValidation`).

  A JSON file's diagnostics – syntax, and its schemas' errors – are found
  in a task, one at a time per file: text arriving meanwhile waits for
  it (`json_jobs`: path => nil, or the text to validate next). They go to
  the editor (cm:diagnostics, with the size of the text they're for) and
  to the problems.
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench
  alias Bee.Editor.Buffer

  ## Events

  # From the editor (editor/json_assist.js), which sent its text first;
  # `size`: the text's, to answer only for that text.
  def handle_event(
        "json_assist",
        %{"path" => path, "kind" => kind, "offset" => offset} = params,
        socket
      )
      when kind in ["complete", "hover"] and is_integer(offset) do
    reply =
      with true <- Workbench.open?(workbench(socket), path),
           %{text: text} <-
             (try do
                Buffer.get(path)
              catch
                :exit, _ -> nil
              end),
           true <- byte_size(text) == params["size"] do
        case kind do
          "complete" -> Bee.JSONValidation.Assist.complete(path, text, offset)
          "hover" -> Bee.JSONValidation.Assist.hover(path, text, offset) || %{}
        end
      else
        _ -> %{}
      end

    {:halt, reply, socket}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  def handle_info({:json_diagnostics, path, size, diagnostics}, socket) do
    {next, jobs} = Map.pop(socket.assigns.json_jobs, path)
    socket = assign(socket, json_jobs: jobs)
    socket = if next, do: validate_json(socket, path, next), else: socket

    if Workbench.open?(workbench(socket), path) do
      {:halt,
       socket
       |> update(:diagnostics, &Map.put(&1, path, diagnostics))
       |> push_event("cm:diagnostics", %{
         path: path,
         size: size,
         diagnostics: for(d <- diagnostics, do: Map.take(d, [:from, :to, :severity, :message]))
       })}
    else
      {:halt, socket}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  def validate_json(socket, path, text) do
    lang = Workbench.language(workbench(socket), path)

    cond do
      not Bee.JSONValidation.language?(lang) ->
        socket

      Map.has_key?(socket.assigns.json_jobs, path) ->
        update(socket, :json_jobs, &Map.put(&1, path, text))

      true ->
        window = self()

        Task.Supervisor.start_child(Bee.JSONValidation.TaskSup, fn ->
          diagnostics =
            try do
              Bee.JSONValidation.validate(path, text)
            rescue
              e ->
                require Logger
                Logger.error("validating #{path}: #{Exception.message(e)}")
                []
            end

          send(window, {:json_diagnostics, path, byte_size(text), diagnostics})
        end)

        update(socket, :json_jobs, &Map.put(&1, path, nil))
    end
  end

  # Schemas changed: every open JSON file again.
  def validate_open_json(socket) do
    Enum.reduce(open_tabs(socket), socket, fn
      %{kind: :file, path: path}, socket ->
        case Buffer.get(path) do
          %{text: text} -> validate_json(socket, path, text)
          _ -> socket
        end

      _tab, socket ->
        socket
    end)
  catch
    :exit, _ -> socket
  end
end

defmodule BeeWeb.EditorLive.Formatting do
  @moduledoc """
  Formatting a file with its formatter (an extension's language feature):
  Format Document, Format Selection, and format on save.
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench
  alias BeeWeb.EditorLive.{Editors, Notifications}

  ## Messages

  # The formatter of a file being saved took too long: saved as it is.
  def handle_info({:format_timeout, ref}, socket) do
    if Map.has_key?(socket.assigns.formats, ref) do
      Bee.Languages.Features.cancel(socket.assigns.root, ref)
      {:halt, formatted(socket, ref, {:ok, nil})}
    else
      {:halt, socket}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  @format_timeout 3_000

  # The settings as they are for the file: its language's on top
  # ("[elixir]": {…}, Bee.Settings.for_language/2).
  def file_settings(socket, path) do
    language = Workbench.language(workbench(socket), path)
    Bee.Settings.for_language(socket.assigns.root, language)
  end

  def formatter?(socket, path, feature),
    do: Map.has_key?(Bee.Languages.Features.for_file(socket.assigns.root, path), feature)

  # Asks the file's formatter for its edits: of the whole text, or of the
  # selection's lines. They are applied when they come (formatted/3), if
  # the text is still the one asked about; `save?`: the file is saved then.
  def format(socket, path, what, save?) do
    root = socket.assigns.root
    text = Bee.API.text(path)
    feature = if what == :selection, do: "rangeFormatting", else: "formatting"

    if is_binary(text) and formatter?(socket, path, feature) do
      ref = make_ref()
      settings = file_settings(socket, path)

      params =
        Map.merge(
          %{
            options: %{tabSize: settings["editor.tabSize"] || 2, insertSpaces: true},
            formatter: settings["editor.defaultFormatter"]
          },
          if(what == :selection, do: %{range: selected_range(socket, path)}, else: %{})
        )

      Bee.Languages.Features.request(root, feature, path, params, {self(), ref})
      if save?, do: Process.send_after(self(), {:format_timeout, ref}, @format_timeout)
      format = %{path: path, hash: :erlang.phash2(text), save?: save?}
      update(socket, :formats, &Map.put(&1, ref, format))
    else
      change(socket, &Workbench.set_status(&1, "No formatter for this file"))
    end
  end

  # The first selection of the file's editor (the cursor's place when
  # there is none).
  defp selected_range(socket, path) do
    case selections(socket.assigns.selection, path) do
      [{from, to} | _] -> %{from: from, to: to}
      [] -> %{from: %{line: 0, character: 0}, to: %{line: 0, character: 0}}
    end
  end

  def formatted(socket, ref, reply) do
    {%{path: path, hash: hash, save?: save?}, formats} = Map.pop(socket.assigns.formats, ref)
    socket = assign(socket, formats: formats)
    text = Bee.API.text(path)

    socket =
      case reply do
        {:ok, %{"edits" => [_ | _] = edits}} when is_binary(text) ->
          if :erlang.phash2(text) == hash do
            edits =
              for %{"from" => from, "to" => to, "text" => insert} <- edits do
                {Bee.Extensions.Host.position_to_bytes(text, from),
                 Bee.Extensions.Host.position_to_bytes(text, to), insert}
              end

            case Bee.API.edit(path, edits) do
              :ok ->
                socket

              _ ->
                Notifications.notify(
                  socket,
                  :error,
                  "The formatter's changes couldn't be applied"
                )
            end
          else
            # Typed in since: its changes are for another text.
            socket
          end

        {:error, message} ->
          Notifications.notify(socket, :error, "Formatting failed: #{message}")

        _ ->
          socket
      end

    if save? and is_binary(Bee.API.text(path)),
      do: Editors.save_file(socket, path, Bee.API.text(path)),
      else: socket
  end
end

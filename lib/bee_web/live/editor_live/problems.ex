defmodule BeeWeb.EditorLive.Problems do
  @moduledoc """
  The problems there are: Bee's own (settings, keybindings, plugins), JSON
  validation's and the diagnostics of extensions' language features
  (`Bee.Diagnostics`) – for the status bar's count and the panel's Problems
  section.
  """

  import Phoenix.Component, only: [assign: 2]
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench
  alias BeeWeb.EditorLive.LanguageFeatures

  ## Events

  # A row of the Problems section: its file, at the problem.
  def handle_event("problem_open", %{"index" => index}, socket) do
    case Enum.at(problem_entries(socket.assigns), int(index)) do
      %{path: path, line: line} when is_integer(line) ->
        place = %{
          "path" => path,
          "from" => %{
            "line" => line - 1,
            "character" => (problem_column(socket, int(index)) || 1) - 1
          }
        }

        {:halt, LanguageFeatures.open_place(socket, place)}

      %{path: path} ->
        {:halt, change(socket, &Workbench.open_editor(&1, path))}

      nil ->
        {:halt, socket}
    end
  end

  # Errors, warnings or infos shown or not, in the Problems section.
  def handle_event("problems_filter", %{"severity" => severity}, socket)
      when severity in ~w(error warning info) do
    severity = String.to_existing_atom(severity)

    hidden =
      if severity in socket.assigns.problems_hidden,
        do: List.delete(socket.assigns.problems_hidden, severity),
        else: [severity | socket.assigns.problems_hidden]

    {:halt, assign(socket, problems_hidden: hidden)}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  # Extensions' language features found (or cleared) problems in a file:
  # its editor underlines them; the count follows a moment later (they
  # come in bursts, a file at a time).
  def handle_info({:diagnostics_changed, path}, socket) do
    socket =
      if Workbench.open?(workbench(socket), path),
        do: LanguageFeatures.push_language_diagnostics(socket, path),
        else: socket

    timer =
      socket.assigns.language_problems_timer ||
        Process.send_after(self(), :language_problems, 150)

    {:halt, assign(socket, language_problems_timer: timer)}
  end

  def handle_info(:language_problems, socket) do
    {:halt,
     assign(socket,
       language_problems: language_problems(socket.assigns.root),
       language_problems_timer: nil
     )}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  def problems(assigns),
    do:
      assigns.settings_errors ++
        assigns.keybinding_errors ++
        assigns.plugin_errors ++
        diagnostic_problems(assigns) ++
        for(
          %{severity: severity, path: path, line: line, message: message} <-
            assigns.language_problems,
          severity in [:error, :warning],
          do: %{path: path, message: "line #{line}: #{first_line(message)}"}
        )

  # What extensions' language features found in the workspace's files
  # (Bee.Diagnostics), errors first; hints aren't problems:
  # `[%{path, severity, message, line, column, source}]`.
  def language_problems(root) do
    for(
      {path, diagnostics} <- Bee.Diagnostics.all(root),
      %{severity: severity} = d when severity in [:error, :warning, :info] <- diagnostics,
      do: %{
        path: path,
        severity: severity,
        message: d.message,
        line: d.from.line + 1,
        column: d.from.character + 1,
        source:
          Enum.join(Enum.reject([d.source, d.code && "(#{d.code})"], &(&1 in [nil, false])), " ")
      }
    )
    |> Enum.sort_by(&{&1.severity != :error, &1.path, &1.line})
  end

  defp first_line(message), do: message |> String.split("\n", parts: 2) |> hd()

  # Every problem there is, as the Problems section lists them: Bee's own
  # (settings, keybindings, plugins: no place), JSON validation's and the
  # extensions' diagnostics. `%{path, severity, message, line, column, source}`,
  # by file, errors first in each.
  def problem_entries(assigns) do
    own =
      for %{path: path, message: message} <-
            assigns.settings_errors ++ assigns.keybinding_errors ++ assigns.plugin_errors do
        %{path: path, severity: :error, message: message, line: nil, column: nil, source: "Bee"}
      end

    json =
      for {path, diagnostics} <- assigns[:diagnostics] || %{}, d <- diagnostics do
        %{
          path: path,
          severity: if(d[:severity] in [:warning, "warning"], do: :warning, else: :error),
          message: d.message,
          line: d.line,
          column: nil,
          source: "JSON"
        }
      end

    Enum.sort_by(own ++ json ++ assigns.language_problems, fn p ->
      {p.path, Enum.find_index([:error, :warning, :info], &(&1 == p.severity)), p.line || 0}
    end)
  end

  defp problem_column(socket, index) do
    with %{column: column} <- Enum.at(problem_entries(socket.assigns), index), do: column
  end

  defp diagnostic_problems(assigns) do
    for {path, diagnostics} <- Enum.sort(assigns[:diagnostics] || %{}),
        d <- diagnostics,
        do: %{path: path, message: "line #{d.line}: #{d.message}"}
  end
end

defmodule BeeWeb.EditorLive.LanguageFeatures do
  @moduledoc """
  Language features of extensions (`Bee.Languages.Features`).

  The editor's own requests (completion, hover, …; editor/language_features.js)
  are passed on and answered by `ref`. Those the window takes part in are
  followed here, a step per answer: Go to Definition and its relatives,
  Find All References (the panel's References section), Rename Symbol and
  Quick Fix (code actions). Questions go through the palette, as a
  plugin's would (`BeeWeb.EditorLive.PluginAPI`).
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench
  alias BeeWeb.EditorLive.{Formatting, Notifications, Palette, PluginAPI}

  ## Events

  # From the editor (editor/language_features.js), which sent its text
  # first: answered later with language:reply, by `ref`.
  def handle_event(
        "language_request",
        %{"ref" => ref, "feature" => feature, "path" => path} = params,
        socket
      )
      when is_binary(ref) and is_binary(path) do
    if feature in ~w(completion completionResolve completionAccept hover signatureHelp
                     documentHighlight codeAction) and
         Workbench.open?(workbench(socket), path) do
      params = if is_map(params["params"]), do: params["params"], else: %{}
      Bee.Languages.Features.request(socket.assigns.root, feature, path, params, {self(), ref})
      {:halt, socket}
    else
      {:halt, push_event(socket, "language:reply", %{ref: ref, result: nil})}
    end
  end

  def handle_event("language_cancel", %{"ref" => ref}, socket) when is_binary(ref) do
    Bee.Languages.Features.cancel(socket.assigns.root, ref)
    {:halt, socket}
  end

  # Go to Definition and its relatives: the place is opened when it is
  # known (`{:language_reply, ref, …}`), picked first if there are several.
  # The answer can take a while (a language server still building): the
  # status bar says it is looked for, and asking again gives up on what was
  # asked before – only the place asked for last is gone to.
  def handle_event(
        "language_goto",
        %{"feature" => feature, "path" => path, "position" => %{} = position},
        socket
      )
      when feature in ~w(definition typeDefinition declaration implementation references) and
             is_binary(path) do
    if Workbench.open?(workbench(socket), path) do
      ref = make_ref()
      root = socket.assigns.root
      socket = forget_gotos(socket)
      Bee.Languages.Features.request(root, feature, path, %{position: position}, {self(), ref})

      {:halt,
       socket
       |> update(:language_gotos, &Map.put(&1, ref, feature))
       |> change(&Workbench.set_status(&1, looking(feature)))}
    else
      {:halt, socket}
    end
  end

  # Rename Symbol at a place of the editor: what would be renamed is asked
  # first, then its new name (rename_step/3).
  def handle_event("language_rename", %{"path" => path, "position" => %{} = position}, socket)
      when is_binary(path) do
    if Workbench.open?(workbench(socket), path) do
      ref = make_ref()
      root = socket.assigns.root

      Bee.Languages.Features.request(
        root,
        "prepareRename",
        path,
        %{position: position},
        {self(), ref}
      )

      {:halt, update(socket, :renames, &Map.put(&1, ref, {:prepare, path, position}))}
    else
      {:halt, socket}
    end
  end

  # Quick Fix at a range of the editor: its code actions are asked for,
  # then picked from (code_action_step/3).
  def handle_event("language_code_actions", %{"path" => path, "range" => %{} = range}, socket)
      when is_binary(path) do
    if Workbench.open?(workbench(socket), path) do
      ref = make_ref()
      params = %{range: range, context: %{triggerKind: 1}}

      Bee.Languages.Features.request(
        socket.assigns.root,
        "codeAction",
        path,
        params,
        {self(), ref}
      )

      {:halt, update(socket, :code_actions, &Map.put(&1, ref, :list))}
    else
      {:halt, socket}
    end
  end

  # A row of the References section: there.
  def handle_event("reference_open", %{"index" => index}, socket) do
    place = Enum.at(reference_places(socket.assigns.references), int(index))
    {:halt, if(place, do: open_place(socket, place), else: socket)}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  # Extensions registered (or took back) language features: each open
  # file's editor is told what there is for it now.
  def handle_info(:language_features_changed, socket) do
    socket =
      Enum.reduce(open_tabs(socket), socket, fn
        %{kind: :file, path: path}, socket -> push_language_features(socket, path)
        _other, socket -> socket
      end)

    # (Menus and keybindings depend on them: the editorHas…Provider keys.)
    {:halt, update(socket, :language_features, &(&1 + 1))}
  end

  # An extension's answer: the editor's (its `ref` is a string), or where
  # Go to Definition leads.
  def handle_info({:language_reply, ref, reply}, socket) when is_binary(ref) do
    result =
      case reply do
        {:ok, result} -> result
        {:error, _message} -> nil
      end

    {:halt, push_event(socket, "language:reply", %{ref: ref, result: result})}
  end

  def handle_info({:language_reply, ref, reply}, socket) do
    cond do
      Map.has_key?(socket.assigns.formats, ref) ->
        {:halt, Formatting.formatted(socket, ref, reply)}

      Map.has_key?(socket.assigns.language_gotos, ref) ->
        {feature, gotos} = Map.pop(socket.assigns.language_gotos, ref)

        {:halt,
         socket
         |> assign(language_gotos: gotos)
         |> found(feature)
         |> go_to(feature, reply)}

      Map.has_key?(socket.assigns.renames, ref) ->
        {step, renames} = Map.pop(socket.assigns.renames, ref)
        {:halt, rename_step(assign(socket, renames: renames), step, reply)}

      Map.has_key?(socket.assigns.code_actions, ref) ->
        {step, actions} = Map.pop(socket.assigns.code_actions, ref)
        {:halt, code_action_step(assign(socket, code_actions: actions), step, reply)}

      Palette.symbols_reply?(socket.assigns.quick_open, ref) ->
        {:halt, Palette.symbols_reply(socket, ref, reply)}

      true ->
        {:halt, socket}
    end
  end

  # Which of several places to go to was picked (see go_to/3).
  def handle_info({:bee_answer, ref, answer}, socket) do
    cond do
      is_list(socket.assigns.language_gotos[ref]) ->
        {places, gotos} = Map.pop(socket.assigns.language_gotos, ref)
        socket = assign(socket, language_gotos: gotos)
        place = is_integer(answer) && Enum.at(places, answer)
        {:halt, if(place, do: open_place(socket, place), else: socket)}

      # The code action picked.
      Map.has_key?(socket.assigns.code_actions, ref) ->
        {step, actions} = Map.pop(socket.assigns.code_actions, ref)
        {:halt, code_action_step(assign(socket, code_actions: actions), step, answer)}

      # The new name of Rename Symbol.
      Map.has_key?(socket.assigns.renames, ref) ->
        {step, renames} = Map.pop(socket.assigns.renames, ref)
        {:halt, rename_step(assign(socket, renames: renames), step, answer)}

      true ->
        {:halt, socket}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  # What the editor underlines in `path`.
  def push_language_diagnostics(socket, path) do
    diagnostics =
      for d <- Bee.Diagnostics.for_file(socket.assigns.root, path),
          do: Map.take(d, [:from, :to, :severity, :message, :source, :code])

    push_event(socket, "cm:language_diagnostics", %{path: path, diagnostics: diagnostics})
  end

  # Which language features there are for `path`, for its editor.
  def push_language_features(socket, path) do
    features = Bee.Languages.Features.for_file(socket.assigns.root, path)
    push_event(socket, "cm:language_features", %{path: path, features: features})
  end

  # What can be done there: picked from in the palette, the preferred first.
  defp code_action_step(
         socket,
         :list,
         {:ok, %{"session" => session, "actions" => [_ | _] = actions}}
       ) do
    ref = make_ref()
    actions = Enum.sort_by(actions, &(not &1["preferred"]))

    items =
      for {action, index} <- Enum.with_index(actions) do
        %{
          label: action["title"],
          description:
            cond do
              action["disabled"] -> "can't be done: #{action["disabled"]}"
              action["preferred"] -> "preferred"
              true -> ""
            end,
          value: index
        }
      end

    socket
    |> update(:code_actions, &Map.put(&1, ref, {:pick, session, actions}))
    |> PluginAPI.plugin_request(
      {:ask, ref, self(), :pick, %{placeholder: "Quick Fix…", items: items}}
    )
  end

  defp code_action_step(socket, :list, {:error, message}),
    do: Notifications.notify(socket, :error, "Quick Fix: #{message}")

  defp code_action_step(socket, :list, _none),
    do: change(socket, &Workbench.set_status(&1, "No code actions available"))

  defp code_action_step(socket, {:pick, session, actions}, index) when is_integer(index) do
    case Enum.at(actions, index) do
      %{"disabled" => reason, "title" => title} when is_binary(reason) ->
        Notifications.notify(socket, :error, "#{title}: #{reason}")

      %{"index" => action, "title" => title} ->
        ref = make_ref()
        params = %{session: session, index: action}

        Bee.Languages.Features.request(
          socket.assigns.root,
          "codeActionApply",
          nil,
          params,
          {self(), ref}
        )

        update(socket, :code_actions, &Map.put(&1, ref, {:apply, title}))

      nil ->
        socket
    end
  end

  # (Dismissed.)
  defp code_action_step(socket, {:pick, _session, _actions}, _nothing), do: socket

  defp code_action_step(socket, {:apply, title}, {:ok, %{"error" => message}}),
    do: Notifications.notify(socket, :error, "#{title}: #{message}")

  defp code_action_step(socket, {:apply, title}, {:error, message}),
    do: Notifications.notify(socket, :error, "#{title}: #{message}")

  defp code_action_step(socket, {:apply, _title}, _done), do: socket

  # What is renamed is known: asks for its new name, in the palette.
  defp rename_step(socket, {:prepare, path, position}, {:ok, %{"placeholder" => old}})
       when is_binary(old) do
    ref = make_ref()

    socket
    |> update(:renames, &Map.put(&1, ref, {:name, path, position, old}))
    |> PluginAPI.plugin_request(
      {:ask, ref, self(), :input,
       %{prompt: "Rename Symbol: a new name for #{old}", placeholder: old, value: old}}
    )
  end

  defp rename_step(socket, {:prepare, _path, _position}, {:ok, %{"error" => message}}),
    do: Notifications.notify(socket, :error, to_string(message))

  defp rename_step(socket, {:prepare, _path, _position}, {:error, message}),
    do: Notifications.notify(socket, :error, "Rename Symbol: #{message}")

  defp rename_step(socket, {:prepare, _path, _position}, _none),
    do: change(socket, &Workbench.set_status(&1, "Nothing to rename here"))

  # The new name: renamed, in every file it is in.
  defp rename_step(socket, {:name, path, position, old}, name) when is_binary(name) do
    name = String.trim(name)

    if name in ["", old] do
      socket
    else
      ref = make_ref()
      params = %{position: position, newName: name}
      Bee.Languages.Features.request(socket.assigns.root, "rename", path, params, {self(), ref})
      update(socket, :renames, &Map.put(&1, ref, {:apply, old, name}))
    end
  end

  # (Dismissed.)
  defp rename_step(socket, {:name, _path, _position, _old}, _nothing), do: socket

  defp rename_step(socket, {:apply, old, name}, {:ok, %{"applied" => true} = done}) do
    places = "#{done["edits"]} #{if done["edits"] == 1, do: "place", else: "places"}"
    files = "#{done["files"]} #{if done["files"] == 1, do: "file", else: "files"}"
    change(socket, &Workbench.set_status(&1, "Renamed #{old} to #{name}: #{places} in #{files}"))
  end

  defp rename_step(socket, {:apply, _old, _name}, {:ok, %{"error" => message}}),
    do: Notifications.notify(socket, :error, "Rename Symbol: #{message}")

  defp rename_step(socket, {:apply, _old, _name}, {:error, message}),
    do: Notifications.notify(socket, :error, "Rename Symbol: #{message}")

  defp rename_step(socket, {:apply, old, _name}, _other),
    do: Notifications.notify(socket, :error, "Rename Symbol: #{old} couldn't be renamed")

  # Every place a symbol is (`[%{"path", "from", "to"}]`), by file, each
  # with its line's text around the place: `%{count, files: [%{path, rows:
  # [%{index, line, before, match, after}]}]}`; `index` among all places.
  defp show_references(socket, [_ | _] = places) do
    root = socket.assigns.root

    files =
      places
      |> Enum.with_index()
      |> Enum.group_by(fn {place, _} -> place["path"] end)
      |> Enum.sort_by(fn {path, _} -> display_path(root, path) end)
      |> Enum.map(fn {path, entries} ->
        lines = path |> place_text() |> String.split("\n")
        %{path: path, rows: Enum.map(entries, &reference_row(&1, lines))}
      end)

    # (Files folded in the last list are open in this one.)
    view = BeeWeb.Workbench.ReferencesView.view_id()

    socket
    |> assign(references: %{count: length(places), files: files, places: places})
    |> update(:collapsed, fn collapsed ->
      MapSet.reject(collapsed, &match?({^view, _file}, &1))
    end)
    |> change(&Workbench.show_container(&1, "references"))
  end

  defp show_references(socket, _none),
    do: change(socket, &Workbench.set_status(&1, "No references found"))

  defp reference_row({%{"from" => from, "to" => to} = _place, index}, lines) do
    text = String.trim_trailing(Enum.at(lines, from["line"], ""), "\r")
    start = Bee.Extensions.Host.to_bytes(text, from["character"])

    stop =
      if to["line"] == from["line"],
        do: max(start, Bee.Extensions.Host.to_bytes(text, to["character"])),
        else: byte_size(text)

    before = binary_part(text, 0, start)

    %{
      index: index,
      line: from["line"] + 1,
      # (Its indentation says nothing here.)
      before: String.trim_leading(before),
      match: binary_part(text, start, stop - start),
      after: binary_part(text, stop, byte_size(text) - stop)
    }
  end

  defp reference_places(%{places: places}), do: places
  defp reference_places(_none), do: []

  @goto_names %{
    "definition" => "definition",
    "typeDefinition" => "type definition",
    "declaration" => "declaration",
    "implementation" => "implementation"
  }

  # What the status bar says while a place is looked for.
  defp looking("references"), do: "Looking for references…"
  defp looking(feature), do: "Looking for the #{@goto_names[feature]}…"

  # The answer came: the status bar doesn't say so any more.
  defp found(socket, feature) do
    if socket.assigns.status == looking(feature),
      do: change(socket, &Workbench.set_status(&1, nil)),
      else: socket
  end

  # Gives up on the places still looked for (not on those to pick from).
  defp forget_gotos(socket) do
    {asked, kept} = Enum.split_with(socket.assigns.language_gotos, &is_binary(elem(&1, 1)))
    for {ref, _feature} <- asked, do: Bee.Languages.Features.cancel(socket.assigns.root, ref)
    assign(socket, language_gotos: Map.new(kept))
  end

  # Where a symbol is defined (`[%{"path", "from", "to"}]`): there, or
  # picked among them in the palette.
  defp go_to(socket, "references", {:ok, places}) when is_list(places),
    do: show_references(socket, places)

  defp go_to(socket, "references", {:error, message}),
    do: Notifications.notify(socket, :error, "Find All References: #{message}")

  defp go_to(socket, "references", _none), do: show_references(socket, [])

  defp go_to(socket, _feature, {:ok, [place]}), do: open_place(socket, place)

  defp go_to(socket, feature, {:ok, [_ | _] = places}) do
    root = socket.assigns.root
    ref = make_ref()

    items =
      for {%{"path" => path, "from" => from}, index} <- Enum.with_index(places) do
        %{
          label: "#{display_path(root, path)}:#{from["line"] + 1}",
          description: place_line(path, from["line"]),
          value: index
        }
      end

    socket
    |> update(:language_gotos, &Map.put(&1, ref, places))
    |> PluginAPI.plugin_request(
      {:ask, ref, self(), :pick, %{placeholder: "Go to #{@goto_names[feature]}", items: items}}
    )
  end

  defp go_to(socket, feature, {:error, message}),
    do: Notifications.notify(socket, :error, "Go to #{@goto_names[feature]}: #{message}")

  defp go_to(socket, feature, _none),
    do: change(socket, &Workbench.set_status(&1, "No #{@goto_names[feature]} found"))

  def open_place(socket, %{"path" => path, "from" => from}) do
    at = Bee.Extensions.Host.position_to_bytes(place_text(path), from)
    PluginAPI.plugin_request(socket, {:open_file, path, %{from: at, to: at}})
  end

  # A file's text as its editor has it (unsaved, if open).
  defp place_text(path) do
    case Bee.API.text(path) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp place_line(path, line) do
    path |> place_text() |> String.split("\n") |> Enum.at(line, "") |> String.trim()
  end
end

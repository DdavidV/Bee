defmodule BeeWeb.EditorLive.Palette do
  @moduledoc """
  The command palette: Quick Open (files, commands, symbols), quick picks
  and input boxes.

  Quick Open's data (`quick_open`): the recent files, read when it opens,
  a file finder (`Bee.Workspace.FileFinder`) searching the workspace's
  files off this process, and the symbols extensions' language features
  list (Go to Symbol, its @ and # modes).
  """

  import Phoenix.Component, only: [assign: 2]
  import BeeWeb.EditorLive.Window

  alias Bee.Workbench
  alias Bee.Commands.Registry, as: CommandRegistry
  alias Bee.Workspace.FileFinder
  alias Bee.Workspace.RecentFiles
  alias Bee.Workbench.QuickOpen
  alias BeeWeb.EditorLive.{Commands, LanguageFeatures, Notifications}

  ## Events

  def handle_event("palette_filter", %{"query" => query}, socket),
    do: {:halt, change(socket, &Workbench.filter_palette(&1, query))}

  def handle_event("palette_key", %{"key" => key}, socket) do
    count = length(palette_items(socket.assigns))

    case key do
      "ArrowDown" -> {:halt, change(socket, &Workbench.move_palette(&1, 1, count))}
      "ArrowUp" -> {:halt, change(socket, &Workbench.move_palette(&1, -1, count))}
      "Escape" -> {:halt, change(socket, &Workbench.close_palette/1)}
      _ -> {:halt, socket}
    end
  end

  # Enter in the input submits the form.
  def handle_event("palette_run", _params, %{assigns: %{palette: %{mode: :input} = p}} = socket),
    do: {:halt, palette_answer(socket, p, p.query)}

  def handle_event("palette_run", _params, %{assigns: %{palette: %{index: index}}} = socket) do
    case Enum.at(palette_items(socket.assigns), index) do
      nil -> {:halt, socket}
      item -> {:halt, palette_choose(socket, item)}
    end
  end

  def handle_event("palette_run", _params, socket), do: {:halt, socket}

  # Clicking a quick pick item.
  def handle_event("palette_pick", %{"index" => index}, socket) do
    case Enum.at(palette_items(socket.assigns), String.to_integer(index)) do
      nil -> {:halt, socket}
      item -> {:halt, palette_choose(socket, item)}
    end
  end

  def handle_event("close_palette", _params, socket),
    do: {:halt, change(socket, &Workbench.close_palette/1)}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  # Quick Open's file finder answered.
  def handle_info(
        {:file_finder, finder, query, paths, loading?},
        %{assigns: %{quick_open: %{finder: finder} = data}} = socket
      ),
      do:
        {:halt,
         assign(socket,
           quick_open: %{data | results: paths, results_for: query, loading?: loading?}
         )}

  def handle_info({:file_finder, _old, _query, _paths, _loading?}, socket), do: {:halt, socket}

  # It stopped: on purpose, or it crashed (no results then, nothing worse).
  def handle_info({:DOWN, _ref, :process, finder, _reason}, socket) do
    case socket.assigns.quick_open do
      %{finder: ^finder} = data ->
        {:halt, assign(socket, quick_open: %{data | finder: nil, loading?: false})}

      _ ->
        {:halt, socket}
    end
  end

  def handle_info(_message, socket), do: {:cont, socket}

  def palette_items(%{palette: nil}), do: []
  def palette_items(%{palette: %{mode: :input}}), do: []

  def palette_items(%{palette: %{mode: :pick, items: items, query: query}}) do
    query = String.downcase(query)

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, i} -> Map.merge(item, %{kind: :pick, key: i}) end)
    |> Enum.filter(&fuzzy_match?(String.downcase(&1.label), query))
  end

  def palette_items(%{palette: %{mode: :quick_open, query: query}} = assigns) do
    case QuickOpen.mode(query) do
      {:commands, rest} -> command_items(assigns, String.downcase(rest))
      :recent -> mode_items() ++ recent_items(assigns)
      {:files, query} -> file_items(assigns, query)
      symbols -> symbol_items(assigns, symbols)
    end
  end

  defp command_items(assigns, query) do
    ctx = context(assigns)
    hidden = hidden_from_palette(assigns, ctx)

    assigns.commands
    |> Enum.filter(&(CommandRegistry.enabled?(&1, ctx) and not MapSet.member?(hidden, &1.id)))
    |> Enum.map(
      &%{
        kind: :command,
        id: &1.id,
        label: CommandRegistry.label(&1),
        shortcut: assigns.keybinding_labels[&1.id]
      }
    )
    |> Enum.filter(&fuzzy_match?(String.downcase(&1.label), query))
    # Contiguous matches ("term" in "Terminal") before scattered ones.
    |> Enum.sort_by(&{not String.contains?(String.downcase(&1.label), query), &1.label})
  end

  defp mode_items do
    for %{prefix: prefix, label: label} <- QuickOpen.modes(),
        do: %{kind: :mode, prefix: prefix, label: label, description: prefix}
  end

  defp recent_items(%{quick_open: %{recent: recent}} = assigns) do
    recent
    |> Enum.take(assigns.settings["workbench.quickOpen.recentFiles"] || 10)
    |> Enum.with_index()
    |> Enum.map(fn {path, i} ->
      Map.put(file_item(assigns.root, path), :section, if(i == 0, do: "recently opened"))
    end)
  end

  defp recent_items(_assigns), do: []

  # The finder's latest answer (a newer query's is on its way).
  defp file_items(%{quick_open: %{results: results}} = assigns, _query),
    do: Enum.map(results, &file_item(assigns.root, Path.join(assigns.root, &1)))

  defp file_items(_assigns, _query), do: []

  # Its name, and the folder it is in (relative to the workspace).
  defp file_item(root, path) do
    dir = Path.dirname(Bee.Workspace.FS.relative(root, path))

    %{
      kind: :file,
      path: path,
      label: Path.basename(path),
      description: if(dir == ".", do: "", else: dir)
    }
  end

  # Quick Open's data: the recent files, read when it opens, and a file
  # finder (Bee.Workspace.FileFinder) searching the workspace's files off
  # this process, started with it (unless it opens on commands), stopped
  # when it closes. Its answers come as {:file_finder, …} messages.
  def sync_quick_open(%{assigns: %{palette: %{mode: :quick_open, query: query}}} = socket) do
    data =
      socket.assigns.quick_open ||
        %{
          recent: RecentFiles.list(socket.assigns.root),
          finder: nil,
          sent: nil,
          results: [],
          results_for: nil,
          loading?: false,
          # Go to Symbol: the file's (asked once), the workspace's (per query).
          symbols: nil,
          symbols_ref: nil,
          symbols_path: nil,
          workspace_symbols: nil,
          workspace_ref: nil,
          workspace_sent: nil
        }

    mode = QuickOpen.mode(query)

    data =
      case {data.finder, mode} do
        {nil, {kind, _}} when kind in [:commands, :symbols, :workspace_symbols] ->
          data

        {nil, _} ->
          {:ok, finder} = FileFinder.start(socket.assigns.root)
          Process.monitor(finder)
          %{data | finder: finder, loading?: true}

        _ ->
          data
      end

    data =
      case mode do
        {:files, q} when q != data.sent and data.finder != nil ->
          FileFinder.query(data.finder, q)
          %{data | sent: q}

        _ ->
          data
      end

    assign(socket, quick_open: sync_symbols(socket, data, mode))
  end

  def sync_quick_open(%{assigns: %{quick_open: nil}} = socket), do: socket

  def sync_quick_open(%{assigns: %{quick_open: data}} = socket) do
    if data.finder, do: FileFinder.stop(data.finder)
    assign(socket, quick_open: nil)
  end

  # Quick Open waits for its file finder: listing, or a query not answered yet.
  def quick_open_busy?(%{mode: :quick_open, query: query}, %{} = data) do
    case QuickOpen.mode(query) do
      {:files, q} -> data.loading? or data.results_for != q
      {:symbols, _} -> data.symbols_ref != nil
      {:workspace_symbols, _} -> data.workspace_ref != nil
      _ -> false
    end
  end

  def quick_open_busy?(_palette, _data), do: false

  # Commands whose "commandPalette" menu entry has a `when` that is false
  # (e.g. commands that need arguments from a view item).
  defp hidden_from_palette(assigns, ctx) do
    for %{command: id, when_ast: when_ast} <- assigns.menu_items["commandPalette"] || [],
        not Bee.Commands.When.eval(when_ast, ctx),
        into: MapSet.new(),
        do: id
  end

  defp palette_choose(socket, %{kind: :command, id: id}),
    do: socket |> change(&Workbench.close_palette/1) |> Commands.run_command(id)

  defp palette_choose(socket, %{kind: :mode, prefix: prefix}),
    do: change(socket, &Workbench.open_quick_open(&1, prefix))

  defp palette_choose(socket, %{kind: :symbol, place: place}),
    do: socket |> change(&Workbench.close_palette/1) |> LanguageFeatures.open_place(place)

  defp palette_choose(socket, %{kind: :file, path: path}) do
    socket = change(socket, &Workbench.close_palette/1)

    if File.regular?(path) do
      # Already open: switched to (open_buffer records the others).
      if Workbench.open?(workbench(socket), path), do: RecentFiles.add(socket.assigns.root, path)
      change(socket, &Workbench.open_editor(&1, path))
    else
      Notifications.notify(socket, :error, "Cannot open #{path}: no such file")
    end
  end

  defp palette_choose(%{assigns: %{palette: palette}} = socket, item),
    do: palette_answer(socket, palette, item.value)

  # What was picked or typed: to who asked (`reply`), or to the palette's command.
  defp palette_answer(socket, %{reply: {pid, ref}}, value) do
    send(pid, {:bee_answer, ref, value})
    change(socket, &Workbench.close_palette/1)
  end

  defp palette_answer(socket, palette, value) do
    socket
    |> change(&Workbench.close_palette/1)
    |> Commands.run_command(palette.command, palette.arguments ++ [value])
  end

  # Every query character appears in order ("tgpan" matches "Toggle Panel").
  defp fuzzy_match?(_label, ""), do: true

  defp fuzzy_match?(label, query) do
    Enum.reduce_while(String.graphemes(query), label, fn char, rest ->
      case String.split(rest, char, parts: 2) do
        [_, rest] -> {:cont, rest}
        [_] -> {:halt, nil}
      end
    end) != nil
  end

  # Asks for what the query's mode lists, once per file (@) or query (#):
  # the answers come as {:language_reply, ref, …} (symbols_reply/3).
  defp sync_symbols(socket, data, {:symbols, _query}) do
    path = Workbench.active_file(workbench(socket))

    if data.symbols_ref == nil and data.symbols == nil and path != nil do
      ref = make_ref()

      Bee.Languages.Features.request(
        socket.assigns.root,
        "documentSymbol",
        path,
        %{},
        {self(), ref}
      )

      %{data | symbols_ref: ref, symbols_path: path}
    else
      data
    end
  end

  defp sync_symbols(socket, data, {:workspace_symbols, query}) do
    if query != data.workspace_sent do
      ref = make_ref()
      params = %{query: query}

      Bee.Languages.Features.request(
        socket.assigns.root,
        "workspaceSymbol",
        nil,
        params,
        {self(), ref}
      )

      %{data | workspace_ref: ref, workspace_sent: query}
    else
      data
    end
  end

  defp sync_symbols(_socket, data, _mode), do: data

  def symbols_reply?(%{symbols_ref: ref}, ref) when ref != nil, do: true
  def symbols_reply?(%{workspace_ref: ref}, ref) when ref != nil, do: true
  def symbols_reply?(_data, _ref), do: false

  def symbols_reply(%{assigns: %{quick_open: data}} = socket, ref, reply) do
    symbols =
      case reply do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    data =
      if data.symbols_ref == ref,
        do: %{data | symbols_ref: nil, symbols: symbols},
        else: %{data | workspace_ref: nil, workspace_symbols: symbols}

    assign(socket, quick_open: data)
  end

  # The file's symbols matching the query, in file order, nested ones
  # indented; the workspace's, as its extensions found them for the query.
  defp symbol_items(%{quick_open: %{symbols: symbols, symbols_path: path}}, {:symbols, query})
       when is_list(symbols) do
    query = String.downcase(String.trim(query))

    for %{"name" => name} = symbol <- symbols, fuzzy_match?(String.downcase(name), query) do
      %{
        kind: :symbol,
        label: String.duplicate("  ", if(query == "", do: symbol["depth"] || 0, else: 0)) <> name,
        description:
          Enum.join(Enum.reject([symbol["kind"], symbol["detail"]], &(&1 in [nil, ""])), " · "),
        section: "line #{symbol["from"]["line"] + 1}",
        place: %{"path" => path, "from" => symbol["from"]}
      }
    end
  end

  defp symbol_items(
         %{quick_open: %{workspace_symbols: symbols}} = assigns,
         {:workspace_symbols, _}
       )
       when is_list(symbols) do
    for %{"name" => name, "path" => path} = symbol <- symbols do
      %{
        kind: :symbol,
        label: name,
        description:
          Enum.join(Enum.reject([symbol["kind"], symbol["container"]], &(&1 in [nil, ""])), " · "),
        section: "#{display_path(assigns.root, path)}:#{symbol["from"]["line"] + 1}",
        place: %{"path" => path, "from" => symbol["from"]}
      }
    end
  end

  defp symbol_items(_assigns, _mode), do: []
end

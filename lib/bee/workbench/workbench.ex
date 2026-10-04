defmodule Bee.Workbench do
  @moduledoc """
  The state of one editor window – open editors, panel, terminals, menus,
  palette – and the functions that change it.

  Functions return the new workbench, or `{workbench, effects}` when
  something has to happen outside the struct. The LiveView carries effects
  out (`BeeWeb.EditorLive.run_effects/2`):

    * `{:push, event, payload}` – event to the browser (CodeMirror etc.)
    * `{:open_file, path}` – open a `Bee.Editor.Buffer`, then `editor_opened/3`
    * `{:close_buffer, path}` – detach from the file's `Bee.Editor.Buffer`
    * `:new_terminal` – start a `Bee.Terminal`, then `terminal_started/3`
    * `{:stop_terminal, id}` – stop it (`{:forget_terminal, id}` when it already exited)
    * `:panel_hidden` – the terminals' xterm views were unmounted
    * `{:exec_client, command}` – run a client-side command in the browser
    * `{:flash, kind, message}`

  Commands (`Bee.Workbench.Actions`) are built from these functions.
  """

  defstruct root: nil,
            tabs: [],
            active: nil,
            status: nil,
            sidebar_open: true,
            panel_open: false,
            terminals: [],
            active_term: nil,
            open_menu: nil,
            palette: nil

  @type tab :: %{path: String.t(), dirty: boolean()}
  @type terminal :: %{id: integer(), name: String.t()}
  @type effect :: tuple() | atom()
  @type t :: %__MODULE__{}

  @fields [
    :tabs,
    :active,
    :status,
    :sidebar_open,
    :panel_open,
    :terminals,
    :active_term,
    :open_menu,
    :palette,
    :root
  ]

  @doc "The struct's fields (the LiveView keeps them as individual assigns)."
  def fields, do: @fields

  def new(root), do: %__MODULE__{root: root}

  @doc "Normalizes a handler result to `{workbench, effects}`."
  def wrap({%__MODULE__{} = wb, effects}) when is_list(effects), do: {wb, effects}
  def wrap(%__MODULE__{} = wb), do: {wb, []}

  @doc "Runs `fun` on the workbench of `{wb, effects}`, collecting its effects."
  def chain({wb, effects}, fun) do
    {wb, more} = wrap(fun.(wb))
    {wb, effects ++ more}
  end

  ## Editors

  def open?(wb, path), do: Enum.any?(wb.tabs, &(&1.path == path))

  @doc "Shows `path`: activates its tab, or asks for the file to be opened."
  def open_editor(wb, path) do
    if open?(wb, path), do: activate_editor(wb, path), else: {wb, [{:open_file, path}]}
  end

  @doc "Called once the buffer for `path` is open."
  def editor_opened(wb, path, dirty) do
    %{wb | tabs: wb.tabs ++ [%{path: path, dirty: dirty}], active: path}
  end

  def activate_editor(wb, path) do
    if open?(wb, path) do
      {%{wb | active: path}, [{:push, "cm:activate", %{path: path}}]}
    else
      wb
    end
  end

  def close_editor(wb, path) do
    case Enum.find_index(wb.tabs, &(&1.path == path)) do
      nil ->
        wb

      index ->
        remaining = List.delete_at(wb.tabs, index)
        effects = [{:close_buffer, path}, {:push, "cm:close", %{path: path}}]
        wb = %{wb | tabs: remaining}

        cond do
          wb.active != path ->
            {wb, effects}

          remaining == [] ->
            {%{wb | active: nil}, effects}

          true ->
            neighbour = Enum.at(remaining, min(index, length(remaining) - 1)).path
            chain({wb, effects}, &activate_editor(&1, neighbour))
        end
    end
  end

  def set_dirty(wb, path, dirty) do
    %{wb | tabs: Enum.map(wb.tabs, &if(&1.path == path, do: %{&1 | dirty: dirty}, else: &1))}
  end

  ## Layout

  def toggle_sidebar(wb), do: %{wb | sidebar_open: not wb.sidebar_open}

  @doc """
  Closing the panel keeps the shells running (their views re-attach on
  reopen); opening an empty panel starts a shell.
  """
  def toggle_panel(%{panel_open: true} = wb), do: {%{wb | panel_open: false}, [:panel_hidden]}
  def toggle_panel(%{terminals: []} = wb), do: {wb, [:new_terminal]}
  def toggle_panel(wb), do: %{wb | panel_open: true}

  ## Terminals

  def terminal?(wb, id), do: Enum.any?(wb.terminals, &(&1.id == id))

  @doc "Called once a `Bee.Terminal` with `id` is running."
  def terminal_started(wb, id, name) do
    %{wb | terminals: wb.terminals ++ [%{id: id, name: name}], active_term: id, panel_open: true}
  end

  def activate_terminal(wb, id) do
    if terminal?(wb, id), do: %{wb | active_term: id}, else: wb
  end

  def kill_terminal(wb, id) do
    if terminal?(wb, id), do: {remove_terminal(wb, id), [{:stop_terminal, id}]}, else: wb
  end

  @doc "The shell exited on its own."
  def terminal_exited(wb, id) do
    if terminal?(wb, id), do: {remove_terminal(wb, id), [{:forget_terminal, id}]}, else: wb
  end

  defp remove_terminal(wb, id) do
    terminals = Enum.reject(wb.terminals, &(&1.id == id))

    active =
      cond do
        wb.active_term != id -> wb.active_term
        terminals == [] -> nil
        true -> List.last(terminals).id
      end

    %{wb | terminals: terminals, active_term: active}
  end

  ## Menus and palette

  def toggle_menu(wb, menu), do: %{wb | open_menu: if(wb.open_menu == menu, do: nil, else: menu)}
  def close_menu(wb), do: %{wb | open_menu: nil}

  def open_palette(wb), do: %{wb | palette: %{query: "", index: 0}, open_menu: nil}
  def close_palette(wb), do: %{wb | palette: nil}
  def filter_palette(wb, query), do: %{wb | palette: %{query: query, index: 0}}

  @doc "Moves the palette selection by `delta`, within `count` items."
  def move_palette(%{palette: %{index: index} = p} = wb, delta, count) do
    %{wb | palette: %{p | index: index |> Kernel.+(delta) |> min(count - 1) |> max(0)}}
  end

  def move_palette(wb, _delta, _count), do: wb

  def set_status(wb, status), do: %{wb | status: status}

  ## `when` context

  @doc """
  The server half of the `when` context (VS Code context keys where they
  exist). `settings` adds `config.*`. The browser adds focus keys.
  """
  def context(wb, settings \\ %{}) do
    active = wb.active

    settings
    |> Map.new(fn {key, value} -> {"config." <> key, value} end)
    |> Map.merge(%{
      "activeEditor" => active && Bee.Workspace.FS.relative(wb.root, active),
      "activeEditorIsDirty" => Enum.any?(wb.tabs, &(&1.path == active and &1.dirty)),
      "resourceFilename" => active && Path.basename(active),
      "resourceExtname" => active && Path.extname(active),
      "resourcePath" => active,
      "editorLangId" => active && Bee.Editor.Lang.detect(active),
      "editorIsOpen" => wb.tabs != [],
      "sideBarVisible" => wb.sidebar_open,
      "panelVisible" => wb.panel_open,
      "terminalCount" => length(wb.terminals),
      "inQuickOpen" => wb.palette != nil,
      "menuOpen" => wb.open_menu != nil
    })
  end
end

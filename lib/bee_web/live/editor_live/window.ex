defmodule BeeWeb.EditorLive.Window do
  @moduledoc """
  The window's state, and how it changes.

  The state is a `%Bee.Workbench{}`, kept as individual assigns (one per
  field) so LiveView change tracking stays fine-grained: `workbench/1` puts
  it together, `change/2` applies a `Bee.Workbench` function (or a command
  handler) to it and performs the effects that returns
  (`BeeWeb.EditorLive.Effects`).

  Also what the other parts of the window share: the `when` context
  (`context/1`), what plugins are told of the window (`plugin_context/1`),
  its open tabs, and how paths are shown. The parts import this module.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Bee.Settings
  alias Bee.Workbench
  alias Bee.Commands.Keybindings
  alias BeeWeb.EditorLive.{Config, Effects, Extensions, Layout, Palette, Webviews}

  # Whether a click opens a file as a preview (workbench.editor.enablePreview).
  def preview?(socket), do: socket.assigns.settings["workbench.editor.enablePreview"] != false

  def workbench(socket), do: workbench_from(socket.assigns)
  def workbench_from(assigns), do: struct(Workbench, Map.take(assigns, Workbench.fields()))

  def put_workbench(socket, wb),
    do: assign(socket, Map.take(Map.from_struct(wb), Workbench.fields()))

  # Applies `fun` (a Workbench function or command handler) and its effects.
  def change(socket, fun) do
    before = workbench(socket)
    {wb, effects} = Workbench.wrap(fun.(before))

    socket
    |> put_workbench(wb)
    |> Effects.run_effects(effects)
    |> Palette.sync_quick_open()
    |> Config.sync_theme()
    |> Extensions.sync_extension_details()
    |> sync_asked(before)
    |> sync_active_editor(before)
    |> Webviews.sync_webviews(before)
    |> Layout.sync_containers(before)
  end

  # A question asked through the palette (`reply`) that closed, or made way
  # for something else: answered with nothing. (After an answer, that is a
  # second one, which nobody waits for.)
  defp sync_asked(socket, %{palette: %{reply: {pid, ref}}}) do
    case socket.assigns.palette do
      %{reply: {^pid, ^ref}} -> :ok
      _ -> send(pid, {:bee_answer, ref, nil})
    end

    socket
  end

  defp sync_asked(socket, _before), do: socket

  # Another file is shown: what VS Code extensions see as the active editor.
  defp sync_active_editor(socket, before) do
    if Workbench.active_file(before) != Workbench.active_file(workbench(socket)),
      do: tell_extension_host(socket)

    socket
  end

  def tell_extension_host(socket) do
    a = socket.assigns
    active = Workbench.active_file(workbench(socket))
    Bee.Extensions.Host.active_editor(a.root, self(), active, selections(a.selection, active))
  end

  # The selections of file `path`, as the editor sent them: `[{from, to}]`,
  # positions (`Bee.Editor.Positions`).
  def selections({path, ranges}, path) when path != nil, do: ranges
  def selections(_selection, _path), do: []

  # Every group's tabs, one per editor (a file open in two groups: once).
  def open_tabs(socket),
    do: socket |> workbench() |> Workbench.all_tabs() |> Enum.uniq_by(& &1.path)

  def plugin_context(assigns) do
    active = Workbench.active_file(workbench_from(assigns))

    # Plugins count in bytes: of the text the file has now.
    selections =
      with [_ | _] = ranges <- selections(assigns.selection, active),
           text when is_binary(text) <- Bee.API.text(active) do
        for {from, to} <- ranges do
          {Bee.Extensions.Host.position_to_bytes(text, from),
           Bee.Extensions.Host.position_to_bytes(text, to)}
        end
      else
        _ -> []
      end

    %Bee.Plugins.Context{
      window: self(),
      root: assigns.root,
      active_editor: active,
      language: active && Workbench.language(workbench_from(assigns), active),
      selections: selections
    }
  end

  def int(nil), do: nil
  def int(value) when is_integer(value), do: value
  def int(value) when is_binary(value), do: String.to_integer(value)

  # The server half of the `when` context, as it is now. The page and its
  # menus use the one kept in the assigns (`BeeWeb.EditorLive.Derived`).
  def context(assigns) do
    wb = workbench_from(assigns)
    active = Workbench.active_file(wb)

    assigns.config_context
    |> Map.merge(Workbench.context(wb))
    |> Map.put(
      "editorHasSelection",
      match?({^active, _}, assigns[:selection]) and active != nil and
        Enum.any?(elem(assigns.selection, 1), fn {from, to} -> from != to end)
    )
    |> Map.put("notificationCenterVisible", assigns[:notifications_open] == true)
    |> Map.merge(
      language_context(assigns[:root], active, active && Workbench.language(wb, active))
    )
    |> Map.merge(assigns[:ui_context] || %{})
  end

  # VS Code's editorHas…Provider keys, of the shown file.
  @provider_keys %{
    "completion" => "editorHasCompletionItemProvider",
    "hover" => "editorHasHoverProvider",
    "definition" => "editorHasDefinitionProvider",
    "typeDefinition" => "editorHasTypeDefinitionProvider",
    "declaration" => "editorHasDeclarationProvider",
    "implementation" => "editorHasImplementationProvider",
    "formatting" => "editorHasDocumentFormattingProvider",
    "rangeFormatting" => "editorHasDocumentSelectionFormattingProvider",
    "signatureHelp" => "editorHasSignatureHelpProvider",
    "references" => "editorHasReferenceProvider",
    "rename" => "editorHasRenameProvider",
    "documentSymbol" => "editorHasDocumentSymbolProvider",
    "documentHighlight" => "editorHasDocumentHighlightProvider",
    "codeAction" => "editorHasCodeActionsProvider"
  }

  defp language_context(root, path, language) when is_binary(root) and is_binary(path) do
    features = Bee.Languages.Features.for_file(root, path, language)
    Map.new(@provider_keys, fn {feature, key} -> {key, Map.has_key?(features, feature)} end)
  end

  defp language_context(_root, _path, _language), do: %{}

  # "file — workspace", like VS Code's window title.
  def window_title(nil, root), do: Path.basename(root)
  def window_title(label, root), do: "#{label} — #{Path.basename(root)}"

  # Workspace-relative where possible; settings files get readable names.
  def display_path(root, path) do
    cond do
      path == Settings.user_path() -> "User Settings"
      path == Keybindings.user_path() -> "Keyboard Shortcuts"
      String.starts_with?(path, root <> "/") -> Path.relative_to(path, root)
      true -> path
    end
  end
end

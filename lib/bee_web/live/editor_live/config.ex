defmodule BeeWeb.EditorLive.Config do
  @moduledoc """
  What is configured and contributed, as assigns: settings, the color and
  file icon themes, commands, menus and keybindings – loaded at mount and
  again when they change.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Languages
  alias Bee.Settings
  alias Bee.Commands.Registry, as: CommandRegistry
  alias Bee.Commands.Keybindings
  alias BeeWeb.EditorLive.{Editors, Extensions, Json, Palette, Views}

  ## Messages

  # Ours changed: the user's settings, or this window's workspace's.
  def handle_info({:settings_changed, scope}, socket)
      when scope == :user or scope == {:workspace, socket.assigns.root} do
    old = socket.assigns.settings
    {settings, errors} = {Settings.all(socket.assigns.root), Settings.errors(socket.assigns.root)}

    if settings["files.exclude"] != old["files.exclude"],
      do: send_update(BeeWeb.Workbench.FileTree, id: "explorer", refresh: true)

    socket = load_settings(socket, settings, errors)

    if settings["files.associations"] != old["files.associations"],
      do: {:halt, Editors.redetect_languages(socket)},
      else: {:halt, socket}
  end

  def handle_info({:keybindings_changed, bindings, errors}, socket),
    do: {:halt, load_keybindings(socket, bindings, errors)}

  def handle_info({:contributions_changed, keys}, socket) do
    socket = if :commands in keys, do: load_commands(socket), else: socket

    socket =
      if :views in keys do
        socket = socket |> Views.load_views() |> Extensions.load_live()

        # The shown container went away with its plugin.
        if Enum.any?(socket.assigns.containers, &(&1.id == socket.assigns.sidebar_view)),
          do: socket,
          else: change(socket, &%{&1 | sidebar_view: "explorer"})
      else
        socket
      end

    socket =
      if :languages in keys,
        do: socket |> assign(grammars: Languages.grammars()) |> Editors.redetect_languages(),
        else: socket

    socket =
      if :json_validation in keys or :languages in keys,
        do: Json.validate_open_json(socket),
        else: socket

    socket =
      if :icon_themes in keys,
        do: assign(socket, icon_theme: icon_theme(socket.assigns)),
        else: socket

    socket = if :color_themes in keys, do: sync_theme(socket, true), else: socket

    {:halt, socket}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  def load_settings(socket, settings, errors) do
    socket
    |> assign(
      settings: settings,
      settings_errors: errors,
      editor_settings: %{
        fontSize: settings["editor.fontSize"],
        tabSize: settings["editor.tabSize"],
        wordWrap: settings["editor.wordWrap"],
        lineNumbers: settings["editor.lineNumbers"]
      },
      terminal_settings: %{fontSize: settings["terminal.integrated.fontSize"]}
    )
    |> sync_theme(true)
  end

  # The color theme shown: the one selected in the Color Theme pick while
  # it is open (a preview), else workbench.colorTheme's. Loaded again only
  # when that changes, or when `reload?` (settings or themes changed).
  def sync_theme(socket, reload? \\ false) do
    id = previewed_theme(socket.assigns) || socket.assigns.settings["workbench.colorTheme"]

    if not reload? and socket.assigns[:color_theme_id] == id do
      socket
    else
      theme = Bee.ColorThemes.get(id)
      base = to_string(theme.base)
      colors = theme.custom?

      socket
      |> assign(
        color_theme_id: id,
        color_theme: theme,
        color_theme_css: Bee.ColorThemes.Theme.css(theme, "#workbench"),
        token_colors: Bee.ColorThemes.Theme.token_colors(theme),
        editor_settings:
          Map.merge(socket.assigns.editor_settings, %{theme: base, themeColors: colors}),
        terminal_settings:
          Map.merge(socket.assigns.terminal_settings, %{
            theme: base,
            colors: Bee.ColorThemes.Theme.terminal(theme)
          })
      )
      |> then(&assign(&1, icon_theme: icon_theme(&1.assigns)))
    end
  end

  defp previewed_theme(%{palette: %{mode: :pick, preview: :color_theme, index: index}} = assigns) do
    case Enum.at(Palette.palette_items(assigns), index) do
      %{value: id} -> id
      nil -> nil
    end
  end

  defp previewed_theme(_assigns), do: nil

  # The file icon theme picked in workbench.iconTheme, in its variant for
  # the color theme's base; nil (Bee's own icons) when none is set or it
  # isn't loaded (yet).
  defp icon_theme(%{settings: settings, color_theme: color_theme}) do
    with id when is_binary(id) <- settings["workbench.iconTheme"],
         {:ok, theme} <- Bee.IconThemes.load(id, color_theme.base) do
      theme
    else
      _ -> nil
    end
  end

  def load_commands(socket) do
    socket
    |> assign(commands: CommandRegistry.commands(), menus: CommandRegistry.menus())
    |> then(&load_keybindings(&1, &1.assigns.keybindings, &1.assigns.keybinding_errors))
  end

  # Bindings of client commands carry their enablement: the browser runs those
  # itself, without a round trip.
  defp load_keybindings(socket, bindings, errors) do
    commands = Map.new(socket.assigns[:commands] || [], &{&1.id, &1})

    client =
      Enum.map(bindings, fn binding ->
        base = Map.take(binding, [:key, :mac, :linux, :win, :command, :when])
        # Sent with run_command (and to client commands) when it has any.
        base =
          if binding.args == nil,
            do: base,
            else: Map.put(base, :args, Keybindings.arguments(binding.args))

        case commands[binding.command] do
          %{runtime: :client, enablement_ast: ast} ->
            Map.merge(base, %{client: true, enablement: ast})

          _ ->
            base
        end
      end)

    assign(socket, keybindings: bindings, keybinding_errors: errors, client_keybindings: client)
  end
end

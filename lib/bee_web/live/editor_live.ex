defmodule BeeWeb.EditorLive do
  @moduledoc """
  The editor window.

  This module mounts the window and puts its parts together; the parts are
  the modules under `BeeWeb.EditorLive`, each with the events of the page
  and the messages it handles itself (`handle_event/3`, `handle_info/2`,
  attached as hooks: `{:halt, socket}` when it was theirs, `{:cont, socket}`
  when not):

  - `Window`: the window's state, a `%Bee.Workbench{}` kept as individual
    assigns, and how it changes (`Window.change/2`); the `when` context.
  - `Effects`: performs what `Bee.Workbench` functions and command handlers
    ask for (buffers, terminals, browser events).
  - `Commands`, `Menus`, `Palette`: every user action goes through
    `Commands.run_command/4` with a `Bee.Commands.Registry` id – from the
    menus, the palette, keybindings and buttons.
  - `Editors`, `Formatting`, `LanguageFeatures`, `Json`, `Problems`: the
    files shown – text lives in CodeMirror (the `CodeEditor` hook) and in a
    `Bee.Editor.Buffer` per file – and what extensions know of them.
  - `Views`, `Layout`, `SearchView`, `Terminals`, `Output`, `Webviews`,
    `Notifications`: the sidebar, the panel and what they show.
  - `Extensions`, `PluginAPI`: the plugins installed, and what they ask of
    the window (`Bee.API`).
  - `Config`: settings, themes, commands and keybindings, as assigns.
  - `Derived`: what the page shows that is computed from other assigns
    (the `when` context, menus, toolbars), kept up to date after every
    event and message a part handled.

  The page itself is editor_live.html.heex, with the components of
  `BeeWeb.Workbench`.
  """
  use BeeWeb, :live_view

  alias Bee.{Languages, Plugins, Settings, Workbench, Workspace}
  alias Bee.Commands.Registry, as: CommandRegistry
  alias Bee.Commands.Keybindings
  alias Bee.Editor.Buffer
  alias BeeWeb.Workbench.EditorArea

  alias BeeWeb.EditorLive.{
    Commands,
    Config,
    Derived,
    Editors,
    Extensions,
    Formatting,
    Json,
    LanguageFeatures,
    Layout,
    Notifications,
    Output,
    Palette,
    PluginAPI,
    Problems,
    SearchView,
    Terminals,
    Views,
    Webviews,
    Window
  }

  # The parts that handle events of the page or messages.
  @parts [
    Commands,
    Palette,
    Editors,
    Formatting,
    LanguageFeatures,
    Json,
    Problems,
    Views,
    Layout,
    SearchView,
    Terminals,
    Output,
    Webviews,
    Notifications,
    Extensions,
    PluginAPI,
    Config
  ]

  # Their callbacks, found when this module compiles: `{part, stage, fun}`.
  @hooks for part <- @parts,
             {stage, arity} <- [handle_event: 3, handle_info: 2],
             Code.ensure_compiled!(part),
             function_exported?(part, stage, arity),
             do: {part, stage, Function.capture(part, stage, arity)}

  @impl true
  def mount(params, _session, socket) do
    # The window's folder: ?folder=…, else the one Bee was started for.
    {root, problem} = folder(params["folder"])

    # Subscribed before the workspace opens: what starting it says (a plugin
    # that fails to activate) is for this window too.
    if connected?(socket) do
      subscribe(root)
      Workspace.open(root)
    end

    {:ok,
     socket
     |> attach_parts()
     |> assign(page_title: Path.basename(root), selection: nil)
     |> assign(root: root)
     |> assign(connected: connected?(socket))
     |> assign(view_inputs: %{}, collapsed: MapSet.new(), collapsed_views: MapSet.new())
     |> assign(view_sizes: %{})
     |> assign(quick_open: nil)
     |> Views.load_views()
     |> assign(status_items: Bee.UI.status_items(root), ui_context: Bee.UI.context(root))
     |> Views.load_decorations()
     |> Window.put_workbench(Layout.restore_layout(Workbench.new(root), socket))
     |> Config.load_settings(Settings.all(root), Settings.errors(root))
     |> assign(keybindings: Keybindings.all(), keybinding_errors: Keybindings.errors())
     |> Config.load_commands()
     |> Extensions.load_plugins()
     |> assign(grammars: Languages.grammars())
     |> assign(diagnostics: %{}, json_jobs: %{})
     |> assign(language_problems: Problems.language_problems(root), language_problems_timer: nil)
     |> assign(language_features: 0, language_gotos: %{}, formats: %{})
     |> assign(renames: %{}, references: nil, code_actions: %{}, problems_hidden: [])
     |> Webviews.load_webviews()
     |> Output.load_output_channels()
     |> assign(notifications: [], toasts: [], notifications_open: false)
     |> assign(progress: Bee.UI.progress(root))
     |> allow_upload(:vsix,
       accept: :any,
       max_entries: 1,
       max_file_size: 200_000_000,
       auto_upload: true,
       progress: &vsix_progress/3
     )
     |> then(&if(problem, do: Notifications.notify(&1, :error, problem), else: &1))
     |> open_file_param(params["file"])
     |> Derived.sync()}
  end

  defp vsix_progress(name, entry, socket) do
    {:noreply, socket} = Extensions.vsix_progress(name, entry, socket)
    {:noreply, Derived.sync(socket)}
  end

  # `{root, problem}`: the folder asked for, or Bee's own with why not.
  defp folder(nil), do: {Workspace.root(), nil}

  defp folder(path) do
    root = Path.expand(path)

    if File.dir?(root),
      do: {root, nil},
      else: {Workspace.root(), "Can't open #{root}: not a folder"}
  end

  # What the window follows: Bee's own changes, and its workspace's.
  defp subscribe(root) do
    Workspace.subscribe()
    Buffer.subscribe()
    Settings.subscribe()
    Keybindings.subscribe()
    CommandRegistry.subscribe()
    Plugins.subscribe()
    Bee.API.subscribe_window(root)
    Bee.UI.subscribe(root)
    Bee.Diagnostics.subscribe(root)
    Bee.Languages.Features.subscribe(root)
    Bee.Webviews.subscribe(root)
    Bee.Output.subscribe(root)
  end

  # Each part gets the page's events and the window's messages, until one
  # takes them: what the page computes from the assigns it changed is
  # computed again then (`Derived`).
  defp attach_parts(socket) do
    Enum.reduce(@hooks, socket, fn
      {part, :handle_event, fun}, socket ->
        attach_hook(socket, part, :handle_event, &handled(fun.(&1, &2, &3)))

      {part, :handle_info, fun}, socket ->
        attach_hook(socket, part, :handle_info, &handled(fun.(&1, &2)))
    end)
  end

  defp handled({:halt, socket}), do: {:halt, Derived.sync(socket)}
  defp handled({:halt, reply, socket}), do: {:halt, reply, Derived.sync(socket)}
  defp handled({:cont, socket}), do: {:cont, socket}

  # ?file=… or ?file[]=…: files to open (the desktop app's `bee FILE…`),
  # once connected.
  defp open_file_param(socket, files) do
    if connected?(socket) do
      for path <- List.wrap(files), is_binary(path), path != "", reduce: socket do
        socket ->
          Commands.run_command(socket, "bee.openFile", [Path.expand(path, socket.assigns.root)])
      end
    else
      socket
    end
  end

  # Nobody's: the remaining buffer events are for plugins and LSP.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}
end

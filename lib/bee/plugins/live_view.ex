defmodule Bee.Plugin.LiveView do
  @moduledoc """
  A plugin's own user interface: a LiveView – Elixir, with HEEx templates –
  drawn in one of its views (sidebar, panel) or in an editor tab, next to
  the plugin's server part (`Bee.Plugin`).

      defmodule Todos.ListLive do
        use Bee.Plugin.LiveView

        @impl true
        def mount(_params, _session, socket) do
          {:ok, todos} = request(socket, "todos")
          {:ok, assign(socket, todos: todos)}
        end

        @impl true
        def render(assigns) do
          ~H\"""
          <ul>
            <li :for={todo <- @todos} phx-click="open" phx-value-id={todo["id"]}>{todo["text"]}</li>
          </ul>
          \"""
        end

        @impl true
        def handle_event("open", %{"id" => id}, socket),
          do: {:noreply, run_command(socket, "todos.open", [id])}

        # Bee.API.push_live(ctx, "todos.list", {:todos, todos}) of the server part.
        @impl true
        def handle_info({:todos, todos}, socket), do: {:noreply, assign(socket, todos: todos)}
      end

  The manifest names it, by its module:

      "views": {"todos": [{"id": "todos.list", "name": "TODOs", "live": "Todos.ListLive"}]},
      "editors": [{"id": "todos.board", "title": "TODO Board", "live": "Todos.BoardLive"}]

  A view shows it in place of the data of `Bee.API.set_view/3`; an editor
  opens in a tab with `Bee.API.open_editor/3`. The module is one of the
  plugin's server sources (`lib/`), compiled with them; templates are `~H`
  or `.html.heex` files next to it (`embed_templates "*"`). A plugin with
  LiveViews has a server part: its code is loaded when that starts.

  It is an ordinary `Phoenix.LiveView`, nested in the window (a process of
  its own: its crash doesn't take the window down), with `@bee` assigned:

    * `plugin`, `root` – the plugin and the folder of the window's workspace
    * `id` – the view's or editor's id; `kind` – `:view` or `:editor`
    * `params` – what `Bee.API.open_editor/3` was given (`%{}` for a view)
    * `window` – the window's process

  and these helpers imported:

    * `request(socket, method, params)` – asks the plugin's server part
      (`handle_request/4`), waiting for `{:ok, result}` or `{:error, message}`
    * `run_command(socket, id, args)` – runs a command (Bee's or a
      plugin's) in the window

  The server part sends it messages with `Bee.API.push_live/3`: they
  arrive in `handle_info/2`.

  Its markup can use Bee's theme (the `--vscode-*` CSS variables, the
  classes of Bee's own CSS); what else it needs comes from the plugin's
  stylesheet (`"styles"` in the manifest). Its `phx-hook`s are registered
  by the plugin's browser part (`bee.registerHook(name, hook)`).
  """

  alias Bee.Plugins.Context

  defmacro __using__(opts) do
    quote do
      use Phoenix.LiveView, unquote(opts)

      import Bee.Plugin.LiveView,
        only: [request: 2, request: 3, request: 4, run_command: 2, run_command: 3]

      on_mount Bee.Plugin.LiveView
    end
  end

  @doc "The topic `Bee.API.push_live/3` sends on."
  def topic(root, plugin, id), do: "plugin_live:#{root}:#{plugin}:#{id}"

  @doc false
  # Only reachable through the window that rendered it (live_render's
  # signed session): no access check of its own.
  def on_mount(:default, _params, session, socket) do
    bee = %{
      plugin: session["plugin"],
      root: session["root"],
      id: session["id"],
      kind: if(session["kind"] == "editor", do: :editor, else: :view),
      params: session["params"] || %{},
      window: socket.parent_pid
    }

    if Phoenix.LiveView.connected?(socket),
      do: Phoenix.PubSub.subscribe(Bee.PubSub, topic(bee.root, bee.plugin, bee.id))

    # Bee.API in this process acts on this workspace.
    Process.put(:bee_workspace, bee.root)
    {:cont, Phoenix.Component.assign(socket, :bee, bee)}
  end

  @doc """
  Asks the plugin's server part: its `handle_request(method, params, ctx,
  state)` answers. Returns `{:ok, result}` (JSON-like data, as it gave it)
  or `{:error, message}`; waits `timeout` ms.
  """
  def request(socket, method, params \\ nil, timeout \\ 5_000) do
    %{plugin: plugin, root: root} = socket.assigns.bee
    ref = make_ref()

    case Bee.Plugins.request(plugin, method, params, %Context{root: root, window: self()}, ref) do
      :ok ->
        receive do
          {:bee_api, {:reply, ^ref, reply}} -> reply
        after
          timeout -> {:error, "#{plugin} didn't answer #{method} in #{timeout}ms"}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Runs command `id` in the window, with `args`. Returns the socket."
  def run_command(socket, id, args \\ []) do
    send(socket.assigns.bee.window, {:bee_api, {:execute_command, to_string(id), args}})
    socket
  end
end

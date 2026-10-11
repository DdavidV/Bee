defmodule BeeWeb.EditorLive.Extensions do
  @moduledoc """
  Plugins and extensions in the window: the ones installed, the LiveViews
  they draw with (`BeeWeb.Workbench.PluginLive`), their details in editor
  tabs, Open VSX (the Plugins view's search box, `Bee.Workbench.Marketplace`)
  and installing from a VSIX file.
  """

  import Phoenix.Component, only: [assign: 2, update: 3, upload_errors: 2]
  import Phoenix.LiveView
  import BeeWeb.EditorLive.Window

  alias Bee.Plugins
  alias Bee.Workbench
  alias Bee.Plugins.OpenVsx
  alias Bee.Workbench.Marketplace
  alias BeeWeb.EditorLive.Notifications

  ## Events

  def handle_event("marketplace_search", %{"query" => query}, socket) when is_binary(query),
    do: {:halt, change(socket, &Marketplace.update(&1, query))}

  def handle_event("marketplace_more", _params, socket),
    do: {:halt, change(socket, &Marketplace.more/1)}

  def handle_event("marketplace_retry", _params, socket),
    do: {:halt, change(socket, &Marketplace.refresh/1)}

  # An Open VSX extension's details failed to load: again.
  def handle_event("openvsx_details_retry", %{"id" => id}, socket) when is_binary(id) do
    {:halt,
     socket
     |> update(:extension_details, &Map.delete(&1, id))
     |> sync_extension_details()}
  end

  # Required by uploads; the file goes up as soon as it is picked.
  def handle_event("vsix_validate", _params, socket) do
    case socket.assigns.uploads.vsix.entries do
      [%{} = entry] ->
        case upload_errors(socket.assigns.uploads.vsix, entry) do
          [] ->
            {:halt, socket}

          errors ->
            {:halt,
             socket
             |> cancel_upload(:vsix, entry.ref)
             |> Notifications.notify(
               :error,
               "Can't upload #{entry.client_name}: #{inspect(errors)}"
             )}
        end

      _ ->
        {:halt, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  def handle_info(:plugins_changed, socket), do: {:halt, load_plugins(socket)}

  def handle_info({:marketplace_results, ref, offset, result}, socket),
    do: {:halt, change(socket, &Marketplace.results(&1, ref, offset, result))}

  def handle_info({:extension_installed, id, result}, socket) do
    socket = socket |> change(&Marketplace.installed(&1, id)) |> load_plugins()

    case result do
      {:ok, name} ->
        {:halt, Notifications.notify(socket, :info, "Installed #{id} as the plugin #{name}")}

      {:error, message} ->
        {:halt, Notifications.notify(socket, :error, "Can't install #{id}: #{message}")}
    end
  end

  def handle_info({:openvsx_details, id, result}, socket) do
    details =
      case {socket.assigns.extension_details[id], result} do
        {nil, _} -> nil
        {_, {:ok, details}} -> Map.merge(details, %{source: :openvsx, loading: false, error: nil})
        {old, {:error, message}} -> %{old | loading: false, error: message}
      end

    {:halt,
     if(details,
       do: update(socket, :extension_details, &Map.put(&1, id, details)),
       else: socket
     )}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  # The details of the plugins shown in editor tabs (BeeWeb.Workbench.ExtensionEditor),
  # read when a tab opens and again when plugins change (`reload?`). Tabs of
  # Open VSX extensions ("publisher.name", plugin names have no dots) are
  # fetched once, in a task (`{:openvsx_details, id, result}`).
  def sync_extension_details(socket, reload? \\ false) do
    cached = socket.assigns[:extension_details] || %{}

    details =
      for %{kind: :extension, name: name} <- open_tabs(socket), into: %{} do
        case {String.contains?(name, "."), Map.fetch(cached, name)} do
          {true, {:ok, details}} ->
            {name, details}

          {true, :error} ->
            fetch_openvsx_details(name)
            {name, %{source: :openvsx, id: name, display_name: name, loading: true, error: nil}}

          {false, {:ok, details}} when not reload? ->
            {name, details}

          {false, _} ->
            plugin = Enum.find(socket.assigns[:plugins] || [], &(&1.name == name))
            {name, plugin && Bee.Plugins.Details.get(plugin)}
        end
      end

    assign(socket, extension_details: details)
  end

  defp fetch_openvsx_details(id) do
    window = self()

    Task.Supervisor.start_child(Bee.Plugins.OpenVsx.TaskSup, fn ->
      send(window, {:openvsx_details, id, OpenVsx.details(id)})
    end)
  end

  def vsix_progress(:vsix, %{done?: false}, socket), do: {:noreply, socket}

  def vsix_progress(:vsix, entry, socket) do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Bee.Plugins.Vsix.install(path)}
      end)

    case result do
      {:ok, name} ->
        {:noreply,
         socket
         |> load_plugins()
         |> change(&Workbench.reveal_view(&1, "extensions"))
         |> Notifications.notify(:info, "Installed #{name} from #{entry.client_name}")}

      {:error, message} ->
        {:noreply, Notifications.notify(socket, :error, "#{entry.client_name}: #{message}")}
    end
  end

  def load_plugins(socket) do
    socket
    |> assign(
      plugins: Plugins.list(socket.assigns.root),
      plugin_errors: Plugins.errors(socket.assigns.root),
      browser_plugins: Plugins.browser_modules(socket.assigns.root),
      plugin_styles: Plugins.styles(socket.assigns.root),
      marketplace_installed: OpenVsx.installed()
    )
    |> sync_extension_details(true)
    |> load_live()
  end

  # The LiveViews plugins draw their views and editors with
  # (BeeWeb.Workbench.PluginLive): `{:view | :editor, id} => %{plugin, name,
  # module, status, load_id}`, `module` once the plugin's code is loaded.
  def load_live(socket) do
    plugins = Map.new(socket.assigns[:plugins] || [], &{&1.name, &1})

    declared =
      for(
        %{live: live, source: {:plugin, name}} = v <- Bee.Views.views(),
        live != nil,
        do: {{:view, v.id}, name, live}
      ) ++
        for(
          %{live: live, source: {:plugin, name}} = e <- Bee.Views.editors(),
          do: {{:editor, e.id}, name, live}
        )

    live =
      for {key, name, module_name} <- declared, plugin = plugins[name], into: %{} do
        module =
          with :active <- plugin.status,
               {:ok, module} <- Plugins.live_module(plugin, module_name) do
            module
          else
            _ -> nil
          end

        {key,
         %{
           plugin: name,
           name: module_name,
           module: module,
           status: plugin.status,
           load_id: plugin.load_id
         }}
      end

    # What is on screen needs its plugin running (again, after a reload):
    # open editor tabs, and the views of the shown containers.
    if connected?(socket) do
      shown = [
        socket.assigns[:sidebar_open] && socket.assigns[:sidebar_view],
        socket.assigns[:panel_open] && socket.assigns[:panel_view]
      ]

      on_screen =
        for(%{kind: :live, plugin: name} <- socket.assigns[:tabs] || [], do: name) ++
          for %{live: live, container: container, source: {:plugin, name}} <- Bee.Views.views(),
              live != nil and container in shown,
              do: name

      for name <- Enum.uniq(on_screen),
          match?(%{status: :inactive}, plugins[name]),
          do: Plugins.activate(name, socket.assigns.root)
    end

    assign(socket, live: live)
  end
end

defmodule Bee.Plugins.Manager do
  @moduledoc """
  Finds, registers, activates and supervises plugins. See `Bee.Plugins` for
  the public API and the plugin layout.

  Lifecycle of a plugin (`status`):

    * `:invalid` – its manifest or contributions were rejected
    * `:disabled` – listed in `plugins.disabled`
    * `:inactive` – contributions registered; its server part (if any) not running
    * `:activating` / `:active` – its `Bee.Plugins.Host` is starting / running
    * `:failed` – activation failed, or it crashed too often

  Server parts start lazily: at boot for the `*` / `onStartupFinished`
  activation events, when a file of the language of an `onLanguage:<id>`
  event is opened, and when one of the plugin's commands runs.

  A host that crashes is restarted, up to three times a minute. When a
  plugin's folder changes on disk it is reloaded (debounced).

  The plugin table lives in ETS for reads; changes broadcast
  `:plugins_changed` on the `"plugins"` topic.
  """
  use GenServer
  require Logger

  alias Bee.Contributions
  alias Bee.Plugins.Host

  @table Bee.Plugins
  @topic "plugins"
  @max_crashes 3
  @crash_window_ms 60_000
  @debounce_ms 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    # After a restart of the plugin supervisor: code of the previous hosts.
    Bee.Plugins.Loader.unload(Bee.Plugins.Loader.loaded())
    File.mkdir_p(Bee.Plugins.user_dir())
    Phoenix.PubSub.subscribe(Bee.PubSub, "fs")
    Bee.Settings.subscribe()
    Bee.Editor.Buffer.subscribe()

    {:ok, %{plugins: %{}, hosts: %{}, timers: %{}, config: config()}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, s), do: {:noreply, rescan(s)}

  @impl true
  def handle_call({:execute, name, id, ctx}, _from, s) do
    case s.plugins[name] do
      %{status: status} = plugin when status in [:inactive, :activating, :active] ->
        {s, pid} = ensure_active(s, plugin)
        Host.run_command(pid, id, ctx)
        {:reply, :ok, s}

      %{status: :failed} ->
        {:reply, {:error, "plugin #{name} failed to activate (see problems)"}, s}

      _ ->
        {:reply, {:error, "plugin #{name} is not loaded"}, s}
    end
  end

  # Something of the plugin is needed (one of its views was shown).
  def handle_call({:activate, name}, _from, s) do
    case s.plugins[name] do
      %{status: :inactive, server?: true} = plugin ->
        {:reply, :ok, elem(ensure_active(s, plugin), 0)}

      _ ->
        {:reply, :ok, s}
    end
  end

  def handle_call({:request, name, method, params, ctx, ref}, _from, s) do
    case s.plugins[name] do
      %{status: status, server?: true} = plugin
      when status in [:inactive, :activating, :active] ->
        {s, pid} = ensure_active(s, plugin)
        Host.request(pid, method, params, ctx, ref)
        {:reply, :ok, s}

      _ ->
        {:reply, {:error, "plugin #{name} has no running server part"}, s}
    end
  end

  def handle_call(:reload, _from, s) do
    s = Enum.reduce(Map.keys(s.plugins), s, &remove(&2, &1))
    {:reply, :ok, rescan(s)}
  end

  def handle_call({:reload, name}, _from, s), do: {:reply, :ok, s |> remove(name) |> rescan()}

  @impl true
  def handle_cast({:plugin_loaded, name, modules}, s),
    do: {:noreply, update_plugin(s, name, &%{&1 | modules: modules})}

  def handle_cast({:plugin_activated, name}, s),
    do: {:noreply, update_plugin(s, name, &%{&1 | status: :active})}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, s) do
    case Map.pop(s.hosts, ref) do
      {nil, _} -> {:noreply, s}
      {name, hosts} -> {:noreply, host_down(%{s | hosts: hosts}, name, reason)}
    end
  end

  def handle_info({:fs_changed, path}, s), do: {:noreply, fs_changed(s, path)}

  def handle_info({:debounced, :rescan}, s),
    do: {:noreply, rescan(%{s | timers: Map.delete(s.timers, :rescan)})}

  def handle_info({:debounced, {:reload, name}}, s) do
    s = %{s | timers: Map.delete(s.timers, {:reload, name})}
    {:noreply, s |> remove(name) |> rescan()}
  end

  def handle_info({:settings_changed, _settings, _errors}, s) do
    case config() do
      same when same == s.config -> {:noreply, s}
      config -> {:noreply, rescan(%{s | config: config})}
    end
  end

  def handle_info({:buffer_opened, path, text}, s) do
    lang = Bee.Languages.detect(path, first_line: Bee.Languages.first_line(text))
    event = "onLanguage:" <> lang

    {:noreply,
     Enum.reduce(Map.values(s.plugins), s, fn plugin, s ->
       if plugin.status == :inactive and plugin.server? and event in plugin.activation_events,
         do: elem(ensure_active(s, plugin), 0),
         else: s
     end)}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  ## Discovery

  defp config,
    do: {Bee.Settings.get("plugins.disabled"), Bee.Settings.get_user("plugins.workspace.enabled")}

  # Adds plugins found on disk that aren't loaded yet, drops vanished or
  # disabled ones. Loaded plugins are kept as they are (see reload).
  defp rescan(s) do
    found = discover()
    found_names = MapSet.new(found, & &1.name)

    s =
      Enum.reduce(Map.keys(s.plugins), s, fn name, s ->
        if MapSet.member?(found_names, name), do: s, else: remove(s, name)
      end)

    s =
      Enum.reduce(found, s, fn plugin, s ->
        case s.plugins[plugin.name] do
          nil ->
            add(s, plugin)

          # (un)disabled in settings
          loaded when loaded.status == :disabled != (plugin.status == :disabled) ->
            s |> remove(plugin.name) |> add(plugin)

          _loaded ->
            s
        end
      end)

    publish(s)
  end

  defp discover do
    {disabled, workspace?} = config()

    builtin =
      if Application.get_env(:bee, :builtin_plugins, true),
        do: [{:builtin, Bee.Plugins.builtin_dir()}],
        else: []

    dirs =
      builtin ++
        [{:user, Bee.Plugins.user_dir()}] ++
        if(workspace?, do: [{:workspace, Bee.Plugins.workspace_dir()}], else: [])

    {plugins, _seen} =
      for {scope, root} <- dirs,
          dir <-
            root |> Path.join("*/plugin.json") |> Path.wildcard() |> Enum.map(&Path.dirname/1),
          reduce: {[], %{}} do
        {acc, seen} ->
          plugin = read_plugin(scope, dir, disabled)

          case Map.fetch(seen, plugin.name) do
            {:ok, other} ->
              dup =
                invalid(plugin, "a plugin named #{plugin.name} is already loaded from #{other}")

              # Listed (with its problem) under a name of its own.
              {acc ++ [%{dup | name: plugin.name <> "@" <> dir}], seen}

            :error ->
              {acc ++ [plugin], Map.put(seen, plugin.name, dir)}
          end
      end

    plugins
  end

  defp read_plugin(scope, dir, disabled) do
    path = Path.join(dir, "plugin.json")

    base = %{
      name: Path.basename(dir),
      display_name: Path.basename(dir),
      description: nil,
      version: nil,
      scope: scope,
      dir: dir,
      # File events of a symlinked plugin (e.g. a checkout) carry the target path.
      watch_dirs: Enum.uniq([dir, resolve_link(dir)]),
      manifest_path: path,
      manifest: nil,
      status: :inactive,
      errors: [],
      server?: false,
      browser: nil,
      activation_events: [],
      modules: [],
      crashes: []
    }

    with {:ok, text} <- File.read(path),
         {:ok, %{} = manifest} <- Bee.JSON.JSONC.decode(text),
         :ok <- validate(manifest) do
      %{
        base
        | name: manifest["name"],
          display_name: manifest["displayName"] || manifest["name"],
          description: manifest["description"],
          version: manifest["version"],
          manifest: manifest,
          server?: manifest["server"] != nil,
          activation_events: Map.get(manifest, "activationEvents", []),
          status: if(manifest["name"] in disabled, do: :disabled, else: :inactive)
      }
    else
      {:ok, _} -> invalid(base, "plugin.json must contain a JSON object")
      {:error, reason} when is_binary(reason) -> invalid(base, reason)
      {:error, reason} -> invalid(base, "cannot read plugin.json: #{inspect(reason)}")
    end
  end

  defp resolve_link(dir) do
    case File.read_link(dir) do
      {:ok, target} -> Path.expand(target, Path.dirname(dir))
      {:error, _} -> dir
    end
  end

  defp validate(manifest) do
    case Bee.JSON.Schema.validate("manifest", "#", manifest) do
      :ok -> :ok
      {:error, messages} -> {:error, "invalid manifest: " <> Enum.join(messages, "; ")}
    end
  end

  defp invalid(plugin, message),
    do: %{plugin | status: :invalid, errors: plugin.errors ++ [problem(plugin, message)]}

  defp problem(plugin, %{path: path, message: message}),
    do: %{path: path, message: "#{plugin.name}: #{message}"}

  defp problem(plugin, message),
    do: problem(plugin, %{path: plugin.manifest_path, message: message})

  ## Adding and removing

  defp add(s, %{status: :inactive} = plugin) do
    plugin =
      case Contributions.register({:plugin, plugin.name}, plugin.manifest, dir: plugin.dir) do
        :ok -> %{plugin | browser: browser(plugin)}
        {:error, message} -> invalid(plugin, message)
      end

    s = put_in(s.plugins[plugin.name], plugin)

    if plugin.status == :inactive and plugin.server? and
         Enum.any?(plugin.activation_events, &(&1 in ["*", "onStartupFinished"])),
       do: elem(ensure_active(s, plugin), 0),
       else: s
  end

  defp add(s, plugin), do: put_in(s.plugins[plugin.name], plugin)

  defp remove(s, name) do
    case s.plugins[name] do
      nil ->
        s

      plugin ->
        s = stop_host(s, plugin)
        Contributions.unregister({:plugin, name})
        Bee.UI.forget(name)
        %{s | plugins: Map.delete(s.plugins, name)}
    end
  end

  defp browser(%{manifest: %{"browser" => rel}} = plugin) do
    with {:ok, path} <- Bee.Workspace.FS.resolve(plugin.dir, rel),
         {:ok, %{mtime: mtime, size: size}} <- File.stat(path) do
      # A new URL when the file changes, so the browser re-imports it.
      version = :erlang.phash2({mtime, size})
      %{path: path, url: "/plugins/#{plugin.name}/#{rel}?v=#{version}"}
    else
      _ -> nil
    end
  end

  defp browser(_plugin), do: nil

  ## Hosts

  defp ensure_active(s, %{name: name} = plugin) do
    case Host.whereis(name) do
      nil ->
        {:ok, pid} = DynamicSupervisor.start_child(Bee.Plugins.HostSup, {Host, plugin})
        ref = Process.monitor(pid)
        s = %{s | hosts: Map.put(s.hosts, ref, name)}
        {s |> update_plugin(name, &%{&1 | status: :activating}), pid}

      pid ->
        {s, pid}
    end
  end

  defp stop_host(s, plugin) do
    s =
      case Enum.find(s.hosts, fn {_ref, name} -> name == plugin.name end) do
        {ref, _} ->
          Process.demonitor(ref, [:flush])

          if pid = Host.whereis(plugin.name),
            do: DynamicSupervisor.terminate_child(Bee.Plugins.HostSup, pid)

          %{s | hosts: Map.delete(s.hosts, ref)}

        nil ->
          s
      end

    Bee.Plugins.Loader.unload(plugin.modules)
    s
  end

  defp host_down(s, name, reason) do
    host_down(s, name, reason, s.plugins[name])
  end

  defp host_down(s, _name, _reason, nil), do: s

  defp host_down(s, name, reason, plugin) do
    Bee.Plugins.Loader.unload(plugin.modules)
    plugin = %{plugin | modules: []}

    case reason do
      {:shutdown, {:activation_failed, problems}} ->
        Logger.warning("Bee: plugin #{name} failed to activate: #{inspect(problems)}")

        publish(
          put_in(s.plugins[name], %{
            plugin
            | status: :failed,
              errors: Enum.map(problems, &problem(plugin, &1))
          })
        )

      _crash ->
        now = System.monotonic_time(:millisecond)
        crashes = [now | Enum.filter(plugin.crashes, &(now - &1 < @crash_window_ms))]
        Logger.error("Bee: plugin #{name} crashed: #{Exception.format_exit(reason)}")

        if length(crashes) > @max_crashes do
          message =
            "crashed #{length(crashes)} times in a minute, last: #{Exception.format_exit(reason)}"

          publish(
            put_in(s.plugins[name], %{
              plugin
              | status: :failed,
                crashes: crashes,
                errors: [problem(plugin, message)]
            })
          )
        else
          s = put_in(s.plugins[name], %{plugin | status: :inactive, crashes: crashes})
          s |> ensure_active(s.plugins[name]) |> elem(0) |> publish()
        end
    end
  end

  defp update_plugin(s, name, fun) do
    case s.plugins[name] do
      nil -> s
      plugin -> publish(put_in(s.plugins[name], fun.(plugin)))
    end
  end

  ## File changes

  defp fs_changed(s, path) do
    in_plugin? = fn plugin ->
      Enum.any?(plugin.watch_dirs, &String.starts_with?(path, &1 <> "/"))
    end

    case Enum.find(Map.values(s.plugins), in_plugin?) do
      %{name: name} ->
        debounce(s, {:reload, name})

      nil ->
        roots = [Bee.Plugins.user_dir(), Bee.Plugins.workspace_dir()]

        if Enum.any?(roots, &String.starts_with?(path, &1 <> "/")),
          do: debounce(s, :rescan),
          else: s
    end
  end

  defp debounce(s, key) do
    if timer = s.timers[key], do: Process.cancel_timer(timer)

    %{
      s
      | timers:
          Map.put(s.timers, key, Process.send_after(self(), {:debounced, key}, @debounce_ms))
    }
  end

  ## Publishing

  defp publish(s) do
    rows = for {name, plugin} <- s.plugins, do: {name, Map.drop(plugin, [:crashes])}
    :ets.delete_all_objects(@table)
    :ets.insert(@table, rows)
    Phoenix.PubSub.broadcast(Bee.PubSub, @topic, :plugins_changed)
    s
  end
end

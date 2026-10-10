defmodule Bee.Plugins.Manager do
  @moduledoc """
  Finds, registers, activates and supervises plugins. See `Bee.Plugins` for
  the public API and the plugin layout.

  Plugins are found once for all workspaces (built-in, the user's, and the
  workspace plugins of every open workspace), and their contributions are
  registered once. Their server parts run per open workspace: a
  `Bee.Plugins.Host` per plugin and workspace it is active in, like VS
  Code's extension host per window. The manager follows the workspaces
  (`workspace_opened/2`, then a monitor): when one closes, its hosts stop.

  A plugin's `status`:

    * `:invalid` – its manifest or contributions were rejected
    * `:disabled` – listed in `plugins.disabled`
    * `:inactive` – contributions registered

  and in each workspace (`hosts`, by root) its server part's:

    * `:activating` / `:active` – its host there is starting / running
    * `:failed` – activation failed, or it crashed too often

  Server parts start lazily, per workspace: when it opens for the `*` /
  `onStartupFinished` activation events, and for `workspaceContains:<glob>`
  when it has such a file; when a file of the language of an
  `onLanguage:<id>` event is opened in it; and when one of the plugin's
  commands runs in one of its windows (`onCommand:` needs no more) or one
  of its views is shown (`onView:`). Other events are ignored.

  A host that crashes is restarted, up to three times a minute. When a
  plugin's folder changes on disk it is reloaded (debounced).

  The plugin table lives in ETS for reads; changes broadcast
  `:plugins_changed` on the `"plugins"` topic.
  """
  use GenServer
  require Logger

  alias Bee.Contributions
  alias Bee.Plugins.Host
  alias Bee.Plugins.VSCode.Manifest

  @table Bee.Plugins
  @topic "plugins"
  @max_crashes 3
  @crash_window_ms 60_000
  @debounce_ms 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Workspace `root` was opened; its process is `pid` (it closes when that exits)."
  def workspace_opened(root, pid), do: GenServer.cast(__MODULE__, {:workspace_opened, root, pid})

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    File.mkdir_p(Bee.Plugins.user_dir())
    Phoenix.PubSub.subscribe(Bee.PubSub, "fs")
    Bee.Settings.subscribe()
    Bee.Editor.Buffer.subscribe()

    s = %{plugins: %{}, hosts: %{}, roots: %{}, timers: %{}, config: config()}

    # After a restart of the plugin supervisor: the workspaces already open.
    s =
      Enum.reduce(Bee.Workspace.list(), s, fn root, s ->
        case Bee.Workspace.whereis(root) do
          nil -> s
          pid -> put_in(s.roots[root], Process.monitor(pid))
        end
      end)

    {:ok, s, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, s),
    # (rescan/1 added every plugin: add/2 looked for their workspaceContains.)
    do: {:noreply, Enum.reduce(Map.keys(s.roots), rescan(s), &start_eager(&2, &1, false))}

  @impl true
  def handle_call({:execute, name, id, ctx}, _from, s) do
    case usable(s, name, ctx.root) do
      {:ok, plugin} ->
        {s, pid} = ensure_active(s, plugin, ctx.root)
        Host.run_command(pid, id, ctx)
        {:reply, :ok, s}

      error ->
        {:reply, error, s}
    end
  end

  # Something of the plugin is needed in workspace `root` (one of its views was shown).
  def handle_call({:activate, name, root}, _from, s) do
    case usable(s, name, root) do
      {:ok, %{server?: true} = plugin} -> {:reply, :ok, elem(ensure_active(s, plugin, root), 0)}
      _ -> {:reply, :ok, s}
    end
  end

  def handle_call({:request, name, method, params, ctx, ref}, _from, s) do
    case usable(s, name, ctx.root) do
      {:ok, %{server?: true} = plugin} ->
        {s, pid} = ensure_active(s, plugin, ctx.root)
        Host.request(pid, method, params, ctx, ref)
        {:reply, :ok, s}

      {:ok, _no_server} ->
        {:reply, {:error, "plugin #{name} has no server part"}, s}

      error ->
        {:reply, error, s}
    end
  end

  def handle_call(:reload, _from, s) do
    s = Enum.reduce(Map.keys(s.plugins), s, &remove(&2, &1))
    {:reply, :ok, rescan(s)}
  end

  def handle_call({:reload, name}, _from, s), do: {:reply, :ok, s |> remove(name) |> rescan()}

  @impl true
  def handle_cast({:plugin_activated, name, root}, s),
    do: {:noreply, update_host(s, name, root, &%{&1 | status: :active})}

  def handle_cast({:workspace_opened, root, pid}, s) do
    if Map.has_key?(s.roots, root) do
      {:noreply, s}
    else
      s = put_in(s.roots[root], Process.monitor(pid))
      # Its workspace plugins, then what starts with it.
      {:noreply, s |> rescan() |> start_eager(root)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    case Map.pop(s.hosts, ref) do
      {{name, root}, hosts} ->
        # Its code is unloaded (if it was the last) before anyone hears of it.
        Bee.Plugins.Modules.release(pid)
        {:noreply, host_down(%{s | hosts: hosts}, name, root, reason)}

      {nil, _} ->
        case Enum.find(s.roots, fn {_root, r} -> r == ref end) do
          {root, _} -> {:noreply, workspace_closed(s, root)}
          nil -> {:noreply, s}
        end
    end
  end

  def handle_info({:fs_changed, path}, s), do: {:noreply, fs_changed(s, path)}

  def handle_info({:debounced, :rescan}, s),
    do: {:noreply, rescan(%{s | timers: Map.delete(s.timers, :rescan)})}

  def handle_info({:debounced, {:reload, name}}, s) do
    s = %{s | timers: Map.delete(s.timers, {:reload, name})}
    {:noreply, s |> remove(name) |> rescan()}
  end

  def handle_info({:settings_changed, _scope}, s) do
    case config() do
      same when same == s.config -> {:noreply, s}
      config -> {:noreply, rescan(%{s | config: config})}
    end
  end

  # onLanguage activation, in the workspaces the file is in.
  def handle_info({:buffer_opened, path, text}, s) do
    lang = Bee.Languages.detect(path, first_line: Bee.Languages.first_line(text))
    event = "onLanguage:" <> lang

    {:noreply,
     for root <- Map.keys(s.roots),
         inside?(path, root),
         plugin <- Map.values(s.plugins),
         event in plugin.activation_events,
         reduce: s do
       s -> start_in(s, plugin.name, root)
     end}
  end

  # workspaceContains activation: the plugins whose files `root` has.
  def handle_info({:workspace_contains, root, names}, s) do
    {:noreply,
     if(Map.has_key?(s.roots, root),
       do: Enum.reduce(names, s, &start_in(&2, &1, root)),
       else: s
     )}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  ## Discovery

  defp config,
    do:
      {Bee.Settings.get_user("plugins.disabled"),
       Bee.Settings.get_user("plugins.workspace.enabled")}

  # Adds plugins found on disk that aren't loaded yet, drops vanished or
  # disabled ones. Loaded plugins are kept as they are (see reload).
  defp rescan(s) do
    found = discover(s)
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

  defp discover(s) do
    {disabled, workspace?} = config()

    builtin =
      if Application.get_env(:bee, :builtin_plugins, true),
        do: [{:builtin, nil, Bee.Plugins.builtin_dir()}],
        else: []

    workspaces =
      if workspace?,
        do:
          for(
            root <- Enum.sort(Map.keys(s.roots)),
            do: {:workspace, root, Bee.Plugins.workspace_dir(root)}
          ),
        else: []

    dirs = builtin ++ [{:user, nil, Bee.Plugins.user_dir()}] ++ workspaces

    {plugins, _seen} =
      for {scope, workspace, base} <- dirs,
          dir <- plugin_dirs(base),
          reduce: {[], %{}} do
        {acc, seen} ->
          plugin = read_plugin(scope, workspace, dir, disabled)

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

  # The folders in `base` that are plugins: with a plugin.json, or a VS
  # Code extension installed from a VSIX (read from its package.json).
  defp plugin_dirs(base) do
    case File.ls(base) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            not String.starts_with?(name, "."),
            dir = Path.join(base, name),
            File.exists?(Path.join(dir, "plugin.json")) or Manifest.extension?(dir),
            do: dir

      {:error, _} ->
        []
    end
  end

  defp read_plugin(scope, workspace, dir, disabled) do
    kind = if Manifest.extension?(dir), do: :vscode, else: :bee

    path =
      case kind do
        :vscode -> Manifest.package_path(dir)
        :bee -> Path.join(dir, "plugin.json")
      end

    base = %{
      name: Path.basename(dir),
      display_name: Path.basename(dir),
      description: nil,
      version: nil,
      scope: scope,
      # :bee (a plugin.json) or :vscode (an extension's package.json).
      kind: kind,
      # A workspace plugin's workspace: it only runs there.
      workspace: workspace,
      dir: dir,
      # File events of a symlinked plugin (e.g. a checkout) carry the target path.
      watch_dirs: Enum.uniq([dir, resolve_link(dir)]),
      manifest_path: path,
      manifest: nil,
      status: :inactive,
      errors: [],
      # What Bee left out of a VS Code extension, and why.
      warnings: [],
      server?: false,
      browser: nil,
      activation_events: [],
      # Its server part in each workspace: %{root => %{status, errors, crashes}}.
      hosts: %{},
      # This load of it, for Bee.Plugins.Modules.
      load_id: System.unique_integer([:positive])
    }

    with {:ok, manifest, warnings} <- read_manifest(kind, dir, path),
         :ok <- validate(manifest) do
      %{
        base
        | name: manifest["name"],
          warnings: warnings,
          display_name: manifest["displayName"] || manifest["name"],
          description: manifest["description"],
          version: manifest["version"],
          manifest: manifest,
          server?: manifest["server"] != nil,
          activation_events: Map.get(manifest, "activationEvents", []),
          status: if(manifest["name"] in disabled, do: :disabled, else: :inactive)
      }
    else
      {:error, reason} -> invalid(base, reason)
    end
  end

  defp read_manifest(:vscode, dir, _path), do: Manifest.read(dir)

  defp read_manifest(:bee, _dir, path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = manifest} <- Bee.JSON.JSONC.decode(text) do
      {:ok, manifest, []}
    else
      {:ok, _} -> {:error, "plugin.json must contain a JSON object"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "cannot read plugin.json: #{inspect(reason)}"}
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
    Enum.each(Map.keys(s.roots), &check_workspace_contains([plugin], &1))

    if eager?(plugin),
      do: Enum.reduce(Map.keys(s.roots), s, &start_in(&2, plugin.name, &1)),
      else: s
  end

  defp add(s, plugin), do: put_in(s.plugins[plugin.name], plugin)

  defp remove(s, name) do
    case s.plugins[name] do
      nil ->
        s

      plugin ->
        s = stop_hosts(s, name, Map.keys(plugin.hosts))
        Bee.Plugins.Modules.drop(name)
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

  ## Workspaces

  # Plugins that start with a workspace.
  defp eager?(plugin),
    do: Enum.any?(plugin.activation_events, &(&1 in ["*", "onStartupFinished"]))

  defp start_eager(s, root, check_files? \\ true) do
    if check_files?, do: check_workspace_contains(Map.values(s.plugins), root)

    for {name, plugin} <- s.plugins, eager?(plugin), reduce: s do
      s -> start_in(s, name, root)
    end
  end

  # Looking through a workspace's files can take a while: in a task, which
  # tells us the plugins to start there.
  defp check_workspace_contains(plugins, root) do
    wanted =
      for %{status: :inactive, name: name} = plugin <- plugins,
          globs = for("workspaceContains:" <> glob <- plugin.activation_events, do: glob),
          globs != [],
          do: {name, globs}

    manager = self()

    if wanted != [] do
      Task.Supervisor.start_child(Bee.Plugins.TaskSup, fn ->
        send(manager, {:workspace_contains, root, workspace_contains(root, wanted)})
      end)
    end
  end

  @doc false
  # The names in `wanted` (`[{name, globs}]`) one of whose globs matches a
  # file of `root`: a plain path is looked up, a pattern matched against
  # every file (without `files.exclude`d ones).
  def workspace_contains(root, wanted) do
    {plain, patterns} =
      wanted
      |> Enum.flat_map(fn {name, globs} -> Enum.map(globs, &{name, &1}) end)
      |> Enum.split_with(fn {_name, glob} -> not String.contains?(glob, ["*", "?", "{", "["]) end)

    found =
      for {name, path} <- plain,
          match?({:ok, _}, Bee.Workspace.FS.resolve(root, path)),
          File.exists?(Path.join(root, path)),
          into: MapSet.new(),
          do: name

    patterns =
      for {name, glob} <- patterns,
          name not in found,
          do: {name, Bee.Workspace.Glob.compile(glob)}

    found =
      if patterns == [] do
        found
      else
        Enum.reduce(Bee.Workspace.files(root), found, fn file, found ->
          for {name, regex} <- patterns,
              name not in found,
              Bee.Workspace.Glob.match?(regex, file),
              into: found,
              do: name
        end)
      end

    MapSet.to_list(found)
  rescue
    # A glob Bee can't read.
    _ -> []
  end

  defp workspace_closed(s, root) do
    s =
      for {name, plugin} <- s.plugins, Map.has_key?(plugin.hosts, root), reduce: s do
        s -> stop_hosts(s, name, [root])
      end

    Bee.UI.forget_workspace(root)
    # Without its workspace plugins.
    rescan(%{s | roots: Map.delete(s.roots, root)})
  end

  ## Hosts

  # Plugin `name`, if it can run in workspace `root`: `{:ok, plugin}` or `{:error, message}`.
  defp usable(s, name, root) do
    plugin = s.plugins[name]

    cond do
      plugin == nil or plugin.status != :inactive ->
        {:error, "plugin #{name} is not loaded"}

      not Map.has_key?(s.roots, root) or plugin.workspace not in [nil, root] ->
        {:error, "plugin #{name} is not loaded in #{root}"}

      match?(%{status: :failed}, plugin.hosts[root]) ->
        {:error, "plugin #{name} failed to activate (see problems)"}

      true ->
        {:ok, plugin}
    end
  end

  # Starts plugin `name`'s server part in workspace `root`, if it has one and may.
  defp start_in(s, name, root) do
    case usable(s, name, root) do
      {:ok, %{server?: true} = plugin} -> elem(ensure_active(s, plugin, root), 0)
      _ -> s
    end
  end

  defp ensure_active(s, %{name: name} = plugin, root) do
    case Host.whereis(name, root) do
      nil ->
        {:ok, pid} =
          DynamicSupervisor.start_child(Bee.Plugins.HostSup, {Host, {plugin, root}})

        ref = Process.monitor(pid)
        s = %{s | hosts: Map.put(s.hosts, ref, {name, root})}
        crashes = get_in(plugin.hosts, [root, :crashes]) || []

        s =
          update_plugin(
            s,
            name,
            &put_in(&1.hosts[root], %{status: :activating, errors: [], crashes: crashes})
          )

        {s, pid}

      pid ->
        {s, pid}
    end
  end

  defp stop_hosts(s, name, roots) do
    s =
      Enum.reduce(s.hosts, s, fn
        {ref, {^name, root}}, s ->
          if root in roots do
            Process.demonitor(ref, [:flush])

            if pid = Host.whereis(name, root),
              do: DynamicSupervisor.terminate_child(Bee.Plugins.HostSup, pid)

            %{s | hosts: Map.delete(s.hosts, ref)}
          else
            s
          end

        _other, s ->
          s
      end)

    update_plugin(s, name, &%{&1 | hosts: Map.drop(&1.hosts, roots)})
  end

  defp host_down(s, name, root, reason) do
    case s.plugins[name] do
      nil -> s
      plugin -> host_down(s, plugin, root, reason, plugin.hosts[root] || %{crashes: []})
    end
  end

  defp host_down(s, plugin, root, reason, host) do
    name = plugin.name

    case reason do
      {:shutdown, {:activation_failed, problems}} ->
        Logger.warning("Bee: plugin #{name} failed to activate: #{inspect(problems)}")

        update_host(s, name, root, fn _ ->
          %{status: :failed, errors: Enum.map(problems, &problem(plugin, &1)), crashes: []}
        end)

      _crash ->
        now = System.monotonic_time(:millisecond)
        crashes = [now | Enum.filter(host.crashes, &(now - &1 < @crash_window_ms))]
        Logger.error("Bee: plugin #{name} crashed in #{root}: #{Exception.format_exit(reason)}")

        if length(crashes) > @max_crashes do
          message =
            "crashed #{length(crashes)} times in a minute, last: #{Exception.format_exit(reason)}"

          update_host(s, name, root, fn _ ->
            %{status: :failed, errors: [problem(plugin, message)], crashes: crashes}
          end)
        else
          s =
            update_host(s, name, root, fn _ ->
              %{status: :inactive, errors: [], crashes: crashes}
            end)

          if Map.has_key?(s.roots, root), do: start_in(s, name, root), else: s
        end
    end
  end

  defp update_plugin(s, name, fun) do
    case s.plugins[name] do
      nil -> s
      plugin -> publish(put_in(s.plugins[name], fun.(plugin)))
    end
  end

  defp update_host(s, name, root, fun) do
    update_plugin(s, name, fn plugin ->
      case plugin.hosts[root] do
        nil -> plugin
        host -> put_in(plugin.hosts[root], fun.(host))
      end
    end)
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
        dirs = [
          Bee.Plugins.user_dir() | Enum.map(Map.keys(s.roots), &Bee.Plugins.workspace_dir/1)
        ]

        if Enum.any?(dirs, &String.starts_with?(path, &1 <> "/")),
          do: debounce(s, :rescan),
          else: s
    end
  end

  defp inside?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

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
    rows = Map.to_list(s.plugins)
    :ets.delete_all_objects(@table)
    :ets.insert(@table, rows)
    Phoenix.PubSub.broadcast(Bee.PubSub, @topic, :plugins_changed)
    s
  end
end

defmodule Bee.Plugins.Host do
  @moduledoc """
  Runs the server part of one plugin for one workspace, like VS Code's
  extension host per window: one process per plugin and open workspace it
  is active in, under `Bee.Plugins.HostSup`, registered as
  `{:plugin, name, root}` in `Bee.Registry`. Its contexts' `root` is that
  workspace, and it only gets events of that workspace: buffers and file
  changes under its root (and in the config folder), its settings.

  Activation happens in `handle_continue/2`, so starting a host never blocks
  the caller: it gets the plugin's code (`Bee.Plugins.Modules`, loaded once
  for all its hosts), checks that its manifest's server commands and its
  `@command` handlers match, then calls `activate/1`. Commands sent
  meanwhile wait in the mailbox. On failure the host stops with
  `{:shutdown, {:activation_failed, problems}}`.

  Callbacks run one at a time, each in a task with a timeout: a slow or
  crashing command is reported to the user and leaves the plugin running
  with its previous state. Only a crash of the host itself (e.g. a bad
  return value) restarts the plugin – `Bee.Plugins.Manager` decides.

  The manager is told `{:plugin_activated, name, root}`.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Bee.Plugins.{Context, Modules}

  # How long a callback may run (app env :plugin_timeout, milliseconds).
  defp timeout, do: Application.get_env(:bee, :plugin_timeout, 10_000)

  def start_link({plugin, root}),
    do: GenServer.start_link(__MODULE__, {plugin, root}, name: via(plugin.name, root))

  def whereis(name, root) do
    case Registry.lookup(Bee.Registry, {:plugin, name, root}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Runs command `id` with `ctx` (a `Bee.Plugins.Context`) – asynchronously."
  def run_command(pid, id, %Context{} = ctx), do: GenServer.cast(pid, {:command, id, ctx})

  @doc "Calls `handle_request/4`; the result goes to `ctx.window` (see `Bee.Plugins.request/5`)."
  def request(pid, method, params, %Context{} = ctx, ref),
    do: GenServer.cast(pid, {:request, method, params, ctx, ref})

  defp via(name, root), do: {:via, Registry, {Bee.Registry, {:plugin, name, root}}}

  ## Server

  @impl true
  def init({plugin, root}) do
    # So terminate/2 (deactivate) runs when the supervisor stops us.
    Process.flag(:trap_exit, true)
    Logger.metadata(plugin: plugin.name, workspace: root)
    # Bee.API's workspace, for this process (tasks get it in run/2).
    Process.put(:bee_workspace, root)

    {:ok, %{plugin: plugin, root: root, module: nil, handlers: %{}, state: nil, active?: false},
     {:continue, :activate}}
  end

  @impl true
  def handle_continue(:activate, %{plugin: plugin} = s) do
    with {:ok, module} <- load(plugin),
         handlers = Bee.Plugin.commands(module),
         :ok <- check_handlers(plugin, handlers),
         s = %{s | module: module, handlers: handlers},
         {:ok, state} <- activate(s) do
      if function_exported?(module, :handle_event, 2) do
        Bee.Editor.Buffer.subscribe()
        Bee.Settings.subscribe()
        Bee.Workspace.subscribe()
      end

      notify({:plugin_activated, plugin.name, s.root})
      {:noreply, %{s | state: state, active?: true}}
    else
      {:error, problems} -> {:stop, {:shutdown, {:activation_failed, problems}}, s}
    end
  end

  @impl true
  def handle_cast({:command, id, ctx}, s) do
    ctx = %{ctx | plugin: s.plugin.name, dir: s.plugin.dir, host: self(), root: s.root}

    case s.handlers do
      %{^id => fun} ->
        {:noreply, call(s, ctx, "command #{id}", fn -> apply(s.module, fun, [ctx, s.state]) end)}

      _ ->
        Bee.API.show_message(ctx, :error, "#{s.plugin.name} has no handler for #{id}")
        {:noreply, s}
    end
  end

  def handle_cast({:request, method, params, ctx, ref}, s) do
    ctx = %{ctx | plugin: s.plugin.name, dir: s.plugin.dir, host: self(), root: s.root}

    {reply, s} =
      if function_exported?(s.module, :handle_request, 4) do
        case run(fn -> s.module.handle_request(method, params, ctx, s.state) end) do
          {:ok, {:reply, result}} -> {{:ok, result}, s}
          {:ok, {:reply, result, state}} -> {{:ok, result}, %{s | state: state}}
          {:ok, {:error, message}} -> {{:error, to_string(message)}, s}
          {:ok, other} -> {{:error, "handle_request/4 returned #{inspect(other)}"}, s}
          {:error, message} -> {{:error, "handle_request/4 #{message}"}, s}
        end
      else
        {{:error, "#{s.plugin.name} has no handle_request/4"}, s}
      end

    Bee.API.reply(ctx, ref, reply)
    {:noreply, s}
  end

  @impl true
  # Linked helpers finishing (Kernel.ParallelCompiler's workers do); the
  # supervisor's exit is handled by GenServer itself.
  def handle_info({:EXIT, _pid, :normal}, s), do: {:noreply, s}
  def handle_info({:EXIT, _pid, reason}, s), do: {:stop, reason, s}

  def handle_info(msg, s) do
    case event(msg, s.root) do
      nil -> {:noreply, maybe_handle_info(msg, s)}
      :ignore -> {:noreply, s}
      event -> {:noreply, callback(s, :handle_event, [event, s.state])}
    end
  end

  @impl true
  def terminate(_reason, %{active?: true, module: module} = s) do
    if function_exported?(module, :deactivate, 1),
      do: run(fn -> module.deactivate(s.state) end)
  end

  def terminate(_reason, _s), do: :ok

  ## Activation

  defp activate(%{module: module} = s) do
    if function_exported?(module, :activate, 1) do
      ctx = base_context(s)

      case run(fn -> module.activate(ctx) end) do
        {:ok, {:ok, state}} -> {:ok, state}
        {:ok, {:error, reason}} -> {:error, [problem(s, "activate/1 failed: #{inspect(reason)}")]}
        {:ok, other} -> {:error, [problem(s, "activate/1 returned #{inspect(other)}")]}
        {:error, message} -> {:error, [problem(s, "activate/1 #{message}")]}
      end
    else
      {:ok, nil}
    end
  end

  # Built-in plugins are compiled with Bee: nothing to load (or unload).
  defp load(%{scope: :builtin} = plugin) do
    module = Module.concat([plugin.manifest["server"]["module"]])

    case Code.ensure_loaded(module) do
      {:module, module} -> {:ok, module}
      {:error, reason} -> {:error, [problem(%{plugin: plugin}, "#{inspect(module)}: #{reason}")]}
    end
  end

  defp load(plugin) do
    with {:ok, module, _modules} <- Modules.ensure(plugin), do: {:ok, module}
  end

  defp check_handlers(plugin, handlers) do
    declared =
      for %{"runtime" => "server", "command" => id} <-
            get_in(plugin.manifest, ["contributes", "commands"]) || [],
          do: id

    problems =
      Enum.map(declared -- Map.keys(handlers), &"no @command handler for #{inspect(&1)}") ++
        Enum.map(Map.keys(handlers) -- declared, &"handler for undeclared command #{inspect(&1)}")

    case problems do
      [] -> :ok
      _ -> {:error, Enum.map(problems, &%{path: plugin.manifest_path, message: &1})}
    end
  end

  defp base_context(s),
    do: %Context{
      plugin: s.plugin.name,
      dir: s.plugin.dir,
      host: self(),
      root: s.root
    }

  ## Events

  # Only the workspace's: its buffers and files (and the config folder's),
  # its settings.
  defp event({:buffer_opened, path, _text}, root), do: mine(path, root, {:buffer_opened, path})

  defp event({:buffer_changed, path, version, _text}, root),
    do: mine(path, root, {:buffer_changed, path, version})

  defp event({:buffer_saved, path, _text}, root), do: mine(path, root, {:buffer_saved, path})
  defp event({:buffer_closed, path}, root), do: mine(path, root, {:buffer_closed, path})

  defp event({:buffer_reloaded, path, _text}, root),
    do: mine(path, root, {:buffer_changed, path, nil})

  defp event({:buffer_edited, _path, _version, _edits, _text}, _root), do: :ignore

  defp event({:settings_changed, scope}, root) when scope in [:user, {:workspace, root}],
    do: {:settings_changed, Bee.Settings.all(root)}

  defp event({:settings_changed, _other}, _root), do: :ignore

  defp event({:fs_changed, path}, root) do
    if inside?(path, Bee.Settings.user_dir()),
      do: {:fs_changed, path},
      else: mine(path, root, {:fs_changed, path})
  end

  defp event(_, _root), do: nil

  defp mine(path, root, event), do: if(inside?(path, root), do: event, else: :ignore)

  defp inside?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp maybe_handle_info(msg, s) do
    if function_exported?(s.module, :handle_info, 2),
      do: callback(s, :handle_info, [msg, s.state]),
      else: s
  end

  ## Running plugin code

  defp callback(s, fun, args) do
    call(s, base_context(s), "#{fun}/#{length(args)}", fn -> apply(s.module, fun, args) end)
  end

  # Runs plugin code, applies its result to the state, reports failures.
  defp call(s, ctx, what, fun) do
    case run(fun) do
      {:ok, :ok} ->
        s

      {:ok, {:ok, state}} ->
        %{s | state: state}

      {:ok, other} ->
        report(ctx, s, "#{what} returned #{inspect(other)}, expected :ok or {:ok, state}")

      {:error, message} ->
        report(ctx, s, "#{what} #{message}")
    end
  end

  defp report(ctx, s, message) do
    Logger.warning("Bee plugin #{s.plugin.name}: #{message}")
    Bee.API.show_message(ctx, :error, "#{s.plugin.name}: #{message}")
    s
  end

  # In a task, so a crash or a hang doesn't take the plugin down.
  defp run(fun) do
    root = Process.get(:bee_workspace)

    task =
      Task.Supervisor.async_nolink(Bee.Plugins.TaskSup, fn ->
        Process.put(:bee_workspace, root)
        fun.()
      end)

    case Task.yield(task, timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:ok, result}

      {:exit, {exception, stack}} when is_exception(exception) ->
        {:error, "raised " <> Exception.format_banner(:error, exception, stack)}

      {:exit, reason} ->
        {:error, "exited: #{Exception.format_exit(reason)}"}

      nil ->
        {:error, "timed out after #{timeout()}ms"}
    end
  end

  defp problem(s, message), do: %{path: s.plugin.manifest_path, message: message}

  defp notify(msg) do
    GenServer.cast(Bee.Plugins.Manager, msg)
    :ok
  end
end

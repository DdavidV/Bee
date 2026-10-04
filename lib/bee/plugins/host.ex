defmodule Bee.Plugins.Host do
  @moduledoc """
  Runs the server part of one plugin: one process per active plugin, under
  `Bee.Plugins.HostSup`, registered as `{:plugin, name}` in `Bee.Registry`.

  Activation happens in `handle_continue/2`, so starting a host never blocks
  the caller: it compiles and loads the plugin's code (`Bee.Plugins.Loader`),
  checks that its manifest's server commands and its `@command` handlers
  match, then calls `activate/1`. Commands sent meanwhile wait in the mailbox.
  On failure the host stops with `{:shutdown, {:activation_failed, problems}}`.

  Callbacks run one at a time, each in a task with a timeout: a slow or
  crashing command is reported to the user and leaves the plugin running
  with its previous state. Only a crash of the host itself (e.g. a bad
  return value) restarts the plugin – `Bee.Plugins.Manager` decides.

  The manager is told `{:plugin_loaded, name, modules}` (it unloads them
  when the host is gone) and `{:plugin_activated, name}`.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Bee.Plugins.{Context, Loader}

  # How long a callback may run (app env :plugin_timeout, milliseconds).
  defp timeout, do: Application.get_env(:bee, :plugin_timeout, 10_000)

  def start_link(plugin), do: GenServer.start_link(__MODULE__, plugin, name: via(plugin.name))

  def whereis(name) do
    case Registry.lookup(Bee.Registry, {:plugin, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Runs command `id` with `ctx` (a `Bee.Plugins.Context`) – asynchronously."
  def run_command(pid, id, %Context{} = ctx), do: GenServer.cast(pid, {:command, id, ctx})

  defp via(name), do: {:via, Registry, {Bee.Registry, {:plugin, name}}}

  ## Server

  @impl true
  def init(plugin) do
    # So terminate/2 (deactivate) runs when the supervisor stops us.
    Process.flag(:trap_exit, true)
    Logger.metadata(plugin: plugin.name)

    {:ok, %{plugin: plugin, module: nil, handlers: %{}, state: nil, active?: false},
     {:continue, :activate}}
  end

  @impl true
  def handle_continue(:activate, %{plugin: plugin} = s) do
    with {:ok, module, modules} <- Loader.load(plugin.dir, plugin.manifest["server"]),
         :ok <- notify({:plugin_loaded, plugin.name, modules}),
         handlers = Bee.Plugin.commands(module),
         :ok <- check_handlers(plugin, handlers),
         s = %{s | module: module, handlers: handlers},
         {:ok, state} <- activate(s) do
      if function_exported?(module, :handle_event, 2) do
        Bee.Editor.Buffer.subscribe()
        Bee.Settings.subscribe()
      end

      notify({:plugin_activated, plugin.name})
      {:noreply, %{s | state: state, active?: true}}
    else
      {:error, problems} -> {:stop, {:shutdown, {:activation_failed, problems}}, s}
    end
  end

  @impl true
  def handle_cast({:command, id, ctx}, s) do
    ctx = %{ctx | plugin: s.plugin.name, dir: s.plugin.dir, host: self()}

    case s.handlers do
      %{^id => fun} ->
        {:noreply, call(s, ctx, "command #{id}", fn -> apply(s.module, fun, [ctx, s.state]) end)}

      _ ->
        Bee.API.show_message(ctx, :error, "#{s.plugin.name} has no handler for #{id}")
        {:noreply, s}
    end
  end

  @impl true
  # Linked helpers finishing (Kernel.ParallelCompiler's workers do); the
  # supervisor's exit is handled by GenServer itself.
  def handle_info({:EXIT, _pid, :normal}, s), do: {:noreply, s}
  def handle_info({:EXIT, _pid, reason}, s), do: {:stop, reason, s}

  def handle_info(msg, s) do
    case event(msg) do
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
      root: Bee.Workspace.root()
    }

  ## Events

  defp event({:buffer_opened, path, _text}), do: {:buffer_opened, path}
  defp event({:buffer_changed, path, version, _text}), do: {:buffer_changed, path, version}
  defp event({:buffer_saved, path, _text}), do: {:buffer_saved, path}
  defp event({:buffer_closed, path}), do: {:buffer_closed, path}
  defp event({:buffer_reloaded, path, _text}), do: {:buffer_changed, path, nil}
  defp event({:buffer_edited, _path, _version, _edits, _text}), do: :ignore
  defp event({:settings_changed, settings, _errors}), do: {:settings_changed, settings}
  defp event(_), do: nil

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
    task = Task.Supervisor.async_nolink(Bee.Plugins.TaskSup, fun)

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

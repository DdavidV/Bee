defmodule Bee.Terminal do
  @moduledoc """
  One process per terminal tab: a shell running in a pty via erlexec.

  Output is broadcast on `"term:<id>"` as `{:term_data, id, seq, data}` and
  kept in a bounded scrollback, so a viewer that attaches late can replay it
  and then skip chunks with `seq <= last_seq`. Output that comes in a burst
  (a build, `cat`) is sent on at most every few milliseconds, in one piece:
  what is typed is echoed at once, and a flood costs the window one message
  per frame instead of thousands. The terminal exits with its
  owner (the LiveView that opened it), and broadcasts `{:term_exit, id, reason}`
  when the shell exits.
  """
  use GenServer, restart: :temporary

  @scrollback_bytes 256 * 1024
  # How long output is gathered after some was sent.
  @flush_ms 8

  def start(opts) do
    DynamicSupervisor.start_child(Bee.TerminalSup, {__MODULE__, opts})
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))

  def topic(id), do: "term:#{id}"

  @doc "The shell new terminals run (`terminal.integrated.shell` of workspace `root`)."
  def default_shell(root \\ nil), do: Bee.Settings.get("terminal.integrated.shell", root)

  def input(id, data), do: GenServer.cast(via(id), {:input, data})
  def resize(id, cols, rows), do: GenServer.cast(via(id), {:resize, cols, rows})

  @doc "Returns `{scrollback, last_seq}`."
  def scrollback(id), do: GenServer.call(via(id), :scrollback)

  def stop(id) do
    case Registry.lookup(Bee.Registry, {:terminal, id}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  catch
    # Already stopping on its own (shell exited or owner died).
    :exit, _ -> :ok
  end

  defp via(id), do: {:via, Registry, {Bee.Registry, {:terminal, id}}}

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    owner = Keyword.fetch!(opts, :owner)
    shell = Keyword.get_lazy(opts, :shell, &default_shell/0)
    cwd = Keyword.get_lazy(opts, :cwd, &Bee.Workspace.root/0)
    {cols, rows} = {Keyword.get(opts, :cols, 80), Keyword.get(opts, :rows, 24)}

    # Turns the shell's exit into a message (see :link below) and makes
    # terminate/2 run on supervisor shutdown.
    Process.flag(:trap_exit, true)

    exec_opts = [
      :stdin,
      :stdout,
      :stderr,
      :pty,
      # erlexec disables echo by default; shells (readline) then don't show typed input.
      :pty_echo,
      # Linked both ways: we get {:EXIT, exec_pid, reason} when the shell exits,
      # and erlexec kills the shell if this process dies, even by crash.
      :link,
      {:winsz, {rows, cols}},
      # Hang up like a closed terminal window would (interactive shells ignore
      # erlexec's default SIGTERM); SIGKILL follows after 1s. erlexec also uses
      # this when this process dies without running terminate/2.
      {:kill, ~c"kill -HUP $CHILD_PID"},
      {:kill_timeout, 1},
      {:cd, String.to_charlist(cwd)},
      {:env, [{~c"TERM", ~c"xterm-256color"}, {~c"COLORTERM", ~c"truecolor"}]}
    ]

    case :exec.run(String.to_charlist(shell), exec_opts) do
      {:ok, exec_pid, os_pid} ->
        Process.monitor(owner)

        {:ok,
         %{
           id: id,
           owner: owner,
           exec_pid: exec_pid,
           os_pid: os_pid,
           seq: 0,
           scrollback: <<>>,
           # Output not sent yet (iodata), while `timer` runs.
           pending: [],
           timer: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:scrollback, _from, state) do
    # (What waits is sent first: the scrollback is what `seq` has seen.)
    state = flush(state)
    {:reply, {state.scrollback, state.seq}, state}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    :exec.send(state.os_pid, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    :exec.winsz(state.os_pid, rows, cols)
    {:noreply, state}
  end

  @impl true
  def handle_info({stream, os_pid, data}, %{os_pid: os_pid} = state)
      when stream in [:stdout, :stderr] do
    state = %{state | pending: [state.pending | data]}

    # The first of a burst goes at once; what follows shortly, together.
    if state.timer,
      do: {:noreply, state},
      else: {:noreply, %{flush(state) | timer: Process.send_after(self(), :flush, @flush_ms)}}
  end

  def handle_info(:flush, state) do
    if state.pending == [],
      do: {:noreply, %{state | timer: nil}},
      else: {:noreply, %{flush(state) | timer: Process.send_after(self(), :flush, @flush_ms)}}
  end

  # The shell exited: reason is :normal or {:exit_status, status}.
  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    state = flush(state)
    Phoenix.PubSub.broadcast(Bee.PubSub, topic(state.id), {:term_exit, state.id, reason})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    :exec.stop(state.os_pid)
  end

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    data = IO.iodata_to_binary(state.pending)
    seq = state.seq + 1
    Phoenix.PubSub.broadcast(Bee.PubSub, topic(state.id), {:term_data, state.id, seq, data})
    %{state | seq: seq, pending: [], scrollback: trim(state.scrollback <> data)}
  end

  defp trim(buf) when byte_size(buf) > @scrollback_bytes,
    do: binary_part(buf, byte_size(buf) - @scrollback_bytes, @scrollback_bytes)

  defp trim(buf), do: buf
end

defmodule Desktop.StdoutGuard do
  @moduledoc """
  In desktop mode stdout carries the bridge's frames, so nothing else may
  write to it: `IO.puts/1`, `IO.inspect/1` or a plugin's `:io.format/2`
  would corrupt the stream. This process takes over as the terminal (the
  `:user` I/O device, and the group leader of every process using it, which
  new processes inherit) and passes output on to stderr. Reading input gets
  an error: stdin is the bridge's too.
  """

  @doc "Installs the guard. Returns its pid."
  def install do
    old_user = Process.whereis(:user)
    guard = spawn(&loop/0)

    for pid <- Process.list(),
        Process.info(pid, :group_leader) == {:group_leader, old_user},
        do: :erlang.group_leader(guard, pid)

    if old_user, do: Process.unregister(:user)
    Process.register(guard, :user)
    guard
  end

  defp loop do
    receive do
      {:io_request, from, reply_as, request} ->
        # stderr's own I/O server answers `from` directly.
        case Process.whereis(:standard_error) do
          nil -> send(from, {:io_reply, reply_as, {:error, :enodev}})
          stderr -> send(stderr, {:io_request, from, reply_as, request})
        end

      _other ->
        :ok
    end

    loop()
  end
end

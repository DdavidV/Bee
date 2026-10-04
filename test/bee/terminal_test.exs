defmodule Bee.TerminalTest do
  use ExUnit.Case, async: true

  alias Bee.Terminal

  setup do
    dir = Path.join(System.tmp_dir!(), "bee_terminal_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "runs commands in the given directory", %{dir: dir} do
    id = start_terminal(dir)

    Terminal.input(id, "echo bee-$((40 + 2)); pwd\n")
    output = await_output(id, ~r/bee-42.*#{Regex.escape(dir)}/s)
    assert output =~ "bee-42"
  end

  test "echoes typed input", %{dir: dir} do
    id = start_terminal(dir)

    Terminal.input(id, "typed-but-not-run")
    assert await_output(id, ~r/typed-but-not-run/) =~ "typed-but-not-run"
  end

  test "resize changes the pty window size", %{dir: dir} do
    id = start_terminal(dir)

    Terminal.resize(id, 100, 30)
    Terminal.input(id, "stty size\n")
    assert await_output(id, ~r/30 100/) =~ "30 100"
  end

  test "scrollback replays output with the last sequence number", %{dir: dir} do
    id = start_terminal(dir)
    Terminal.input(id, "echo replay-me\n")
    await_output(id, ~r/replay-me\r?\n/)

    {scrollback, seq} = Terminal.scrollback(id)
    assert scrollback =~ "replay-me"
    assert seq > 0
  end

  test "exiting the shell broadcasts :term_exit and stops the process", %{dir: dir} do
    id = start_terminal(dir)
    [{pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})
    ref = Process.monitor(pid)

    Terminal.input(id, "exit\n")
    assert_receive {:term_exit, ^id, _reason}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "stops and kills the shell when its owner dies", %{dir: dir} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    id = start_terminal(dir, owner)
    [{pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})
    os_pid = :sys.get_state(pid).os_pid
    ref = Process.monitor(pid)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_os_process_gone(os_pid)
  end

  test "kills the shell even if the terminal process crashes", %{dir: dir} do
    id = start_terminal(dir)
    [{pid, _}] = Registry.lookup(Bee.Registry, {:terminal, id})
    os_pid = :sys.get_state(pid).os_pid

    Process.exit(pid, :kill)
    assert_os_process_gone(os_pid)
  end

  # Starts /bin/sh (not the user's $SHELL, to keep rc files out of tests),
  # subscribes, and waits for the first prompt: input sent before the shell
  # has set up the pty can be discarded.
  defp start_terminal(dir, owner \\ self()) do
    id = System.unique_integer([:positive])
    Phoenix.PubSub.subscribe(Bee.PubSub, Terminal.topic(id))
    {:ok, _} = Terminal.start(id: id, owner: owner, shell: "/bin/sh", cwd: dir)
    on_exit(fn -> Terminal.stop(id) end)
    await_output(id, ~r/[$#] $/)
    id
  end

  defp await_output(id, pattern, acc \\ "") do
    receive do
      {:term_data, ^id, _seq, data} ->
        acc = acc <> data
        if acc =~ pattern, do: acc, else: await_output(id, pattern, acc)
    after
      2_000 -> flunk("no output matching #{inspect(pattern)}, got: #{inspect(acc)}")
    end
  end

  defp assert_os_process_gone(os_pid, tries \\ 50) do
    cond do
      not File.exists?("/proc/#{os_pid}") -> :ok
      tries == 0 -> flunk("OS process #{os_pid} still running")
      true -> Process.sleep(20) && assert_os_process_gone(os_pid, tries - 1)
    end
  end
end

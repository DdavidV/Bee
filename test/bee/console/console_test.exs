defmodule Bee.ConsoleTest do
  use ExUnit.Case, async: true

  alias Bee.Console

  setup do
    id = System.unique_integer([:positive])
    Phoenix.PubSub.subscribe(Bee.PubSub, Bee.Terminal.topic(id))
    {:ok, pid} = Console.start(id: id, owner: self(), root: "/some/folder")
    on_exit(fn -> Process.exit(pid, :kill) end)
    output(id, "bee(1)>")
    %{id: id, pid: pid}
  end

  defp type(id, keys), do: Bee.Terminal.input(id, keys)

  # Output until `expected` shows up in it (escape sequences removed).
  defp output(id, expected, acc \\ "") do
    receive do
      {:term_data, ^id, _seq, data} ->
        acc = acc <> String.replace(data, ~r/\e\[[0-9;]*[A-Za-z]/, "")
        if String.contains?(acc, expected), do: acc, else: output(id, expected, acc)
    after
      3_000 -> flunk("#{inspect(expected)} never came; got #{inspect(acc)}")
    end
  end

  test "evaluates, prints results, keeps variables", %{id: id} do
    type(id, "x = 20\r")
    output(id, "bee(2)>")
    type(id, "x + 22\r")
    assert output(id, "bee(3)>") =~ "42\r\n"
  end

  test "an incomplete expression continues on the next line", %{id: id} do
    type(id, "if true do\r")
    output(id, "...(1)>")
    type(id, ":yes\rend\r")
    assert output(id, "bee(2)>") =~ ":yes"
  end

  test "output and errors", %{id: id} do
    type(id, ~s|IO.puts("hello")\r|)
    assert output(id, "bee(2)>") =~ "hello\r\n:ok"
    type(id, "1 / 0\r")
    assert output(id, "bee(3)>") =~ "ArithmeticError"
  end

  test "Ctrl+C interrupts what runs, and drops a line", %{id: id} do
    type(id, "Process.sleep(:infinity)\r")
    Process.sleep(50)
    type(id, <<3>>)
    assert output(id, "bee(1)>") =~ "interrupted"
    type(id, "half a line" <> <<3>>)
    assert output(id, "bee(1)>") =~ "^C"
  end

  test "history, editing keys, Tab completion", %{id: id} do
    type(id, "1 + 1\r")
    output(id, "bee(2)>")
    # ↑ brings it back; ← and Backspace edit it: "1 + |1" → "1|1"
    type(id, "\e[A\e[D\x7f\x7f\x7f\r")
    assert output(id, "bee(3)>") =~ "11\r\n"

    type(id, "Enum.redu\t")
    output(id, "Enum.reduce")
  end

  test "helpers act on the console's window", %{id: id} do
    type(id, "root()\r")
    assert output(id, "bee(2)>") =~ ~s("/some/folder")

    type(id, ~s|run("workbench.action.togglePanel", ["x"])\r|)
    assert_receive {:bee_api, {:execute_command, "workbench.action.togglePanel", ["x"]}}

    type(id, "memory().processes > 0\r")
    assert output(id, "bee(4)>") =~ "true"

    type(id, "help()\r")
    assert output(id, "bee(5)>") =~ "commands()"
  end

  test "keys typed while something runs wait for it", %{id: id} do
    # one input: the second line arrives while the first one sleeps
    type(id, "Process.sleep(200)\r1 + 41\r")
    assert output(id, "bee(3)>") =~ "42\r\n"
  end

  test "stops with its window", %{pid: pid} do
    ref = Process.monitor(pid)
    window = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, console} =
      Console.start(id: System.unique_integer([:positive]), owner: window, root: "/")

    ref2 = Process.monitor(console)
    Process.exit(window, :kill)
    assert_receive {:DOWN, ^ref2, :process, ^console, :normal}, 2_000
    refute_received {:DOWN, ^ref, _, _, _}
  end
end

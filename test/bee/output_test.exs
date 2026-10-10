defmodule Bee.OutputTest do
  use ExUnit.Case, async: true

  alias Bee.Output

  setup do
    root = "/output-test-#{System.unique_integer([:positive])}"
    Output.subscribe(root)
    on_exit(fn -> Output.forget_workspace(root) end)
    %{root: root}
  end

  test "text is kept by workspace and channel; changes are told", %{root: root} do
    assert Output.channels(root) == []
    assert Output.get(root, "A") == ""

    Output.append(root, "B", "one ")
    Output.append_line(root, "B", "two")
    Output.append(root, "A", "x")
    Output.append(root, "A", "")

    assert_receive {:output, :channels}
    assert_receive {:output, :appended, "B", "one "}
    assert_receive {:output, :appended, "B", "two\n"}
    assert_receive {:output, :channels}
    assert_receive {:output, :appended, "A", "x"}
    refute_receive {:output, :appended, "A", ""}, 50

    assert Output.channels(root) == ["A", "B"]
    assert Output.get(root, "B") == "one two\n"
    assert Output.channels(root <> "-other") == []

    # Cleared: empty, still there.
    Output.clear(root, "B")
    assert_receive {:output, :cleared, "B"}
    assert Output.get(root, "B") == ""
    assert Output.channels(root) == ["A", "B"]
    Output.clear(root, "nope")
    refute_receive {:output, :cleared, "nope"}, 50

    Output.forget_workspace(root)
    assert Output.channels(root) == []
  end

  test "a long channel keeps its end, from the start of a line", %{root: root} do
    line = String.duplicate("é", 500) <> "\n"
    for n <- 1..700, do: Output.append(root, "Long", "#{n} " <> line)

    text = Output.get(root, "Long")
    assert byte_size(text) <= 512_000
    assert String.valid?(text)
    assert String.ends_with?(text, "700 " <> line)
    # Whole lines only.
    assert text =~ ~r/^\d+ é/
    refute text =~ "\n1 é"
  end
end

defmodule Bee.DiffTest do
  use ExUnit.Case, async: true

  alias Bee.Diff

  test "the changed lines, numbered in each text, with the lines around them" do
    original = Enum.map_join(1..12, "\n", &"line #{&1}") <> "\n"

    modified =
      original
      |> String.replace("line 6\n", "six\nand a half\n")
      |> String.replace("line 12\n", "")

    assert Diff.rows(original, modified, 1) == [
             {:eq, 5, 5, "line 5"},
             {:del, 6, nil, "line 6"},
             {:ins, nil, 6, "six"},
             {:ins, nil, 7, "and a half"},
             {:eq, 7, 8, "line 7"},
             :gap,
             {:eq, 11, 12, "line 11"},
             {:del, 12, nil, "line 12"}
           ]
  end

  test "the same text: nothing; a new file: every line added; line ends don't count" do
    assert Diff.rows("a\nb\n", "a\nb\n") == []
    assert Diff.rows("a\r\nb\r\n", "a\nb") == []
    assert Diff.rows("", "a\nb\n") == [{:ins, nil, 1, "a"}, {:ins, nil, 2, "b"}]
    assert Diff.rows("a\n", "") == [{:del, 1, nil, "a"}]
  end
end

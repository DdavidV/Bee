defmodule Bee.Editor.PositionsTest do
  use ExUnit.Case, async: true

  alias Bee.Editor.Positions

  defp at(line, character), do: %{"line" => line, "character" => character}

  test "positions are byte offsets, in the order asked" do
    text = "one\ntwo\n\nfour"

    assert {:ok, [0, 6, 8, 13], {0, 0}} =
             Positions.to_bytes(text, [at(0, 0), at(1, 2), at(2, 0), at(3, 4)])

    assert {:ok, [10, 3, 4], {0, 0}} = Positions.to_bytes(text, [at(3, 1), at(0, 3), at(1, 0)])
    assert Positions.to_bytes(text, []) == {:ok, [], {0, 0}}
    assert {:ok, [0], {0, 0}} = Positions.to_bytes("", [at(0, 0)])
  end

  test "they are found from a line known already, when they are after it" do
    text = "one\ntwo\nthree\nfour"

    # The first position's line and where it starts: for the next ones.
    assert {:ok, [16, 10], {2, 8} = known} = Positions.to_bytes(text, [at(3, 2), at(2, 2)])
    assert {:ok, [9], {2, 8}} = Positions.to_bytes(text, [at(2, 1)], known)
    assert {:ok, [18], {3, 14}} = Positions.to_bytes(text, [at(3, 4)], known)
    # Before it: from the start.
    assert {:ok, [5], {1, 4}} = Positions.to_bytes(text, [at(1, 1)], known)
  end

  test "characters are UTF-16 units: two for what is outside the basic plane" do
    # ö: 2 bytes, 1 unit; 😀: 4 bytes, 2 units
    text = "aö😀b\nö"

    assert {:ok, [1, 3, 7, 8], _} =
             Positions.to_bytes(text, [at(0, 1), at(0, 2), at(0, 4), at(0, 5)])

    assert {:ok, [11], _} = Positions.to_bytes(text, [at(1, 1)])
    # Inside the pair: not a place.
    assert Positions.to_bytes(text, [at(0, 3)]) == :error
  end

  test "a line's \\r\\n is its break" do
    text = "one\r\ntwo\r\n"

    assert {:ok, [3, 5, 8, 10], _} =
             Positions.to_bytes(text, [at(0, 3), at(1, 0), at(1, 3), at(2, 0)])

    assert Positions.to_bytes(text, [at(0, 4)]) == :error
  end

  test "what isn't a place in the text is an error" do
    text = "one\ntwo"
    assert Positions.to_bytes(text, [at(2, 0)]) == :error
    assert Positions.to_bytes(text, [at(0, 4)]) == :error
    assert Positions.to_bytes(text, [at(-1, 0)]) == :error
    assert Positions.to_bytes(text, [at(0, -1)]) == :error
    assert Positions.to_bytes(text, [%{"line" => "0", "character" => 0}]) == :error
    assert Positions.to_bytes(text, [%{}]) == :error
  end

  test "lines agree with the browser's editor unless a \\r stands alone" do
    assert Positions.line_breaks_agree?("one\ntwo\r\nthree")
    assert Positions.line_breaks_agree?("")
    refute Positions.line_breaks_agree?("one\rtwo")
    refute Positions.line_breaks_agree?("one\r\ntwo\r")
  end
end

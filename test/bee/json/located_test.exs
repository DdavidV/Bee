defmodule Bee.JSON.LocatedTest do
  use ExUnit.Case, async: true

  alias Bee.JSON.Located

  test "values and where they are" do
    text = ~s({\n  // a comment\n  "a": [1, {"b": "x\\"y"}],\n  "n": -1.5e3, "t": null,\n})

    assert {:ok, value, locs} = Located.parse(text)
    assert value == %{"a" => [1, %{"b" => "x\"y"}], "n" => -1500.0, "t" => nil}

    slice = fn %{from: from, to: to} -> binary_part(text, from, to - from) end
    key = fn %{key_from: from, key_to: to} -> binary_part(text, from, to - from) end

    assert slice.(locs[[]]) == String.trim_trailing(text)
    assert slice.(locs[["a", "1", "b"]]) == ~s("x\\"y")
    assert key.(locs[["a", "1", "b"]]) == ~s("b")
    assert slice.(locs[["a", "0"]]) == "1"
    assert slice.(locs[["n"]]) == "-1.5e3"
    assert key.(locs[["t"]]) == ~s("t")
  end

  test "multi-byte text: byte offsets" do
    text = ~s({"é": "ő", "k": 1})
    assert {:ok, _, locs} = Located.parse(text)
    assert binary_part(text, locs[["k"]].from, 1) == "1"
  end

  test "errors and where" do
    assert {:error, "Colon expected", 5} = Located.parse(~s({"a" 1}))
    assert {:error, "Comma or ] expected", 5} = Located.parse("[1, 2")
    assert {:error, "Value expected", 6} = Located.parse(~s({"a": tru}))
    assert {:error, "Unterminated string", 2} = Located.parse(~s("x))
    assert {:error, "Unexpected text after the end", 3} = Located.parse("{} x")
    assert {:error, "Unterminated comment", 0} = Located.parse("/* x")
    assert {:error, "Value expected", 0} = Located.parse("")
    assert {:error, "Property name expected (in double quotes)", 1} = Located.parse("{a: 1}")
  end
end

defmodule Bee.JSON.JSONCTest do
  use ExUnit.Case, async: true

  alias Bee.JSON.JSONC

  test "plain JSON" do
    assert JSONC.decode(~s({"a": 1, "b": [true, null]})) == {:ok, %{"a" => 1, "b" => [true, nil]}}
  end

  test "line and block comments" do
    text = """
    // header
    {
      "a": 1, // trailing
      /* block
         comment */ "b": 2
    }
    """

    assert JSONC.decode(text) == {:ok, %{"a" => 1, "b" => 2}}
  end

  test "trailing commas in objects and arrays" do
    assert JSONC.decode(~s({"a": [1, 2,], "b": {"c": 3,},})) ==
             {:ok, %{"a" => [1, 2], "b" => %{"c" => 3}}}
  end

  test "comment markers and commas inside strings are kept" do
    text =
      ~s({"url": "http://x//y", "glob": "/* not a comment */", "s": "a,}", "q": "say \\"hi\\" // no"})

    assert JSONC.decode(text) ==
             {:ok,
              %{
                "url" => "http://x//y",
                "glob" => "/* not a comment */",
                "s" => "a,}",
                "q" => ~s(say "hi" // no)
              }}
  end

  test "non-ASCII text in comments and strings" do
    assert JSONC.decode(~s(// árvíztűrő 🐝\n{"név": "méh 🐝"})) == {:ok, %{"név" => "méh 🐝"}}
  end

  test "errors report line and column of the original text" do
    text = """
    {
      // comment
      "a": 1
      "b": 2
    }
    """

    assert {:error, message} = JSONC.decode(text)
    assert message =~ "line 4, column 3"
  end
end

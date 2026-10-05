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

  describe "put/3" do
    test "replaces a value, keeping comments and the rest" do
      text = """
      {
        // font
        "editor.fontSize": 14, /* big */
        "plugins.disabled": ["a", "}"], // trailing
      }
      """

      assert {:ok, new} = JSONC.put(text, "plugins.disabled", ["a", "git"])
      assert new == String.replace(text, ~s(["a", "}"]), ~s(["a","git"]))

      assert {:ok, %{"plugins.disabled" => ["a", "git"], "editor.fontSize" => 14}} =
               JSONC.decode(new)
    end

    test "adds a missing key after the last one, with its indentation" do
      text = ~s({\n    "a": {"b": [1, 2]} // c\n}\n)
      assert {:ok, new} = JSONC.put(text, "k", true)
      assert new == ~s({\n    "a": {"b": [1, 2]},\n    "k": true // c\n}\n)
    end

    test "adds to an object holding only comments" do
      text = "// header\n{\n  // \"a\": 1,\n}\n"
      assert {:ok, new} = JSONC.put(text, "a", 2)
      assert new == "// header\n{\n  // \"a\": 1,\n  \"a\": 2\n}\n"
      assert {:ok, new} = JSONC.put("{}", "a", "x")
      assert JSONC.decode(new) == {:ok, %{"a" => "x"}}
    end

    test "refuses what isn't an object" do
      assert {:error, _} = JSONC.put("[1]", "a", 1)
      assert {:error, _} = JSONC.put("{", "a", 1)
    end
  end
end

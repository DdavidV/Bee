defmodule Bee.Commands.WhenTest do
  use ExUnit.Case, async: true

  alias Bee.Commands.When

  defp eval(source, ctx), do: When.eval(When.parse!(source), ctx)

  describe "parse/1" do
    test "empty and nil mean always" do
      assert When.parse(nil) == {:ok, ["true"]}
      assert When.parse("  ") == {:ok, ["true"]}
    end

    test "precedence: ! binds tighter than &&, && tighter than ||" do
      assert When.parse!("a || !b && c") == [
               "or",
               ["key", "a"],
               ["and", ["not", ["key", "b"]], ["key", "c"]]
             ]
    end

    test "parentheses" do
      assert When.parse!("!(a || b) && c") ==
               ["and", ["not", ["or", ["key", "a"], ["key", "b"]]], ["key", "c"]]
    end

    test "chains flatten" do
      assert When.parse!("a && b && c") == ["and", ["key", "a"], ["key", "b"], ["key", "c"]]
    end

    test "comparisons with unquoted, quoted and boolean values" do
      assert When.parse!("editorLangId == elixir") == ["eq", "editorLangId", "elixir"]

      assert When.parse!("resourceFilename === 'mix exs'") == [
               "eq",
               "resourceFilename",
               "mix exs"
             ]

      assert When.parse!("x != true") == ["ne", "x", true]
      assert When.parse!("x !== false") == ["ne", "x", false]
      assert When.parse!("terminalCount >= 2") == ["ge", "terminalCount", "2"]
      assert When.parse!("a<1") == ["lt", "a", "1"]
    end

    test "regex, with escaped slashes and flags" do
      assert When.parse!(~S"resourceFilename =~ /^docker/i") == [
               "regex",
               "resourceFilename",
               "^docker",
               "i"
             ]

      assert When.parse!(~S"path =~ /a\/b/") == ["regex", "path", ~S"a\/b", ""]
    end

    test "in and not in" do
      assert When.parse!("resourceExtname in supportedExts") == [
               "in",
               "resourceExtname",
               "supportedExts"
             ]

      assert When.parse!("a not in b") == ["notin", "a", "b"]
    end

    test "keys may contain dots, colons and dashes" do
      assert When.parse!("config.editor.fontSize > 12") == ["gt", "config.editor.fontSize", "12"]
      assert When.parse!("view.my-plugin:focused") == ["key", "view.my-plugin:focused"]
    end

    test "errors" do
      assert {:error, msg} = When.parse("a &&")
      assert msg =~ "unexpected end"
      assert {:error, msg} = When.parse("(a || b")
      assert msg =~ "missing )"
      assert {:error, _} = When.parse("a b")
      assert {:error, _} = When.parse("a == ")
      assert {:error, _} = When.parse("a =~ nope")
      assert {:error, _} = When.parse("a == 'unterminated")
    end
  end

  describe "eval/2" do
    test "bare keys use truthiness" do
      assert eval("a", %{"a" => true})
      assert eval("a", %{"a" => "x"})
      refute eval("a", %{"a" => 0})
      refute eval("a", %{"a" => ""})
      refute eval("a", %{})
      assert eval("!a", %{})
    end

    test "== is loose but booleans are strict" do
      assert eval("n == 2", %{"n" => 2})
      assert eval("s == elixir", %{"s" => "elixir"})
      assert eval("b == true", %{"b" => true})
      refute eval("b == true", %{"b" => "true"})
      refute eval("missing == x", %{})
      assert eval("missing != x", %{})
    end

    test "numeric comparisons; non-numbers are false" do
      assert eval("n > 1", %{"n" => 2})
      assert eval("n <= 2", %{"n" => 2})
      refute eval("n < 1", %{"n" => 2})
      refute eval("s > 1", %{"s" => "abc"})
      refute eval("missing > 1", %{})
    end

    test "regex" do
      assert eval("f =~ /\\.exs?$/", %{"f" => "mix.exs"})
      assert eval("f =~ /DOCKER/i", %{"f" => "Dockerfile"})
      refute eval("f =~ /DOCKER/", %{"f" => "Dockerfile"})
      refute eval("missing =~ /.*/", %{})
    end

    test "in / not in for lists and maps" do
      ctx = %{"ext" => ".ex", "exts" => [".ex", ".exs"], "map" => %{".ex" => 1}}
      assert eval("ext in exts", ctx)
      assert eval("ext in map", ctx)
      refute eval("ext not in exts", ctx)
      refute eval("ext in missing", ctx)
    end

    test "combined" do
      ctx = %{"editorFocus" => true, "editorLangId" => "elixir", "terminalCount" => 0}
      assert eval("editorFocus && editorLangId == elixir && !(terminalCount > 0)", ctx)
      refute eval("terminalFocus || editorLangId == erlang", ctx)
    end
  end
end

defmodule Bee.Workspace.GlobTest do
  use ExUnit.Case, async: true

  alias Bee.Workspace.Glob

  test "**/name matches at any depth, including the root" do
    assert Glob.match?("**/.git", ".git")
    assert Glob.match?("**/.git", "a/b/.git")
    refute Glob.match?("**/.git", "a/.github")
  end

  test "* stays within one path segment" do
    assert Glob.match?("*.log", "debug.log")
    refute Glob.match?("*.log", "logs/debug.log")
    assert Glob.match?("**/*.log", "logs/debug.log")
  end

  test "? matches one character" do
    assert Glob.match?("file?.txt", "file1.txt")
    refute Glob.match?("file?.txt", "file10.txt")
  end

  test "{a,b} alternatives" do
    assert Glob.match?("**/{_build,deps}", "_build")
    assert Glob.match?("**/{_build,deps}", "apps/x/deps")
    refute Glob.match?("**/{_build,deps}", "depsy")
  end

  test "regex characters are literal" do
    assert Glob.match?("a+b(1).txt", "a+b(1).txt")
    refute Glob.match?("a.b", "axb")
  end

  test "patterns anchored at the root" do
    assert Glob.match?("priv/static", "priv/static")
    refute Glob.match?("priv/static", "x/priv/static")
  end
end

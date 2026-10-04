defmodule Bee.Commands.KeysTest do
  use ExUnit.Case, async: true

  alias Bee.Commands.Keys

  test "normalizes case and modifier order" do
    assert Keys.parse("Shift+Ctrl+P") == {:ok, ["ctrl+shift+p"]}
    assert Keys.parse("alt+meta+shift+ctrl+f5") == {:ok, ["ctrl+shift+alt+meta+f5"]}
  end

  test "modifier and key aliases" do
    assert Keys.parse("cmd+s") == {:ok, ["meta+s"]}
    assert Keys.parse("win+e") == {:ok, ["meta+e"]}
    assert Keys.parse("control+option+esc") == {:ok, ["ctrl+alt+escape"]}
    assert Keys.parse("ctrl+ArrowUp") == {:ok, ["ctrl+up"]}
  end

  test "chords" do
    assert Keys.parse("ctrl+k  ctrl+s") == {:ok, ["ctrl+k", "ctrl+s"]}
  end

  test "punctuation and named keys" do
    assert Keys.parse("ctrl+`") == {:ok, ["ctrl+`"]}
    assert Keys.parse("ctrl+,") == {:ok, ["ctrl+,"]}
    assert Keys.parse("f1") == {:ok, ["f1"]}
    assert Keys.parse("ctrl+pagedown") == {:ok, ["ctrl+pagedown"]}
  end

  test "errors" do
    assert {:error, msg} = Keys.parse("ctrl+nope")
    assert msg =~ "unknown key"
    assert {:error, msg} = Keys.parse("hyper+a")
    assert msg =~ "unknown modifier"
    assert {:error, _} = Keys.parse("")
    assert {:error, _} = Keys.parse(42)
  end

  test "labels" do
    assert Keys.label(["ctrl+shift+p"]) == "Ctrl+Shift+P"
    assert Keys.label(["ctrl+k", "ctrl+s"]) == "Ctrl+K Ctrl+S"
    assert Keys.label(["ctrl+,"]) == "Ctrl+,"
    assert Keys.label(["f1"]) == "F1"
  end
end

defmodule Bee.Commands.KeybindingsTest do
  use ExUnit.Case, async: true

  alias Bee.Commands.Keybindings

  @defaults [
    %{key: "ctrl+b", mac: "cmd+b", command: "toggleSidebar", when: nil},
    %{key: "ctrl+j", mac: nil, command: "togglePanel", when: nil},
    %{key: "ctrl+k ctrl+s", mac: nil, command: "openKeybindings", when: nil},
    %{key: "escape", mac: nil, command: "closePalette", when: "inQuickOpen"}
  ]

  defp commands(bindings), do: Enum.map(bindings, & &1.command)

  test "defaults are normalized, with mac falling back to key" do
    {bindings, []} = Keybindings.resolve(@defaults, [])

    assert [
             %{key: ["ctrl+b"], mac: ["meta+b"], command: "toggleSidebar", when: ["true"]},
             %{key: ["ctrl+j"], mac: ["ctrl+j"]},
             %{key: ["ctrl+k", "ctrl+s"]},
             %{key: ["escape"], when: ["key", "inQuickOpen"]}
           ] = bindings
  end

  test "user entries are appended (so they win)" do
    user = [%{"key" => "ctrl+b", "command" => "myCommand", "when" => "editorFocus"}]
    {bindings, []} = Keybindings.resolve(@defaults, user)

    assert List.last(bindings) == %{
             key: ["ctrl+b"],
             mac: ["ctrl+b"],
             command: "myCommand",
             when: ["key", "editorFocus"]
           }
  end

  test "-command removes all bindings of a command" do
    {bindings, []} = Keybindings.resolve(@defaults, [%{"command" => "-togglePanel"}])
    refute "togglePanel" in commands(bindings)
  end

  test "-command with key only removes that key (matching key or mac)" do
    user = [
      %{"key" => "ctrl+j", "command" => "togglePanel"},
      %{"key" => "cmd+b", "command" => "-toggleSidebar"},
      %{"key" => "ctrl+x", "command" => "-togglePanel"}
    ]

    {bindings, []} = Keybindings.resolve(@defaults, user)
    refute "toggleSidebar" in commands(bindings)
    assert Enum.count(bindings, &(&1.command == "togglePanel")) == 2
  end

  test "-command with when only removes bindings with that when" do
    user = [%{"command" => "-closePalette", "when" => "editorFocus"}]
    {bindings, []} = Keybindings.resolve(@defaults, user)
    assert "closePalette" in commands(bindings)

    user = [%{"command" => "-closePalette", "when" => "inQuickOpen"}]
    {bindings, []} = Keybindings.resolve(@defaults, user)
    refute "closePalette" in commands(bindings)
  end

  test "invalid entries are skipped and reported with their position" do
    user = [
      %{"key" => "ctrl+nope", "command" => "x"},
      %{"key" => "ctrl+q", "command" => "x", "when" => "a &&"},
      %{"command" => "x"},
      "not an object",
      %{"key" => "ctrl+q", "command" => "ok"}
    ]

    {bindings, errors} = Keybindings.resolve(@defaults, user)
    assert List.last(bindings).command == "ok"
    assert length(bindings) == length(@defaults) + 1

    assert [
             "entry 1: unknown key" <> _,
             "entry 2: unexpected end" <> _,
             ~s(entry 3: missing "key"),
             "entry 4: Type mismatch. Expected Object but got String."
           ] = errors
  end

  test "entries are checked against the keybindings JSON Schema" do
    user = [
      %{"key" => "ctrl+q", "comand" => "x"},
      %{"key" => "ctrl+q", "command" => "x", "when" => true},
      %{"key" => "", "command" => "x"},
      %{"command" => "-togglePanel"}
    ]

    {bindings, errors} = Keybindings.resolve(@defaults, user)

    assert errors == [
             ~s(entry 1: unknown property "comand"; missing "command"),
             "entry 2: Type mismatch. Expected String but got Boolean. (at when)",
             "entry 3: Expected value to have a minimum length of 1 but was 0. (at key)"
           ]

    refute "togglePanel" in commands(bindings), "a removal entry needs no key"
  end

  test "unknown commands are kept but reported" do
    user = [%{"key" => "ctrl+q", "command" => "plugin.notLoadedYet"}]
    {bindings, errors} = Keybindings.resolve(@defaults, user, ["toggleSidebar"])
    assert List.last(bindings).command == "plugin.notLoadedYet"
    assert errors == [~s(entry 1: unknown command "plugin.notLoadedYet")]
  end

  test "label shows the winning binding" do
    {bindings, []} =
      Keybindings.resolve(@defaults, [%{"key" => "ctrl+alt+b", "command" => "toggleSidebar"}])

    assert Keybindings.label("toggleSidebar", bindings) == "Ctrl+Alt+B"
    assert Keybindings.label("openKeybindings", bindings) == "Ctrl+K Ctrl+S"
    assert Keybindings.label("none", bindings) == nil
  end
end

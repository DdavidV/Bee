defmodule Bee.Commands.RegistryTest do
  # Registers sources in the global registry.
  use ExUnit.Case, async: false

  alias Bee.Commands.Registry, as: CommandRegistry
  alias Bee.Workbench

  defmodule PluginActions do
    use Bee.Commands.Command

    @command "plugin.hello"
    def hello(wb), do: Workbench.set_status(wb, "hello")
  end

  defp manifest(contributes), do: %{"name" => "test", "contributes" => contributes}

  @hello %{"command" => "plugin.hello", "title" => "Hello", "runtime" => "server"}

  describe "the built-in manifest (priv/contributions/bee.json)" do
    test "is loaded with handlers for every server command" do
      for command <- CommandRegistry.commands() do
        case command.runtime do
          :server -> assert {Bee.Workbench.Actions, _fun} = command.handler
          :client -> assert command.handler == nil
        end
      end
    end

    test "every server command runs against a fresh workbench" do
      for %{runtime: :server, handler: {module, fun}, id: id} <- CommandRegistry.commands() do
        assert {%Workbench{}, effects} =
                 Workbench.wrap(apply(module, fun, [Workbench.new("/tmp/ws")])),
               "#{id} must return a workbench"

        assert is_list(effects)
      end
    end

    test "menus are ordered by group, with separators between groups" do
      file = Enum.find(CommandRegistry.menus(), &(&1.id == "file"))
      ids = Enum.map(file.items, &if(&1 == :separator, do: :separator, else: &1.command))

      assert ids == [
               "workbench.action.files.save",
               "workbench.action.closeActiveEditor",
               :separator,
               "workbench.action.openSettingsJson",
               "workbench.action.openWorkspaceSettingsFile",
               "workbench.action.openGlobalKeybindingsFile"
             ]
    end
  end

  describe "register/3" do
    setup do
      on_exit(fn -> CommandRegistry.unregister(:test_plugin) end)
    end

    test "adds commands, keybindings and menu items; unregister removes them" do
      CommandRegistry.subscribe()

      :ok =
        CommandRegistry.register(
          :test_plugin,
          manifest(%{
            "commands" => [@hello],
            "keybindings" => [%{"key" => "ctrl+alt+h", "command" => "plugin.hello"}],
            "menus" => %{
              "menubar/file" => [%{"command" => "plugin.hello", "group" => "1_save@3"}]
            }
          }),
          [PluginActions]
        )

      assert_receive :commands_changed
      assert %{handler: {PluginActions, :hello}} = CommandRegistry.command("plugin.hello")

      assert Enum.any?(
               CommandRegistry.keybindings(),
               &(&1.command == "plugin.hello" and &1.source == :test_plugin)
             )

      # slotted into the built-in "1_save" group, after Close Editor
      file = Enum.find(CommandRegistry.menus(), &(&1.id == "file"))
      assert Enum.at(file.items, 2).command == "plugin.hello"
      assert Enum.at(file.items, 3) == :separator

      CommandRegistry.unregister(:test_plugin)
      assert CommandRegistry.command("plugin.hello") == nil
    end

    test "rejects manifests that don't match the schema" do
      assert_raise ArgumentError, ~r/invalid contributions manifest.*runtime/, fn ->
        CommandRegistry.register(
          :test_plugin,
          manifest(%{"commands" => [Map.delete(@hello, "runtime")]})
        )
      end

      assert_raise ArgumentError, ~r/invalid contributions manifest/, fn ->
        CommandRegistry.register(:test_plugin, manifest(%{"comands" => []}))
      end
    end

    test "server commands need exactly one handler, and handlers a declared command" do
      assert_raise ArgumentError, ~r/has no `use Bee.Commands.Command` handler/, fn ->
        CommandRegistry.register(:test_plugin, manifest(%{"commands" => [@hello]}), [])
      end

      assert_raise ArgumentError, ~r/undeclared command "plugin.hello"/, fn ->
        CommandRegistry.register(:test_plugin, manifest(%{"commands" => []}), [PluginActions])
      end

      assert_raise ArgumentError, ~r/must not have a server handler/, fn ->
        CommandRegistry.register(
          :test_plugin,
          manifest(%{"commands" => [%{@hello | "runtime" => "client"}]}),
          [PluginActions]
        )
      end
    end

    test "rejects invalid keys and when clauses" do
      assert_raise ArgumentError, ~r/invalid key/, fn ->
        CommandRegistry.register(
          :test_plugin,
          manifest(%{
            "commands" => [@hello],
            "keybindings" => [%{"key" => "ctrl+nope", "command" => "plugin.hello"}]
          }),
          [PluginActions]
        )
      end

      assert_raise ArgumentError, ~r/unexpected end/, fn ->
        CommandRegistry.register(
          :test_plugin,
          manifest(%{"commands" => [Map.put(@hello, "enablement", "a &&")]}),
          [PluginActions]
        )
      end
    end
  end
end

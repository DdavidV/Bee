defmodule Bee.Commands.RegistryTest do
  # Registers sources in the global registry.
  use ExUnit.Case, async: false

  alias Bee.Commands.Registry, as: CommandRegistry
  alias Bee.Contributions
  alias Bee.Workbench

  defmodule PluginActions do
    use Bee.Commands.Command

    @command "plugin.hello"
    def hello(wb), do: Workbench.set_status(wb, "hello")
  end

  defp manifest(contributes), do: %{"name" => "test", "contributes" => contributes}

  @hello %{"command" => "plugin.hello", "title" => "Hello", "runtime" => "server"}

  describe "Bee's own manifest (priv/contributions/bee.json)" do
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

  describe "contributing (Bee.Contributions.register/3)" do
    setup do
      on_exit(fn -> Contributions.unregister(:test_plugin) end)
    end

    test "adds commands, keybindings and menu items; unregister removes them" do
      Contributions.subscribe()

      :ok =
        Contributions.register(
          :test_plugin,
          manifest(%{
            "commands" => [@hello],
            "keybindings" => [%{"key" => "ctrl+alt+h", "command" => "plugin.hello"}],
            "menus" => %{
              "menubar/file" => [%{"command" => "plugin.hello", "group" => "1_save@3"}]
            }
          }),
          handlers: [PluginActions]
        )

      assert_receive {:contributions_changed, [:commands]}
      assert %{handler: {PluginActions, :hello}} = CommandRegistry.command("plugin.hello")

      assert Enum.any?(
               CommandRegistry.keybindings(),
               &(&1.command == "plugin.hello" and &1.source == :test_plugin)
             )

      # slotted into the built-in "1_save" group, after Close Editor
      file = Enum.find(CommandRegistry.menus(), &(&1.id == "file"))
      assert Enum.at(file.items, 2).command == "plugin.hello"
      assert Enum.at(file.items, 3) == :separator

      Contributions.unregister(:test_plugin)
      assert_receive {:contributions_changed, [:commands]}
      assert CommandRegistry.command("plugin.hello") == nil
    end

    test "rejects manifests that don't match the schema" do
      assert {:error, message} =
               Contributions.register(
                 :test_plugin,
                 manifest(%{"commands" => [Map.delete(@hello, "runtime")]})
               )

      assert message =~ ~r/invalid manifest.*runtime/

      assert {:error, "invalid manifest" <> _} =
               Contributions.register(:test_plugin, manifest(%{"comands" => []}))
    end

    test "server commands need exactly one handler, and handlers a declared command" do
      assert {:error, message} =
               Contributions.register(:test_plugin, manifest(%{"commands" => [@hello]}))

      assert message =~ "has no `use Bee.Commands.Command` handler"

      assert {:error, message} =
               Contributions.register(:test_plugin, manifest(%{"commands" => []}),
                 handlers: [PluginActions]
               )

      assert message =~ ~s(undeclared command "plugin.hello")

      assert {:error, message} =
               Contributions.register(
                 :test_plugin,
                 manifest(%{"commands" => [%{@hello | "runtime" => "client"}]}),
                 handlers: [PluginActions]
               )

      assert message =~ "must not have a server handler"
    end

    test "plugin commands are handled by the plugin, and need the matching part" do
      source = {:plugin, "test-plugin"}
      on_exit(fn -> Contributions.unregister(source) end)

      assert {:error, message} =
               Contributions.register(source, manifest(%{"commands" => [@hello]}))

      assert message =~ ~s(needs a "server" part)

      server = %{"module" => "TestPlugin"}

      assert :ok =
               Contributions.register(
                 source,
                 Map.put(manifest(%{"commands" => [@hello]}), "server", server)
               )

      assert %{handler: {:plugin, "test-plugin"}, source: ^source} =
               CommandRegistry.command("plugin.hello")

      client = %{@hello | "command" => "plugin.client", "runtime" => "client"}

      assert {:error, message} =
               Contributions.register(
                 source,
                 Map.put(manifest(%{"commands" => [client]}), "server", server)
               )

      assert message =~ ~s(needs a "browser" part)
    end

    test "command ids are unique across sources" do
      taken = %{@hello | "command" => "workbench.action.togglePanel"}

      assert {:error, message} =
               Contributions.register(
                 {:plugin, "thief"},
                 Map.put(manifest(%{"commands" => [taken]}), "server", %{"module" => "X"})
               )

      assert message =~ ~s(command "workbench.action.togglePanel" is already defined)
      refute {:plugin, "thief"} in Contributions.sources()
    end

    test "rejects invalid keys and when clauses" do
      assert {:error, message} =
               Contributions.register(
                 :test_plugin,
                 manifest(%{
                   "commands" => [@hello],
                   "keybindings" => [%{"key" => "ctrl+nope", "command" => "plugin.hello"}]
                 }),
                 handlers: [PluginActions]
               )

      assert message =~ "invalid key"

      assert {:error, message} =
               Contributions.register(
                 :test_plugin,
                 manifest(%{"commands" => [Map.put(@hello, "enablement", "a &&")]}),
                 handlers: [PluginActions]
               )

      assert message =~ "unexpected end"
    end
  end
end

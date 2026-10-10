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
      for %{runtime: :server, handler: {_, _} = handler, id: id} <- CommandRegistry.commands() do
        assert {%Workbench{}, effects} =
                 Workbench.wrap(
                   CommandRegistry.run_handler(handler, Workbench.new("/tmp/ws"), [])
                 ),
               "#{id} must return a workbench"

        assert is_list(effects)
      end
    end

    test "menus are ordered by group, with separators between groups" do
      file = Enum.find(CommandRegistry.menus(), &(&1.id == "file"))
      ids = Enum.map(file.items, &if(&1 == :separator, do: :separator, else: &1.command))

      assert ids == [
               "workbench.action.files.openFolder",
               "workbench.action.files.openFolderInNewWindow",
               :separator,
               "workbench.action.files.save",
               "workbench.action.closeActiveEditor",
               :separator,
               "workbench.action.openSettingsJson",
               "workbench.action.openWorkspaceSettingsFile",
               "workbench.action.openGlobalKeybindingsFile",
               "workbench.action.selectTheme",
               "workbench.action.selectIconTheme"
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
      # (after Open Folder…, Open Folder in New Window…, a separator, Save)
      file = Enum.find(CommandRegistry.menus(), &(&1.id == "file"))
      assert Enum.at(file.items, 5).command == "plugin.hello"
      assert Enum.at(file.items, 6) == :separator

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

    test "commands of a VS Code extension's code need its extension part" do
      source = {:plugin, "test-ext"}
      on_exit(fn -> Contributions.unregister(source) end)

      run = %{
        "command" => "ext.run",
        "title" => "Run",
        "runtime" => "extension",
        "icon" => %{"light" => "./media/l.svg", "dark" => "media/d.svg"}
      }

      spin = %{
        "command" => "ext.spin",
        "title" => "Spin",
        "runtime" => "extension",
        "icon" => "$(sync~spin)"
      }

      assert {:error, message} =
               Contributions.register(source, manifest(%{"commands" => [run]}))

      assert message =~ ~s(extension command "ext.run" needs an "extension" part)

      :ok =
        Contributions.register(
          source,
          Map.put(manifest(%{"commands" => [run, spin]}), "extension", %{"main" => "./x.js"})
        )

      assert %{runtime: :extension, handler: {:extension, "test-ext"}, icon: icon} =
               CommandRegistry.command("ext.run")

      # Its images are served from the plugin's folder.
      assert icon == %{
               light: "/plugins/test-ext/media/l.svg",
               dark: "/plugins/test-ext/media/d.svg"
             }

      assert CommandRegistry.command("ext.spin").icon == "$(sync~spin)"

      # Only plugins have such code.
      assert {:error, message} =
               Contributions.register(:test_plugin, manifest(%{"commands" => [spin]}))

      assert message =~ "must come from a plugin"
    end

    test "submenus: a menu item names one, its items are a menu of its id" do
      :ok =
        Contributions.register(
          :test_plugin,
          manifest(%{
            "commands" => [@hello],
            "submenus" => [%{"id" => "test.more", "label" => "More"}],
            "menus" => %{
              "explorer/context" => [%{"submenu" => "test.more", "group" => "z_more"}],
              "test.more" => [%{"command" => "plugin.hello"}],
              # Not in the menu bar: left out there.
              "menubar/file" => [%{"submenu" => "test.more", "group" => "1_save@9"}]
            }
          }),
          handlers: [PluginActions]
        )

      assert CommandRegistry.submenus()["test.more"] ==
               %{id: "test.more", label: "More", source: :test_plugin}

      assert %{submenu: "test.more", group: "z_more"} =
               Enum.find(CommandRegistry.menu("explorer/context"), &(&1[:submenu] != nil))

      assert [%{command: "plugin.hello"}] = CommandRegistry.menu("test.more")

      file = Enum.find(CommandRegistry.menus(), &(&1.id == "file"))
      assert Enum.all?(file.items, &(&1 == :separator or is_binary(&1.command)))

      # Ids are unique.
      on_exit(fn -> Contributions.unregister(:test_plugin_2) end)

      assert {:error, message} =
               Contributions.register(
                 :test_plugin_2,
                 manifest(%{"submenus" => [%{"id" => "test.more", "label" => "Again"}]})
               )

      assert message =~ ~s(submenu "test.more" is already defined)
    end

    test "keybindings can name keys per platform, and arguments" do
      :ok =
        Contributions.register(
          :test_plugin,
          manifest(%{
            "keybindings" => [
              %{"mac" => "cmd+alt+p", "command" => "x.macOnly"},
              %{
                "key" => "ctrl+u",
                "linux" => "ctrl+shift+u",
                "win" => "alt+u",
                "command" => "x.u",
                "args" => %{"a" => 1}
              }
            ]
          })
        )

      assert [
               %{key: nil, mac: "cmd+alt+p", command: "x.macOnly"},
               %{key: "ctrl+u", linux: "ctrl+shift+u", win: "alt+u", args: %{"a" => 1}}
             ] = Enum.filter(CommandRegistry.keybindings(), &(&1.source == :test_plugin))

      assert {:error, message} =
               Contributions.register(
                 :test_plugin,
                 manifest(%{
                   "keybindings" => [
                     %{"key" => "ctrl+u", "linux" => "ctrl+nope", "command" => "x"}
                   ]
                 })
               )

      assert message =~ ~s(invalid key "ctrl+nope")

      # Keys for some platform at least.
      assert {:error, "invalid manifest" <> _} =
               Contributions.register(
                 :test_plugin,
                 manifest(%{"keybindings" => [%{"command" => "x"}]})
               )
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

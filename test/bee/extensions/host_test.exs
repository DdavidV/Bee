defmodule Bee.Extensions.HostTest do
  # The extension host: the hello fixture's code (test/fixtures/extensions/
  # hello/extension.js) run in Node.js, the test being its window.
  # Plugins, settings and the workspace are global.
  use ExUnit.Case, async: false

  alias Bee.Editor.Buffer
  alias Bee.Extensions.Host
  alias Bee.Plugins
  alias Bee.Plugins.Context

  @moduletag :capture_log

  test "offsets: UTF-8 bytes on Bee's side, UTF-16 units on Node's" do
    text = "aé🐝b"
    # a: 1 byte, é: 2, 🐝: 4 (2 units), b: 1
    assert Enum.map([0, 1, 3, 7, 8], &Host.to_utf16(text, &1)) == [0, 1, 2, 4, 5]
    assert Enum.map([0, 1, 2, 4, 5], &Host.to_bytes(text, &1)) == [0, 1, 3, 7, 8]
    # Inside the bee's surrogate pair: before it. Past the end: the end.
    assert Host.to_bytes(text, 3) == 3
    assert Host.to_bytes(text, 99) == 8
    assert Host.to_utf16(text, 99) == 5
  end

  describe "with the hello extension" do
    @describetag :node

    setup do
      root = Bee.Workspace.root()
      File.rm_rf!(root)
      File.mkdir_p!(root)
      File.write!(Path.join(root, "notes.txt"), "héllo 🐝 world\nsecond line\n")
      {:ok, ^root} = Bee.Workspace.open(root)

      File.rm_rf!(Plugins.user_dir())
      Bee.Test.Extensions.install("hello")
      Bee.API.subscribe_window(root)

      on_exit(fn ->
        File.rm_rf!(Plugins.user_dir())
        Plugins.reload()
        Bee.Output.forget_workspace(root)
        File.rm_rf!(Path.join(Bee.Settings.user_dir(), "extension-state"))
        File.rm(Bee.Settings.user_path())
        Bee.Settings.reload()
        File.rm_rf!(root)
      end)

      %{root: root, path: Path.join(root, "notes.txt")}
    end

    defp eventually(fun, tries \\ 150) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition not met")
        true -> Process.sleep(20) && eventually(fun, tries - 1)
      end
    end

    # Runs a command as a window does; `opts`: args, active_editor, selections.
    defp run(root, command, opts \\ []) do
      ctx = struct(%Context{root: root, window: self()}, opts)
      Plugins.execute_extension("hello", command, ctx)
    end

    defp status(root), do: Plugins.get("hello", root).status

    test "its code starts with its first command, in Node.js", %{root: root} do
      assert status(root) == :inactive
      assert Host.whereis(root) == nil

      assert :ok = run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, "Hello from the hello extension"}}, 5_000
      assert status(root) == :active
      assert is_pid(Host.whereis(root))

      # The commands it registered, declared in its package.json or not.
      assert Host.command(root, "hello.sayHello") == "hello"
      assert Host.command(root, "hello.ask") == "hello"
      assert Host.command(root, "nope") == nil
    end

    test "workspaceContains: starts with a workspace that has the file", %{root: root} do
      File.write!(Path.join(root, ".hello"), "")
      Plugins.reload("hello")
      eventually(fn -> status(root) == :active end)
    end

    test "the active editor: its document, language and selection", %{root: root, path: path} do
      {:ok, _} = Buffer.open(path)
      # "🐝 world": bytes 7..16 of the first line.
      opts = [active_editor: path, selections: [{7, 17}]]

      run(root, "hello.describe", opts)

      assert_receive {:bee_api, {:show_message, :info, message}}, 5_000

      assert message ==
               ~s(notes.txt plaintext 3 lines, selected "🐝 world" at 0:6, run 1)

      # Its state is kept (ExtensionContext.globalState).
      run(root, "hello.describe", active_editor: nil)
      assert_receive {:bee_api, {:show_message, :info, "no editor"}}, 5_000

      state = Path.join([Bee.Settings.user_dir(), "extension-state", "hello", "state.json"])
      assert Jason.decode!(File.read!(state)) == %{"runs" => 2}
    end

    test "a text editor command edits the open file, in Bee's offsets", %{root: root, path: path} do
      {:ok, _} = Buffer.open(path)
      Buffer.subscribe()

      # "héllo 🐝" and "second".
      run(root, "hello.shout", active_editor: path, selections: [{0, 11}, {18, 24}])

      assert_receive {:buffer_edited, ^path, _version, _edits, text}, 5_000
      assert text == "HÉLLO 🐝 world\nSECOND line\n"
      assert Buffer.get(path).text == text

      # What the extension reads next is the edited text.
      run(root, "hello.describe", active_editor: path, selections: [{0, 5}])
      assert_receive {:bee_api, {:show_message, :info, message}}, 5_000
      assert message =~ ~s(selected "HÉLL")
    end

    test "questions are asked in the window, their answers go back", %{root: root} do
      run(root, "hello.ask")

      assert_receive {:bee_api, {:ask, ref, host, :input, %{prompt: "Who?", value: "you"}}}, 5_000
      send(host, {:bee_answer, ref, "Ann"})

      # A message with buttons is a pick.
      assert_receive {:bee_api, {:ask, ref, ^host, :pick, spec}}, 5_000

      assert %{placeholder: "Greet Ann?", items: [%{label: "Yes"}, %{label: "No", value: no}]} =
               spec

      send(host, {:bee_answer, ref, no})
      assert_receive {:bee_api, {:show_message, :info, "Ann: No"}}, 5_000

      # Dismissed: no answer.
      run(root, "hello.ask")
      assert_receive {:bee_api, {:ask, ref, ^host, :input, _}}, 5_000
      send(host, {:bee_answer, ref, nil})
      assert_receive {:bee_api, {:show_message, :info, "Nobody"}}, 5_000
    end

    test "setContext, status bar items, Bee's own commands", %{root: root} do
      run(root, "hello.context")
      eventually(fn -> Bee.UI.context(root)["hello.ready"] == true end)
      run(root, "hello.context", args: [false])
      eventually(fn -> Bee.UI.context(root)["hello.ready"] == false end)

      run(root, "hello.status")

      eventually(fn ->
        match?(
          [
            %{
              owner: "hello",
              text: "Hello",
              command: "hello.sayHello",
              alignment: :right,
              priority: 5
            }
          ],
          Bee.UI.status_items(root)
        )
      end)

      run(root, "hello.bee")
      assert_receive {:bee_api, {:execute_command, "workbench.action.togglePanel", []}}, 5_000

      # Removed with the extension.
      Plugins.uninstall("hello")
      eventually(fn -> Bee.UI.status_items(root) == [] end)
      eventually(fn -> Host.command(root, "hello.sayHello") == nil end)
      assert Bee.UI.context(root)["hello.ready"] == nil
    end

    test "settings: read, and their changes told", %{root: root} do
      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, "Hello" <> _}}, 5_000

      :ok = Bee.Settings.update(:user, "hello.greeting", fn _ -> "Ahoy" end)
      eventually(fn -> "greeting is now Ahoy" in Host.log(root) end)

      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, "Ahoy from the hello extension"}}, 5_000
    end

    test "output channels, what extensions print, and their failures are the workspace's output",
         %{
           root: root
         } do
      Bee.Output.subscribe(root)

      run(root, "hello.output")
      assert_receive {:output, :channels}, 5_000
      assert_receive {:output, :appended, "Hello", "first line\n"}, 5_000
      # channel.show(): the window shows it.
      assert_receive {:bee_api, {:show_output, "Hello"}}, 5_000

      run(root, "hello.output", args: ["second", false])
      eventually(fn -> Bee.Output.get(root, "Hello") == "first line\nsecond\n" end)
      refute_receive {:bee_api, {:show_output, _}}, 100

      # A log channel: lines with their time and level. Printed text, and a
      # command's failure with where it was raised: the host's channel.
      run(root, "hello.log")
      run(root, "hello.broken")
      host = Bee.Output.host_channel()

      eventually(fn ->
        Bee.Output.get(root, "Hello Log") =~
          ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ \[info\] started \{"port":1\}\n.* \[error\] Error: boom\n\s+at /s and
          Bee.Output.get(root, host) =~ "printed by hello\n" and
          Bee.Output.get(root, host) =~
            ~r/command hello\.broken failed: Error: broken on purpose\n\s+at .*extension\.js/
      end)

      assert Bee.Output.channels(root) == ["Extension Host", "Hello", "Hello Log"]

      Bee.Output.clear(root, "Hello")
      assert_receive {:output, :cleared, "Hello"}
      assert Bee.Output.get(root, "Hello") == ""
    end

    test "API Bee doesn't have does nothing, and is listed", %{root: root} do
      run(root, "hello.unsupported")
      assert_receive {:bee_api, {:show_message, :info, "still running"}}, 5_000

      eventually(fn ->
        warnings = Plugins.get("hello", root).warnings

        "uses vscode.debug.registerDebugAdapterDescriptorFactory, which Bee doesn't have" in warnings and
          "uses vscode.TreeItem, which Bee doesn't have" in warnings
      end)

      assert status(root) == :active
    end

    test "a command that throws is reported, the extension goes on", %{root: root} do
      run(root, "hello.broken")
      assert_receive {:bee_api, {:show_message, :error, message}}, 5_000
      assert message == "Broken Enablement: broken on purpose"

      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, _}}, 5_000
    end

    test "when Node exits, the extensions start again in a new one", %{root: root} do
      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, _}}, 5_000
      host = Host.whereis(root)

      run(root, "hello.crash")
      eventually(fn -> Host.whereis(root) not in [nil, host] and status(root) == :active end)

      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, "Hello from the hello extension"}}, 5_000
    end

    test "stopping the host ends its Node.js process", %{root: root} do
      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, _}}, 5_000
      host = Host.whereis(root)
      os_pid = :sys.get_state(host).os_pid

      alive? = fn ->
        match?(
          {_, 0},
          System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true, cd: "/")
        )
      end

      assert alive?.()

      DynamicSupervisor.terminate_child(Bee.Extensions.HostSup, host)
      eventually(fn -> not alive?.() end)
    end

    test "without Node.js: its commands say so, its contributions stay", %{root: root} do
      :ok = Bee.Settings.update(:user, "extensions.nodePath", fn _ -> "/nonexistent/node" end)

      assert {:error, message} = run(root, "hello.sayHello")
      assert message =~ "needs Node.js, which wasn't found"
      assert %{status: :failed, errors: [%{message: ^message}]} = Plugins.get("hello", root)
      assert Bee.Commands.Registry.command("hello.sayHello")
      assert Bee.Settings.get("hello.volume") == 7
    end

    test "an extension that needs another runs when that one is there, after it", %{root: root} do
      # The hello extension, needing another one.
      file = Path.join([Plugins.user_dir(), "hello", "package.json"])

      package =
        file
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("extensionDependencies", ["bee-tests.base"])

      File.write!(file, Jason.encode!(package))
      File.write!(Path.join(root, ".hello"), "")
      Plugins.reload("hello")

      # Not installed: hello's code isn't started (it would fail on it), which
      # is no problem of the plugin's.
      Process.sleep(200)
      assert %{status: :inactive, errors: []} = Plugins.get("hello", root)
      assert {:error, message} = run(root, "hello.sayHello")

      assert message ==
               "hello's code isn't run: it needs the extension bee-tests.base, which isn't installed"

      base = Path.join(Plugins.user_dir(), "base")
      File.mkdir_p!(base)
      File.write!(Path.join(base, ".vsix.json"), "{}")

      File.write!(
        Path.join(base, "package.json"),
        Jason.encode!(%{name: "base", publisher: "Bee-Tests", main: "./main.js"})
      )

      File.write!(Path.join(base, "main.js"), "exports.activate = () => ({base: true})\n")
      Plugins.reload("base")
      Plugins.reload("hello")

      eventually(fn -> Plugins.get("hello", root).status == :active end)
      assert %{status: :active} = Plugins.get("base", root)

      # A dependency whose code doesn't run is as good as missing.
      :ok = Bee.Settings.update(:user, "extensions.disabledCode", fn _ -> ["base"] end)
      Plugins.reload("hello")
      assert {:error, message} = run(root, "hello.sayHello")
      assert message =~ "it needs the code of bee-tests.base, which Bee doesn't run"
    end

    test "extensions.disabledCode: its code doesn't run", %{root: root} do
      :ok = Bee.Settings.update(:user, "extensions.disabledCode", fn _ -> ["hello"] end)

      assert {:error, message} = run(root, "hello.sayHello")
      assert message =~ "switched off"
      assert %{status: :inactive, errors: []} = Plugins.get("hello", root)
      assert Host.whereis(root) == nil
    end
  end
end

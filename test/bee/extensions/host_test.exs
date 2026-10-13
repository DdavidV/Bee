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

    test "a terminal of its own: run by a window, typed into, closed; the environment it wants",
         %{root: root} do
      log = fn -> root |> Bee.Output.get("Extension Host") |> to_string() end
      run(root, "hello.terminal")

      # A window is asked to run it; the first to claim it does.
      assert_receive {:bee_api, {:create_terminal, host, id, spec}}, 5_000
      assert %{name: "Hello Shell", env: %{"HELLO_ONE" => "mine"}, shell: nil, args: []} = spec
      eventually(fn -> Host.terminal_env(root) == %{"HELLO_ALL" => "everywhere"} end)
      assert Host.claim_terminal(host, id)
      refute Host.claim_terminal(host, id)

      term = System.unique_integer([:positive])
      Phoenix.PubSub.subscribe(Bee.PubSub, Bee.Terminal.topic(term))

      {:ok, _pid} =
        Bee.Terminal.start(
          id: term,
          owner: self(),
          shell: "/bin/sh",
          cwd: root,
          env: Map.merge(Host.terminal_env(root), spec.env)
        )

      # What it sent before the shell ran goes in now; it was shown.
      Host.terminal_started(host, id, term)
      assert_receive {:bee_api, {:show_terminal, ^term}}, 5_000

      output = fn output, more ->
        receive do
          {:term_data, ^term, _seq, data} ->
            if output <> data =~ "mine-everywhere\r\n",
              do: :ok,
              else: more.(output <> data, more)
        after
          5_000 -> flunk("no output: #{inspect(output)}")
        end
      end

      output.("", output)
      eventually(fn -> log.() =~ "terminal Hello Shell runs: number, 1 listed, active true" end)

      # Disposed of: its window is to kill it. Gone, the extension is told.
      run(root, "hello.terminalClose")
      assert_receive {:bee_api, {:kill_terminal, ^term}}, 5_000
      eventually(fn -> log.() =~ "terminal Hello Shell closed, 0 left" end)

      # One that exits on its own is closed too.
      run(root, "hello.terminal", args: [false])
      assert_receive {:bee_api, {:create_terminal, ^host, id, _spec}}, 5_000
      assert Host.claim_terminal(host, id)
      second = System.unique_integer([:positive])
      {:ok, _pid} = Bee.Terminal.start(id: second, owner: self(), shell: "/bin/sh", cwd: root)
      Host.terminal_started(host, id, second)
      refute_receive {:bee_api, {:show_terminal, ^second}}, 100
      Bee.Terminal.input(second, "exit\n")

      eventually(fn ->
        length(Regex.scan(~r/terminal Hello Shell closed, 0 left/, log.())) == 2
      end)
    end

    test "a diff: a file beside a document of its own, in a tab; its buttons while it is shown",
         %{root: root, path: path} do
      log = fn -> root |> Bee.Output.get("Extension Host") |> to_string() end
      {:ok, _} = Bee.Editor.Buffer.open(path)
      on_exit(fn -> Bee.Editor.Buffer.close(path) end)
      run(root, "hello.diff", active_editor: path)

      # The window gets the tab: what differs, by line.
      assert_receive {:bee_api, {:open_diff, diff}}, 5_000
      assert %{id: id, title: "Shout ↔ notes", original: %{path: ^path}} = diff
      assert diff.modified.uri == "hello-proposed:" <> path

      assert diff.rows == [
               {:eq, 1, 1, "héllo 🐝 world"},
               {:del, 2, nil, "second line"},
               {:ins, nil, 2, "SECOND line"},
               {:ins, nil, 3, "added"}
             ]

      eventually(fn -> log.() =~ "diff open: true, 4 lines proposed" end)

      # Its tab shown: its modified side is a visible editor – the
      # extension's buttons are for then.
      refute Bee.UI.context(root)["hello.viewingDiff"]
      Host.diff(root, id, {:state, true})
      eventually(fn -> Bee.UI.context(root)["hello.viewingDiff"] == true end)
      Host.diff(root, id, {:state, false})
      eventually(fn -> Bee.UI.context(root)["hello.viewingDiff"] == false end)
      Host.diff(root, id, {:state, true})

      # Accepted: the extension writes the file and closes the tab.
      run(root, "hello.acceptDiff")
      assert_receive {:bee_api, {:close_diff, ^id}}, 5_000
      assert log.() =~ "accepting: active tab ours true"
      assert File.read!(path) == "héllo 🐝 world\nSECOND line\nadded\n"
      Host.diff(root, id, :closed)
      eventually(fn -> log.() =~ "diff tab closed: Shout ↔ notes" end)
      eventually(fn -> Bee.UI.context(root)["hello.viewingDiff"] == false end)
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

    test "a language status item is a status bar item, spinning while busy", %{root: root} do
      item = fn ->
        case Bee.UI.status_items(root) do
          [item] -> Map.take(item, [:owner, :text, :icon, :tooltip, :command, :alignment])
          none -> none
        end
      end

      run(root, "hello.languageStatus")

      eventually(fn ->
        item.() == %{
          owner: "hello",
          text: "HelloLS",
          icon: "$(loading~spin)",
          tooltip: "Starting language server… – Restart",
          command: "hello.sayHello",
          alignment: :right
        }
      end)

      run(root, "hello.languageStatus", args: ["running"])

      eventually(fn ->
        match?(
          %{text: "HelloLS v1", icon: nil, tooltip: "Language server running – Restart"},
          item.()
        )
      end)

      run(root, "hello.languageStatus", args: ["stopped"])

      eventually(fn ->
        match?(%{icon: "$(warning)", tooltip: "Language server stopped" <> _}, item.())
      end)

      run(root, "hello.languageStatus", args: ["gone"])
      eventually(fn -> item.() == [] end)
    end

    test "a command that throws is reported, the extension goes on", %{root: root} do
      run(root, "hello.broken")
      assert_receive {:bee_api, {:show_message, :error, message}}, 5_000
      assert message == "Broken Enablement: broken on purpose"

      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, _}}, 5_000
    end

    test "what it is busy with is progress, until done or cancelled", %{root: root} do
      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, _}}, 5_000

      run(root, "hello.progress")

      eventually(fn ->
        match?(
          [
            %{
              owner: "hello",
              title: "Building",
              message: "step 1",
              percent: 40,
              cancellable: true,
              toast: true
            }
          ],
          Bee.UI.progress(root)
        )
      end)

      [%{id: id}] = Bee.UI.progress(root)
      Host.cancel_progress(root, "hello", id)
      assert_receive {:bee_api, {:show_message, :warning, "cancelled"}}, 5_000
      eventually(fn -> Bee.UI.progress(root) == [] end)
    end

    test "progress left running ends with the host", %{root: root} do
      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, _}}, 5_000
      run(root, "hello.progress")
      eventually(fn -> Bee.UI.progress(root) != [] end)

      Plugins.reload()
      eventually(fn -> Bee.UI.progress(root) == [] end)
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

    test "a host that keeps stopping is given up on: an error notification", %{root: root} do
      :ok = Bee.Settings.update(:user, "extensions.maxStartFailures", fn _ -> 1 end)
      run(root, "hello.sayHello")
      assert_receive {:bee_api, {:show_message, :info, _}}, 5_000

      run(root, "hello.crash")
      assert_receive {:bee_api, {:show_message, :error, message}}, 5_000
      assert message =~ "The extension host stopped 1 times in a minute and isn't started again"
      assert message =~ "Not running: Hello"
      eventually(fn -> status(root) == :failed end)
      assert Host.whereis(root) == nil
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
      assert_receive {:bee_api, {:show_message, :error, notification}}
      assert notification =~ "needs Node.js, which wasn't found"
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

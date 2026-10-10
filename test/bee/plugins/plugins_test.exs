defmodule Bee.PluginsTest do
  # Plugins, settings and contributions are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bee.Commands.Registry, as: CommandRegistry
  alias Bee.Editor.Buffer
  alias Bee.Plugins
  alias Bee.Plugins.{Context, Host}

  @moduletag :capture_log

  @examples Path.expand("../../../examples/plugins", __DIR__)

  setup do
    dir = Plugins.user_dir()
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(root)
    # Plugins run for open workspaces; the test is its window.
    {:ok, ^root} = Bee.Workspace.open(root)

    Plugins.subscribe()
    Plugins.reload()

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(root)
      File.rm(Bee.Settings.user_path())
      File.rm_rf!(Path.dirname(Bee.Settings.workspace_path(Bee.Workspace.root())))
      Bee.Settings.reload()
      Plugins.reload()
    end)

    %{dir: dir, root: root}
  end

  describe "activation by the workspace's files (workspaceContains:)" do
    test "a plain path is looked up, a pattern matched against the files", %{root: root} do
      File.mkdir_p!(Path.join(root, "apps/web"))
      File.write!(Path.join(root, "apps/web/mix.exs"), "")
      File.write!(Path.join(root, "package.json"), "{}")

      wanted = [
        {"plain", ["package.json"]},
        {"missing", ["Cargo.toml"]},
        {"pattern", ["**/mix.exs"]},
        {"either", ["nope.txt", "apps/*/mix.exs"]},
        {"no-match", ["**/*.rs"]},
        {"outside", ["../../etc/passwd"]}
      ]

      assert Enum.sort(Bee.Plugins.Manager.workspace_contains(root, wanted)) ==
               ["either", "pattern", "plain"]
    end

    test "starts the plugin's server part in a workspace that has the file", %{root: root} do
      File.write!(Path.join(root, "marker.txt"), "")

      source = """
      defmodule BeeTestContains do
        use Bee.Plugin
        @impl true
        def activate(_ctx), do: {:ok, nil}
      end
      """

      for {name, glob, module} <- [
            {"contains", "marker.txt", "BeeTestContains"},
            {"contains-not", "other.txt", "BeeTestContainsNot"}
          ] do
        write_plugin(
          name,
          %{
            "server" => %{"module" => module},
            "activationEvents" => ["workspaceContains:" <> glob, "onSomething:else"],
            "contributes" => %{}
          },
          %{"lib/plugin.ex" => String.replace(source, "BeeTestContains", module)}
        )
      end

      Plugins.reload()

      wait_until(fn -> match?(%{status: :active}, Plugins.get("contains", root)) end)
      assert %{status: :inactive} = Plugins.get("contains-not", root)
    end
  end

  ## Helpers

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp install(example) do
    File.cp_r!(Path.join(@examples, example), Path.join(Plugins.user_dir(), example))
  end

  # A plugin from a manifest (map, encoded) and files (relative path => contents).
  defp write_plugin(name, manifest, files \\ %{}, base \\ Plugins.user_dir()) do
    dir = Path.join(base, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(Map.put(manifest, "name", name)))

    for {rel, contents} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, rel)))
      File.write!(Path.join(dir, rel), contents)
    end

    dir
  end

  defp server_command(id), do: %{"command" => id, "title" => id, "runtime" => "server"}

  defp await_status(name, status, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      case Plugins.get(name, Bee.Workspace.root()) do
        %{status: ^status} = plugin ->
          plugin

        other ->
          left = deadline - System.monotonic_time(:millisecond)

          if left <= 0,
            do: flunk("#{name}: expected #{status}, got #{inspect(other && other.status)}")

          receive do
            :plugins_changed -> nil
          after
            left -> nil
          end
      end
    end)
    |> Enum.find(& &1)
  end

  # Kills a plugin's host and waits until the manager has seen it go.
  defp kill_host(name) do
    pid = Host.whereis(name, Bee.Workspace.root())
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    :sys.get_state(Bee.Plugins.Manager)
    pid
  end

  defp ctx(fields \\ []),
    do: struct(Context, [window: self(), root: Bee.Workspace.root()] ++ fields)

  defp write_file(rel, text) do
    path = Path.join(Bee.Workspace.root(), rel)
    File.write!(path, text)
    path
  end

  defp open_buffer(path) do
    {:ok, _} = Buffer.open(path)
    on_exit(fn -> Buffer.close(path, self()) end)
  end

  ## Discovery and contributions

  test "discovers plugins and registers what they contribute, without starting them" do
    for example <- ~w(word-count upcase insert-date dotenv), do: install(example)
    Plugins.reload()

    assert Enum.map(Plugins.list(Bee.Workspace.root()), &{&1.name, &1.status}) == [
             {"dotenv", :inactive},
             {"insert-date", :inactive},
             {"upcase", :inactive},
             {"word-count", :inactive}
           ]

    assert %{handler: {:plugin, "word-count"}} = CommandRegistry.command("wordCount.count")
    assert %{runtime: :client, handler: nil} = CommandRegistry.command("insertDate.insert")
    assert Enum.any?(CommandRegistry.keybindings(), &(&1.command == "upcase.selection"))

    # languages and settings
    assert Bee.Languages.detect("/x/.env.local") == "dotenv"
    assert Bee.Languages.mode("dotenv") == "dotenv"
    assert Bee.Settings.get("wordCount.countNumbers") == true

    # browser parts
    assert [%{name: "dotenv", url: "/plugins/dotenv/browser.js?v=" <> _}, %{name: "insert-date"}] =
             Plugins.browser_modules(Bee.Workspace.root())

    assert {:ok, _, :module} = Plugins.asset_path("dotenv", "browser.js")
    assert :error = Plugins.asset_path("dotenv", "plugin.json")
    assert :error = Plugins.asset_path("word-count", "lib/word_count.ex")

    assert Host.whereis("word-count", Bee.Workspace.root()) == nil
  end

  test "removing a plugin removes its contributions and unloads its code" do
    install("word-count")
    Plugins.reload()
    :ok = Plugins.execute("word-count", "wordCount.count", ctx())
    await_status("word-count", :active)
    assert :code.is_loaded(WordCount)

    File.rm_rf!(Path.join(Plugins.user_dir(), "word-count"))
    Plugins.reload()

    assert Plugins.get("word-count", Bee.Workspace.root()) == nil
    assert CommandRegistry.command("wordCount.count") == nil
    refute :code.is_loaded(WordCount)
  end

  test "invalid manifests are reported, not loaded" do
    write_plugin("broken", %{"contributes" => %{"commands" => [%{"command" => "x"}]}})
    Plugins.reload()

    assert %{status: :invalid, errors: [%{message: message, path: path}]} =
             Plugins.get("broken", Bee.Workspace.root())

    assert message =~ ~s(broken: invalid manifest: missing "title", "runtime")
    assert path =~ "broken/plugin.json"
    assert [%{message: ^message}] = Plugins.errors(Bee.Workspace.root())
  end

  test "a plugin can't take another source's command id" do
    write_plugin("thief", %{
      "server" => %{"module" => "Thief"},
      "contributes" => %{"commands" => [server_command("workbench.action.togglePanel")]}
    })

    Plugins.reload()

    assert %{status: :invalid, errors: [%{message: message}]} =
             Plugins.get("thief", Bee.Workspace.root())

    assert message =~ "already defined"
    assert CommandRegistry.command("workbench.action.togglePanel").source == {:builtin, "bee"}
  end

  ## Server plugins

  test "an Elixir plugin runs commands in its own process and keeps its state" do
    install("word-count")
    Plugins.reload()
    path = write_file("a.txt", "one two three 4")

    :ok = Plugins.execute("word-count", "wordCount.count", ctx(active_editor: path))
    assert_receive {:bee_api, {:show_message, :info, "4 words in a.txt (counted 1×)"}}, 3_000
    assert %{status: :active} = await_status("word-count", :active)

    pid = Host.whereis("word-count", Bee.Workspace.root())
    :ok = Plugins.execute("word-count", "wordCount.count", ctx(active_editor: path))
    assert_receive {:bee_api, {:show_message, :info, "4 words in a.txt (counted 2×)"}}
    assert Host.whereis("word-count", Bee.Workspace.root()) == pid
  end

  test "plugin settings are validated and read by the plugin" do
    install("word-count")
    Plugins.reload()
    path = write_file("a.txt", "one two 3")

    File.write!(Bee.Settings.user_path(), ~s({"wordCount.countNumbers": "nope"}))
    Bee.Settings.reload()
    assert [%{message: ~s("wordCount.countNumbers": ) <> _}] = Bee.Settings.errors()

    File.write!(Bee.Settings.user_path(), ~s({"wordCount.countNumbers": false}))
    Bee.Settings.reload()

    :ok = Plugins.execute("word-count", "wordCount.count", ctx(active_editor: path))
    assert_receive {:bee_api, {:show_message, :info, "2 words in a.txt" <> _}}, 3_000
  end

  test "an Erlang plugin edits the open buffer through Bee.API" do
    install("upcase")
    Plugins.reload()
    path = write_file("b.txt", "hello wörld, bye")
    open_buffer(path)
    Buffer.subscribe()

    # "wörld" is 6 bytes; select "hello" and "wörld"
    ctx = ctx(active_editor: path, selections: [{0, 5}, {6, 12}])
    :ok = Plugins.execute("upcase", "upcase.selection", ctx)

    assert_receive {:buffer_edited, ^path, _version, [{0, 5, "HELLO"}, {6, 12, "WÖRLD"}], text},
                   3_000

    assert text == "HELLO WÖRLD, bye"
    assert Buffer.get(path).text == text

    :ok = Plugins.execute("upcase", "upcase.selection", %{ctx | selections: [{3, 3}]})
    assert_receive {:bee_api, {:show_message, :info, "Select some text first"}}
  end

  test "a failing command is reported and the plugin keeps running" do
    write_plugin(
      "flaky",
      %{
        "server" => %{"module" => "FlakyPlugin"},
        "contributes" => %{
          "commands" =>
            Enum.map(~w(flaky.raise flaky.sleep flaky.bad flaky.ok), &server_command/1)
        }
      },
      %{
        "lib/flaky.ex" => """
        defmodule FlakyPlugin do
          use Bee.Plugin

          @command "flaky.raise"
          def boom(_ctx, _state), do: raise "boom"

          @command "flaky.sleep"
          def nap(_ctx, _state), do: Process.sleep(:infinity)

          @command "flaky.bad"
          def bad(_ctx, _state), do: :what

          @command "flaky.ok"
          def fine(ctx, _state), do: Bee.API.set_status(ctx, "fine")
        end
        """
      }
    )

    Plugins.reload()

    :ok = Plugins.execute("flaky", "flaky.raise", ctx())
    assert_receive {:bee_api, {:show_message, :error, message}}, 3_000
    assert message =~ "flaky: command flaky.raise raised ** (RuntimeError) boom"

    :ok = Plugins.execute("flaky", "flaky.sleep", ctx())

    assert_receive {:bee_api,
                    {:show_message, :error, "flaky: command flaky.sleep timed out" <> _}},
                   2_000

    :ok = Plugins.execute("flaky", "flaky.bad", ctx())
    assert_receive {:bee_api, {:show_message, :error, message}}
    assert message =~ "returned :what"

    :ok = Plugins.execute("flaky", "flaky.ok", ctx())
    assert_receive {:bee_api, {:set_status, "fine"}}
    assert %{status: :active} = Plugins.get("flaky", Bee.Workspace.root())
  end

  test "a crashed host restarts, until it crashes too often" do
    install("word-count")
    Plugins.reload()
    :ok = Plugins.execute("word-count", "wordCount.count", ctx())
    await_status("word-count", :active)

    for _ <- 1..3 do
      pid = kill_host("word-count")
      await_status("word-count", :active)
      assert Host.whereis("word-count", Bee.Workspace.root()) not in [nil, pid]
    end

    kill_host("word-count")
    assert %{errors: [%{message: message}]} = await_status("word-count", :failed)
    assert message =~ "crashed 4 times in a minute"
    assert {:error, _} = Plugins.execute("word-count", "wordCount.count", ctx())
  end

  test "compile errors fail activation and point at the file" do
    write_plugin(
      "bad-code",
      %{
        "server" => %{"module" => "BadCode"},
        "contributes" => %{"commands" => [server_command("bad.run")]}
      },
      %{"lib/bad.ex" => "defmodule BadCode do\n  def x, do: nope()\nend\n"}
    )

    Plugins.reload()

    capture_io(:stderr, fn ->
      :ok = Plugins.execute("bad-code", "bad.run", ctx())
      assert %{errors: [error]} = await_status("bad-code", :failed)
      assert error.path =~ "bad-code/lib/bad.ex"
      assert error.message =~ "bad-code: line 2: undefined function nope/0"
    end)

    refute :code.is_loaded(BadCode)
  end

  test "Erlang compile errors and handler mismatches fail activation" do
    write_plugin(
      "bad-erl",
      %{
        "server" => %{"module" => "bad_erl"},
        "contributes" => %{"commands" => [server_command("bad.run")]}
      },
      %{"src/bad_erl.erl" => "-module(bad_erl).\n-export([f/2]).\nf(_, _) -> X.\n"}
    )

    write_plugin(
      "mismatch",
      %{
        "server" => %{"module" => "mismatch_erl"},
        "contributes" => %{"commands" => [server_command("mismatch.declared")]}
      },
      %{
        "src/mismatch_erl.erl" =>
          "-module(mismatch_erl).\n-export([f/2]).\n-command({<<\"mismatch.other\">>, f}).\nf(_, _) -> ok.\n"
      }
    )

    Plugins.reload()
    :ok = Plugins.execute("bad-erl", "bad.run", ctx())
    :ok = Plugins.execute("mismatch", "mismatch.declared", ctx())

    assert %{errors: [%{message: message}]} = await_status("bad-erl", :failed)
    assert message =~ "line 3: variable 'X' is unbound"

    assert %{errors: errors} = await_status("mismatch", :failed)

    assert Enum.map(errors, & &1.message) == [
             ~s(mismatch: no @command handler for "mismatch.declared"),
             ~s(mismatch: handler for undeclared command "mismatch.other")
           ]

    refute :code.is_loaded(:mismatch_erl)
  end

  test "plugins can't redefine existing modules" do
    write_plugin(
      "evil",
      %{
        "server" => %{"module" => "Bee.Settings"},
        "activationEvents" => ["*"],
        "contributes" => %{}
      },
      %{"lib/evil.ex" => "defmodule Bee.Settings do\n  def get(_), do: :pwned\nend\n"}
    )

    write_plugin(
      "evil-erl",
      %{"server" => %{"module" => "lists"}, "activationEvents" => ["*"], "contributes" => %{}},
      %{"src/lists.erl" => "-module(lists).\n"}
    )

    Plugins.reload()
    assert %{errors: [%{message: message}]} = await_status("evil", :failed)
    assert message =~ "module Bee.Settings already exists"
    assert %{errors: [%{message: message}]} = await_status("evil-erl", :failed)
    assert message =~ "module :lists already exists"
    assert Bee.Settings.get("editor.tabSize") == 2
  end

  test "activation events: * at startup, onLanguage when a file of the language opens" do
    write_plugin(
      "eager",
      %{
        "server" => %{"module" => "EagerPlugin"},
        "activationEvents" => ["*"],
        "contributes" => %{}
      },
      %{"lib/eager.ex" => "defmodule EagerPlugin do\n  use Bee.Plugin\nend\n"}
    )

    write_plugin(
      "md",
      %{
        "server" => %{"module" => "MdPlugin"},
        "activationEvents" => ["onLanguage:markdown"],
        "contributes" => %{}
      },
      %{"lib/md.ex" => "defmodule MdPlugin do\n  use Bee.Plugin\nend\n"}
    )

    Plugins.reload()
    await_status("eager", :active)
    assert Plugins.get("md", Bee.Workspace.root()).status == :inactive

    open_buffer(write_file("x.txt", "hi"))
    Process.sleep(50)
    assert Plugins.get("md", Bee.Workspace.root()).status == :inactive

    open_buffer(write_file("README.md", "# hi"))
    await_status("md", :active)
  end

  test "events reach handle_event/2 and messages handle_info/2" do
    write_plugin(
      "watcher",
      %{
        "server" => %{"module" => "WatcherPlugin"},
        "activationEvents" => ["*"],
        "contributes" => %{}
      },
      %{
        "lib/watcher.ex" => """
        defmodule WatcherPlugin do
          use Bee.Plugin

          @impl true
          def activate(ctx) do
            Process.send_after(ctx.host, :tick, 10)
            {:ok, ctx}
          end

          @impl true
          def handle_event({:buffer_saved, path}, ctx),
            do: Bee.API.show_message(ctx, :info, "saved " <> Path.basename(path))

          def handle_event(_event, _ctx), do: :ok

          @impl true
          def handle_info(:tick, ctx), do: Bee.API.set_status(ctx, "tick")
        end
        """
      }
    )

    Bee.API.subscribe_window(Bee.Workspace.root())
    Plugins.reload()
    await_status("watcher", :active)
    assert_receive {:bee_api, {:set_status, "tick"}}, 3_000

    path = write_file("c.txt", "")
    open_buffer(path)
    {:ok, _} = Buffer.save(path, "saved!")
    assert_receive {:bee_api, {:show_message, :info, "saved c.txt"}}, 3_000
  end

  test "plugins.disabled keeps a plugin from loading" do
    install("word-count")
    File.write!(Bee.Settings.user_path(), ~s({"plugins.disabled": ["word-count"]}))
    Bee.Settings.reload()
    Plugins.reload()

    assert %{status: :disabled} = Plugins.get("word-count", Bee.Workspace.root())
    assert CommandRegistry.command("wordCount.count") == nil
    assert {:error, _} = Plugins.execute("word-count", "wordCount.count", ctx())

    # re-enabled by a settings change alone
    File.write!(Bee.Settings.user_path(), ~s({}))
    Bee.Settings.reload()
    await_status("word-count", :inactive)
    assert CommandRegistry.command("wordCount.count")
  end

  test "workspace plugins load only when user settings allow it" do
    write_plugin(
      "local",
      %{"contributes" => %{"languages" => [%{"id" => "local-lang", "extensions" => [".loc"]}]}},
      %{},
      Plugins.workspace_dir(Bee.Workspace.root())
    )

    Plugins.reload()
    assert Plugins.get("local", Bee.Workspace.root()) == nil

    # a workspace can't allow itself
    File.mkdir_p!(Path.dirname(Bee.Settings.workspace_path(Bee.Workspace.root())))

    File.write!(
      Bee.Settings.workspace_path(Bee.Workspace.root()),
      ~s({"plugins.workspace.enabled": true})
    )

    Bee.Settings.reload()
    Plugins.reload()
    assert Plugins.get("local", Bee.Workspace.root()) == nil

    File.write!(Bee.Settings.user_path(), ~s({"plugins.workspace.enabled": true}))
    Bee.Settings.reload()
    Plugins.reload()
    assert %{scope: :workspace, status: :inactive} = Plugins.get("local", Bee.Workspace.root())
    assert Bee.Languages.detect("/x/a.loc") == "local-lang"
  end

  describe "workspaces" do
    setup do
      old = Application.get_env(:bee, :workspace_idle_ms)
      Application.put_env(:bee, :workspace_idle_ms, 30)

      other =
        Path.join(System.tmp_dir!(), "bee_plugins_other_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(other, ".bee"))
      File.write!(Bee.Settings.workspace_path(other), ~s({"editor.tabSize": 7}))

      Bee.API.subscribe_window(Bee.Workspace.root())
      Bee.API.subscribe_window(other)

      on_exit(fn ->
        if old,
          do: Application.put_env(:bee, :workspace_idle_ms, old),
          else: Application.delete_env(:bee, :workspace_idle_ms)

        File.rm_rf!(other)
      end)

      %{other: other}
    end

    defp eventually(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition not met")
        true -> Process.sleep(20) && eventually(fun, tries - 1)
      end
    end

    test "a plugin runs once per workspace, each copy in its own", %{root: root, other: other} do
      write_plugin(
        "where",
        %{
          "server" => %{"module" => "WherePlugin"},
          "activationEvents" => ["*"],
          "contributes" => %{"commands" => [server_command("where.am")]}
        },
        %{
          "lib/where.ex" => """
          defmodule WherePlugin do
            use Bee.Plugin

            @impl true
            def activate(ctx) do
              Bee.API.set_status_item(ctx, "where", %{text: Path.basename(ctx.root)})
              {:ok, ctx}
            end

            @command "where.am"
            def am(ctx, _ctx),
              do:
                Bee.API.show_message(
                  ctx,
                  "\#{Path.basename(Bee.API.workspace_root())} \#{Bee.API.setting("editor.tabSize")}"
                )

            @impl true
            def handle_event({:buffer_saved, path}, ctx),
              do: Bee.API.show_message(ctx, "\#{Path.basename(ctx.root)} saw \#{Path.basename(path)}")

            def handle_event(_event, _ctx), do: :ok
          end
          """
        }
      )

      Plugins.reload()
      await_status("where", :active)
      {:ok, ^other} = Bee.Workspace.open(other)
      eventually(fn -> match?(%{status: :active}, Plugins.get("where", other)) end)

      here = Path.basename(root)
      there = Path.basename(other)
      assert Host.whereis("where", root) != Host.whereis("where", other)
      assert [%{text: ^here}] = Bee.UI.status_items(root)
      assert [%{text: ^there}] = Bee.UI.status_items(other)

      # Commands run in the window's workspace, with its settings.
      :ok = Plugins.execute("where", "where.am", ctx(root: other))
      assert_receive {:bee_api, {:show_message, :info, message}}, 3_000
      assert message == "#{there} 7"
      :ok = Plugins.execute("where", "where.am", ctx())
      assert_receive {:bee_api, {:show_message, :info, message}}, 3_000
      assert message == "#{here} 2"

      # Events are the workspace's own.
      path = write_file("c.txt", "")
      open_buffer(path)
      {:ok, _} = Buffer.save(path, "saved")
      assert_receive {:bee_api, {:show_message, :info, message}}, 3_000
      assert message == "#{here} saw c.txt"
      refute_receive {:bee_api, {:show_message, :info, _}}, 100

      # Closing a workspace stops its copy and clears what it showed.
      pid = Host.whereis("where", root)
      Bee.Workspace.close(other)
      eventually(fn -> Host.whereis("where", other) == nil end)
      assert Bee.UI.status_items(other) == []
      assert Host.whereis("where", root) == pid
      assert %{status: :active} = Plugins.get("where", root)
    end

    test "a workspace plugin runs in its workspace only", %{other: other} do
      File.write!(Bee.Settings.user_path(), ~s({"plugins.workspace.enabled": true}))
      Bee.Settings.reload()

      write_plugin(
        "local",
        %{
          "server" => %{"module" => "LocalPlugin"},
          "contributes" => %{"commands" => [server_command("local.hi")]}
        },
        %{
          "lib/local.ex" => """
          defmodule LocalPlugin do
            use Bee.Plugin

            @command "local.hi"
            def hi(ctx, _state), do: Bee.API.show_message(ctx, "hi from \#{Path.basename(ctx.root)}")
          end
          """
        },
        Plugins.workspace_dir(other)
      )

      {:ok, ^other} = Bee.Workspace.open(other)
      eventually(fn -> Plugins.get("local", other) != nil end)
      assert %{scope: :workspace, workspace: ^other} = Plugins.get("local", other)
      assert Plugins.get("local", Bee.Workspace.root()) == nil

      :ok = Plugins.execute("local", "local.hi", ctx(root: other))
      expected = "hi from #{Path.basename(other)}"
      assert_receive {:bee_api, {:show_message, :info, ^expected}}, 3_000
      assert {:error, message} = Plugins.execute("local", "local.hi", ctx())
      assert message =~ "not loaded in"

      Bee.Workspace.close(other)
      eventually(fn -> Plugins.get("local") == nil end)
      refute :code.is_loaded(LocalPlugin)
    end
  end
end

defmodule Bee.Extensions.LanguagesTest do
  # Language features of extensions (vscode.languages): the hello-lang
  # fixture's code (test/fixtures/extensions/hello-lang) run in the
  # extension host, the test being its window.
  use ExUnit.Case, async: false

  alias Bee.Diagnostics
  alias Bee.Editor.Buffer
  alias Bee.Extensions.Host
  alias Bee.Languages.Features
  alias Bee.Plugins
  alias Bee.Plugins.Context

  @moduletag :capture_log

  test "positions (line, UTF-16 character) as byte offsets" do
    text = "aé🐝b\r\nsecond\n\nlast"

    at = fn line, character ->
      Host.position_to_bytes(text, %{"line" => line, "character" => character})
    end

    assert at.(0, 0) == 0
    # After the bee (2 units, 4 bytes).
    assert at.(0, 4) == 7
    # Past a line's end: its end, before the line break.
    assert at.(0, 99) == 8
    assert at.(1, 3) == 13
    assert at.(2, 0) == 17
    assert at.(3, 4) == byte_size(text)
    # Past the last line: the end.
    assert at.(9, 0) == byte_size(text)
  end

  describe "Bee.Diagnostics" do
    setup do
      on_exit(fn -> Diagnostics.clear("/ws") end)
    end

    test "a file's diagnostics are its owners', in file order; changes are told" do
      Diagnostics.subscribe("/ws")

      d = fn line, severity ->
        %{
          "from" => %{"line" => line, "character" => 0},
          "to" => %{"line" => line, "character" => 3},
          "severity" => severity,
          "message" => "m#{line}",
          "source" => "s",
          "code" => nil
        }
      end

      Diagnostics.put("/ws", "a/one", "/ws/x.ex", [
        d.(5, "warning"),
        d.(1, "error"),
        %{"nope" => 1}
      ])

      assert_receive {:diagnostics_changed, "/ws/x.ex"}
      Diagnostics.put("/ws", "b/two", "/ws/x.ex", [d.(3, "hint")])
      Diagnostics.put("/ws", "b/two", "/ws/y.ex", [d.(0, "bogus")])

      assert [
               %{
                 from: %{line: 1, character: 0},
                 to: %{character: 3},
                 severity: :error,
                 message: "m1",
                 source: "s",
                 code: nil,
                 owner: "a/one"
               },
               %{from: %{line: 3}, severity: :hint, owner: "b/two"},
               %{from: %{line: 5}, severity: :warning}
             ] = Diagnostics.for_file("/ws", "/ws/x.ex")

      # A severity Bee doesn't know is an error.
      assert %{"/ws/x.ex" => [_, _, _], "/ws/y.ex" => [%{severity: :error}]} =
               Diagnostics.all("/ws")

      assert Diagnostics.counts("/ws") == %{error: 2, warning: 1, hint: 1}
      assert Diagnostics.for_file("/other", "/ws/x.ex") == []

      # An owner's go when it sets none; an extension's, with it.
      Diagnostics.put("/ws", "a/one", "/ws/x.ex", [])
      assert [%{owner: "b/two"}] = Diagnostics.for_file("/ws", "/ws/x.ex")
      Diagnostics.clear("/ws", "b/")
      assert Diagnostics.all("/ws") == %{}
      assert_receive {:diagnostics_changed, "/ws/y.ex"}
    end
  end

  describe "with the hello-lang extension" do
    @describetag :node

    setup do
      root = Bee.Workspace.root()
      File.rm_rf!(root)
      File.mkdir_p!(Path.join(root, "skipped"))
      File.write!(Path.join(root, "a.hl"), "ok\nthis is BAD, very BAD\n# TODO later\nhint\n")
      File.write!(Path.join(root, "b.hl"), "also BAD\n")
      File.write!(Path.join(root, "skipped/c.hl"), "BAD\n")
      File.write!(Path.join(root, "notes.txt"), "BAD TODO\n")
      {:ok, ^root} = Bee.Workspace.open(root)

      File.rm_rf!(Plugins.user_dir())
      Bee.Test.Extensions.install("hello-lang")
      Bee.API.subscribe_window(root)
      Diagnostics.subscribe(root)

      on_exit(fn ->
        File.rm_rf!(Plugins.user_dir())
        Plugins.reload()
        File.rm_rf!(Path.join(Bee.Settings.user_dir(), "extension-state"))
        File.rm_rf!(root)
      end)

      %{root: root, a: Path.join(root, "a.hl"), b: Path.join(root, "b.hl")}
    end

    defp eventually(fun, tries \\ 150) do
      cond do
        result = fun.() -> result
        tries == 0 -> flunk("condition not met")
        true -> Process.sleep(20) && eventually(fun, tries - 1)
      end
    end

    defp run(root, command, opts \\ []) do
      ctx = struct(%Context{root: root, window: self()}, opts)
      Plugins.execute_extension("hello-lang", command, ctx)
    end

    test "opening a file of its language starts it; its diagnostics are the file's", %{
      root: root,
      a: a
    } do
      assert Plugins.get("hello-lang", root).status == :inactive
      {:ok, _} = Buffer.open(a)

      # (Found while it activates, before it has.)
      assert_receive {:diagnostics_changed, ^a}, 5_000
      eventually(fn -> Plugins.get("hello-lang", root).status == :active end)

      assert [bad, bad2, todo, hint] = Diagnostics.for_file(root, a)

      assert %{
               from: %{line: 1, character: 8},
               to: %{line: 1, character: 11},
               severity: :error,
               message: "BAD is bad\nUse GOOD instead.",
               source: "hello",
               code: "H001",
               owner: "hello-lang/hello/" <> _
             } = bad

      assert %{from: %{line: 1, character: 18}, severity: :error} = bad2

      assert %{
               from: %{line: 2, character: 2},
               severity: :warning,
               message: "something to do",
               code: nil
             } = todo

      assert %{
               from: %{line: 3, character: 0},
               to: %{line: 3, character: 4},
               severity: :hint,
               source: nil
             } = hint

      # Another language's file: not its business.
      {:ok, _} = Buffer.open(Path.join(root, "notes.txt"))
      Process.sleep(100)
      assert Map.keys(Diagnostics.all(root)) == [a]
    end

    test "they follow the text, and go when the file closes or the extension does", %{
      root: root,
      a: a,
      b: b
    } do
      {:ok, _} = Buffer.open(a)
      {:ok, _} = Buffer.open(b)
      eventually(fn -> map_size(Diagnostics.all(root)) == 2 end)

      Buffer.update(a, "all GOOD now\n")
      eventually(fn -> Diagnostics.for_file(root, a) == [] end)

      Buffer.update(a, "BAD again\n")

      eventually(fn ->
        match?([%{from: %{line: 0, character: 0}}], Diagnostics.for_file(root, a))
      end)

      Buffer.close(a)
      eventually(fn -> Diagnostics.for_file(root, a) == [] end)
      assert [_] = Diagnostics.for_file(root, b)

      Plugins.uninstall("hello-lang")
      eventually(fn -> Diagnostics.all(root) == %{} end)
    end

    test "a workspace edit changes open files in their buffers, others on disk", %{
      root: root,
      a: a,
      b: b
    } do
      {:ok, _} = Buffer.open(a)
      Buffer.subscribe()
      assert_receive {:diagnostics_changed, ^a}, 5_000

      run(root, "helloLang.fixAll")
      assert_receive {:bee_api, {:show_message, :info, "fixed 2 file(s): true"}}, 5_000

      # The open one: edited in its buffer (unsaved, undoable in its editors).
      assert_receive {:buffer_edited, ^a, _version, _edits, text}, 1_000
      assert text == "ok\nthis is GOOD, very GOOD\n# TODO later\nhint\n"
      assert File.read!(a) =~ "BAD"
      # The other: written. The excluded one: untouched. A file was created.
      assert File.read!(b) == "also GOOD\n"
      assert File.read!(Path.join(root, "skipped/c.hl")) == "BAD\n"
      assert File.read!(Path.join(root, "fixed.log")) == ""

      # Its diagnostics follow the edit.
      eventually(fn ->
        match?([%{severity: :warning}, %{severity: :hint}], Diagnostics.for_file(root, a))
      end)
    end

    test "tabs, all diagnostics, the version it sees", %{root: root, a: a, b: b} do
      {:ok, _} = Buffer.open(a)
      {:ok, _} = Buffer.open(b)
      eventually(fn -> map_size(Diagnostics.all(root)) == 2 end)

      run(root, "helloLang.report")
      assert_receive {:bee_api, {:show_message, :info, message}}, 5_000
      assert message =~ ~r/^2 tab\(s\), 5 diagnostic\(s\) in 2 file\(s\), vscode 1\.\d+\.\d+$/
    end

    test "file system watchers get the workspace's file changes", %{root: root, a: a} do
      {:ok, _} = Buffer.open(a)
      assert_receive {:diagnostics_changed, ^a}, 5_000

      # What the watcher (off in tests) would broadcast.
      tell = fn path -> Phoenix.PubSub.broadcast(Bee.PubSub, "fs", {:fs_changed, path}) end

      File.write!(Path.join(root, "new.hl"), "")
      tell.(Path.join(root, "new.hl"))
      eventually(fn -> "watched created new.hl" in Host.log(root) end)

      tell.(Path.join(root, "gone.hl"))
      eventually(fn -> "watched deleted gone.hl" in Host.log(root) end)

      File.touch!(Path.join(root, "b.hl"), System.os_time(:second) - 60)
      # (Its creation is a while ago for the file system only on some of them.)
      tell.(Path.join(root, "b.hl"))

      eventually(fn ->
        Enum.any?(Host.log(root), &(&1 =~ ~r/^watched (changed|created) b\.hl$/))
      end)

      # Not its pattern; not what the workspace hides.
      tell.(Path.join(root, "notes.txt"))
      tell.(Path.join(root, "_build/x.hl"))
      Process.sleep(100)
      refute Enum.any?(Host.log(root), &(&1 =~ "notes.txt" or &1 =~ "x.hl"))
    end

    # Asks for a feature as a window does, and waits for the answer.
    defp ask(root, feature, path, params) do
      ref = make_ref()
      :ok = Features.request(root, feature, path, params, {self(), ref})
      assert_receive {:language_reply, ^ref, reply}, 5_000
      reply
    end

    defp at(line, character), do: %{position: %{line: line, character: character}}

    defp started(root, path) do
      {:ok, _} = Buffer.open(path)
      eventually(fn -> Plugins.get("hello-lang", root).status == :active end)
      eventually(fn -> Features.for_file(root, path) != %{} end)
    end

    test "which features there are for a file follows what is registered", %{root: root, a: a} do
      Features.subscribe(root)
      assert Features.for_file(root, a) == %{}
      # Nobody to ask: no answer, not an error.
      assert ask(root, "hover", a, at(0, 0)) == {:ok, nil}

      started(root, a)
      assert_receive :language_features_changed

      assert %{
               "completion" => %{triggerCharacters: ["."]},
               "hover" => %{triggerCharacters: []},
               "definition" => %{}
             } = Features.for_file(root, a)

      assert Features.for_file(root, Path.join(root, "notes.txt")) == %{}

      Plugins.uninstall("hello-lang")
      eventually(fn -> Features.for_file(root, a) == %{} end)
    end

    test "completion: items, what resolving adds, the accepted one's command", %{
      root: root,
      a: a
    } do
      started(root, a)

      assert {:ok,
              %{"session" => session, "incomplete" => false, "items" => [good, header, shout]}} =
               ask(root, "completion", a, Map.put(at(0, 2), :context, %{triggerKind: 0}))

      assert %{
               "index" => 0,
               "label" => "GOOD",
               "kind" => "constant",
               "insertText" => "GOOD",
               "snippet" => false,
               "documentation" => nil,
               "resolvable" => true,
               "command" => false,
               "range" => nil
             } = good

      assert %{"label" => "header", "insertText" => "header!", "edits" => []} = header

      assert %{
               "label" => "shout",
               "kind" => "function",
               "insertText" => "SHOUT(${1:what})",
               "snippet" => true,
               "command" => true
             } = shout

      assert {:ok, %{"label" => "GOOD", "documentation" => "**GOOD** is good"}} =
               ask(root, "completionResolve", a, %{session: session, index: 0})

      # Plain text documentation is escaped; edits elsewhere come along.
      assert {:ok, %{"documentation" => "adds a \\*first\\* line", "edits" => [edit]}} =
               ask(root, "completionResolve", a, %{session: session, index: 1})

      assert edit == %{
               "from" => %{"line" => 0, "character" => 0},
               "to" => %{"line" => 0, "character" => 0},
               "text" => "# hello\n"
             }

      assert ask(root, "completionAccept", a, %{session: session, index: 2}) == {:ok, nil}
      eventually(fn -> "accepted shout" in Host.log(root) end)
      # An item that isn't there (any more).
      assert ask(root, "completionResolve", a, %{session: session, index: 9}) == {:ok, nil}
    end

    test "completion is about the buffer's text, with the character that asked", %{
      root: root,
      a: a
    } do
      started(root, a)
      Buffer.update(a, "greet.\n")

      assert {:ok, %{"items" => [hello, world]}} =
               ask(
                 root,
                 "completion",
                 a,
                 Map.put(at(0, 6), :context, %{triggerKind: 1, triggerCharacter: "."})
               )

      assert %{"label" => "hello", "kind" => "method", "info" => "trigger 1."} = hello

      assert %{
               "label" => "world",
               "detail" => "(name)",
               "description" => "greets",
               "insertText" => "world(${1:name})$0",
               "snippet" => true
             } = world

      # A character its provider didn't ask for.
      assert {:ok, %{"items" => []}} =
               ask(
                 root,
                 "completion",
                 a,
                 Map.put(at(0, 6), :context, %{triggerKind: 1, triggerCharacter: "("})
               )
    end

    test "hover: Markdown and the range it is about; a provider failing is none", %{
      root: root,
      a: a
    } do
      started(root, a)

      assert ask(root, "hover", a, at(1, 9)) ==
               {:ok,
                %{
                  "contents" => ["**BAD**: 3 letters"],
                  "range" => %{
                    "from" => %{"line" => 1, "character" => 8},
                    "to" => %{"line" => 1, "character" => 11}
                  }
                }}

      # Nothing there.
      Buffer.update(a, "one  two THROW\n")
      assert ask(root, "hover", a, at(0, 4)) == {:ok, nil}
      assert ask(root, "hover", a, at(0, 10)) == {:ok, nil}

      eventually(fn ->
        Enum.any?(Host.log(root), &(&1 =~ "hover failed: Error: no hover here"))
      end)

      # A file that isn't open, a feature nobody provides.
      assert ask(root, "hover", Path.join(root, "b.hl"), at(0, 0)) == {:ok, nil}
      assert ask(root, "implementation", a, at(0, 0)) == {:ok, []}
    end

    test "a request given up on is cancelled in the extension", %{root: root, a: a} do
      started(root, a)
      Buffer.update(a, "SLOW\n")
      ref = make_ref()
      :ok = Features.request(root, "hover", a, at(0, 1), {self(), ref})
      refute_receive {:language_reply, ^ref, _}, 200
      Features.cancel(root, ref)
      assert_receive {:language_reply, ^ref, {:ok, nil}}, 2_000
      eventually(fn -> "hover cancelled" in Host.log(root) end)
    end

    test "definition: the places in the workspace's files, each once", %{root: root, a: a, b: b} do
      File.write!(b, "also BAD\ndef twice\n")
      started(root, a)
      Buffer.update(a, "def once\ndef twice\nonce twice none\n")

      assert ask(root, "definition", a, at(2, 1)) ==
               {:ok,
                [
                  %{
                    "path" => a,
                    "from" => %{"line" => 0, "character" => 4},
                    "to" => %{"line" => 0, "character" => 8}
                  }
                ]}

      assert {:ok, places} = ask(root, "definition", a, at(2, 6))
      assert Enum.sort(Enum.map(places, &{&1["path"], &1["from"]["line"]})) == [{a, 1}, {b, 1}]
      assert ask(root, "definition", a, at(2, 12)) == {:ok, []}
    end

    test "formatting: one formatter's edits, of the file or of a range", %{root: root, a: a} do
      started(root, a)
      Buffer.update(a, "one   two  \nthree    four\nfive  \n")

      assert {:ok, %{"extension" => "hello-lang", "edits" => edits}} =
               ask(root, "formatting", a, %{options: %{tabSize: 4, insertSpaces: true}})

      assert edits == [
               %{
                 "from" => %{"line" => 0, "character" => 0},
                 "to" => %{"line" => 0, "character" => 11},
                 "text" => "one two"
               },
               %{
                 "from" => %{"line" => 1, "character" => 0},
                 "to" => %{"line" => 1, "character" => 13},
                 "text" => "three four"
               },
               %{
                 "from" => %{"line" => 2, "character" => 0},
                 "to" => %{"line" => 2, "character" => 6},
                 "text" => "five"
               }
             ]

      eventually(fn -> "formatting with tabSize 4" in Host.log(root) end)

      # A range: its lines only. The formatter asked for by its id, or (one
      # that isn't there) the one there is.
      range = %{from: %{line: 1, character: 2}, to: %{line: 1, character: 4}}

      for formatter <- ["bee-tests.hello-lang", "Nobody.Here", nil] do
        assert {:ok, %{"edits" => [%{"text" => "three four"}]}} =
                 ask(root, "rangeFormatting", a, %{range: range, formatter: formatter})
      end

      # Nothing to change; nobody to format.
      Buffer.update(a, "tidy\n")

      assert ask(root, "formatting", a, %{}) ==
               {:ok, %{"extension" => "hello-lang", "edits" => []}}

      notes = Path.join(root, "notes.txt")
      {:ok, _} = Buffer.open(notes)
      assert ask(root, "formatting", notes, %{}) == {:ok, nil}
    end

    test "signature help: the call's signatures and the parameter being typed", %{
      root: root,
      a: a
    } do
      started(root, a)
      assert %{"signatureHelp" => %{triggerCharacters: ["(", ","]}} = Features.for_file(root, a)
      Buffer.update(a, "greet.world(you, \nnothing here\n")

      assert {:ok, help} =
               ask(root, "signatureHelp", a, %{
                 position: %{line: 0, character: 12},
                 context: %{triggerKind: 2, triggerCharacter: "("}
               })

      assert help == %{
               "activeSignature" => 0,
               "activeParameter" => 0,
               "signatures" => [
                 %{
                   "label" => "world(name, loudly)",
                   "documentation" => "Greets the **world**.",
                   "activeParameter" => nil,
                   "parameters" => [
                     %{"label" => "name", "documentation" => "who to greet \\(asked by \\(\\)"},
                     %{"label" => [12, 18], "documentation" => "whether to shout"}
                   ]
                 }
               ]
             }

      assert {:ok, %{"activeParameter" => 1}} =
               ask(root, "signatureHelp", a, at(0, 17))

      # Not in a call.
      assert ask(root, "signatureHelp", a, at(1, 3)) == {:ok, nil}
    end

    test "references and highlights: every place a symbol is", %{root: root, a: a, b: b} do
      File.write!(b, "uses once\n")
      started(root, a)
      Buffer.update(a, "def once\nonce and once\n")

      assert {:ok, places} = ask(root, "references", a, at(1, 1))

      assert Enum.map(
               places,
               &{Path.basename(&1["path"]), &1["from"]["line"], &1["from"]["character"]}
             ) ==
               [{"a.hl", 0, 4}, {"a.hl", 1, 0}, {"a.hl", 1, 9}, {"b.hl", 0, 5}]

      assert {:ok, [_, _, _]} =
               ask(root, "references", a, Map.put(at(1, 1), :includeDeclaration, false))

      assert ask(root, "documentHighlight", a, at(1, 1)) ==
               {:ok,
                [
                  %{
                    "from" => %{"line" => 0, "character" => 4},
                    "to" => %{"line" => 0, "character" => 8},
                    "kind" => "write"
                  },
                  %{
                    "from" => %{"line" => 1, "character" => 0},
                    "to" => %{"line" => 1, "character" => 4},
                    "kind" => "read"
                  },
                  %{
                    "from" => %{"line" => 1, "character" => 9},
                    "to" => %{"line" => 1, "character" => 13},
                    "kind" => "read"
                  }
                ]}
    end

    test "symbols: a file's outline, flat; the workspace's by a query", %{root: root, a: a, b: b} do
      File.write!(b, "def other\n")
      started(root, a)
      Buffer.update(a, "def first\n  var inner\ntext\ndef second\n")

      assert {:ok, [first, inner, second]} = ask(root, "documentSymbol", a, %{})

      assert first == %{
               "name" => "first",
               "detail" => "definition",
               "kind" => "function",
               "container" => nil,
               "depth" => 0,
               "from" => %{"line" => 0, "character" => 4},
               "to" => %{"line" => 0, "character" => 9}
             }

      assert %{"name" => "inner", "kind" => "variable", "container" => "first", "depth" => 1} =
               inner

      assert %{"name" => "second", "depth" => 0, "from" => %{"line" => 3}} = second

      # Not about a file: no path. The open file as it is in its editor.
      assert {:ok, found} = ask(root, "workspaceSymbol", nil, %{query: "s"})

      assert Enum.sort(Enum.map(found, &{&1["name"], &1["container"], Path.basename(&1["path"])})) ==
               [{"first", "a.hl", "a.hl"}, {"second", "a.hl", "a.hl"}]

      assert {:ok,
              [%{"name" => "other", "kind" => "function", "path" => ^b, "from" => %{"line" => 0}}]} =
               ask(root, "workspaceSymbol", nil, %{query: "oth"})
    end

    test "rename: what is renamed, then every place, in open files and on disk", %{
      root: root,
      a: a,
      b: b
    } do
      File.write!(b, "uses once\n")
      started(root, a)
      Buffer.update(a, "def once\nonce BAD\n")
      Buffer.subscribe()

      assert ask(root, "prepareRename", a, at(1, 2)) ==
               {:ok,
                %{
                  "placeholder" => "once",
                  "from" => %{"line" => 1, "character" => 0},
                  "to" => %{"line" => 1, "character" => 4}
                }}

      # What its provider refuses, with its reason.
      assert ask(root, "prepareRename", a, at(1, 6)) ==
               {:ok, %{"error" => "BAD can't be renamed"}}

      assert ask(root, "rename", a, Map.put(at(1, 2), :newName, "not a name")) ==
               {:ok, %{"error" => "'not a name' isn't a name"}}

      assert ask(root, "rename", a, Map.put(at(1, 2), :newName, "twice")) ==
               {:ok, %{"applied" => true, "files" => 2, "edits" => 3}}

      # The open file: in its buffer, as one edit; the other: written.
      assert_receive {:buffer_edited, ^a, _version, [_, _], "def twice\ntwice BAD\n"}
      refute File.read!(a) =~ "twice"
      assert File.read!(b) == "uses twice\n"
    end

    test "code actions: for the diagnostics of a range; an edit resolved, a command run", %{
      root: root,
      a: a
    } do
      started(root, a)
      Buffer.update(a, "this is BAD here\nfine frozen\n")
      eventually(fn -> match?([_], Diagnostics.for_file(root, a)) end)
      Buffer.subscribe()
      line = fn n -> %{from: %{line: n, character: 0}, to: %{line: n, character: 99}} end

      assert {:ok, %{"session" => session, "actions" => [fix, shout]}} =
               ask(root, "codeAction", a, %{range: line.(0), context: %{triggerKind: 1}})

      assert fix == %{
               "index" => 0,
               "title" => "Replace with GOOD",
               "kind" => "quickfix",
               "preferred" => true,
               "disabled" => nil
             }

      assert %{"index" => 1, "title" => "Shout the line", "kind" => "refactor"} = shout

      # A line without the problem; one that can't be done; only quick fixes.
      assert {:ok,
              %{
                "actions" => [
                  %{"title" => "Shout the line"},
                  %{"title" => "Thaw", "disabled" => "too cold"}
                ]
              }} =
               ask(root, "codeAction", a, %{range: line.(1)})

      assert {:ok, %{"actions" => [%{"title" => "Replace with GOOD"}]}} =
               ask(root, "codeAction", a, %{range: line.(0), context: %{only: "quickfix"}})

      # The fix: its edit comes when it is resolved, and is applied.
      assert ask(root, "codeActionApply", nil, %{session: session, index: 0}) ==
               {:ok, %{"applied" => true}}

      assert_receive {:buffer_edited, ^a, _version, [_], "this is GOOD here\nfine frozen\n"}
      eventually(fn -> Diagnostics.for_file(root, a) == [] end)

      # The refactoring: its command runs.
      assert ask(root, "codeActionApply", nil, %{session: session, index: 1}) ==
               {:ok, %{"applied" => true}}

      assert_receive {:buffer_edited, ^a, _version, [_], "THIS IS GOOD HERE\nfine frozen\n"},
                     2_000

      assert {:ok, %{"error" => _}} =
               ask(root, "codeActionApply", nil, %{session: session, index: 9})
    end
  end
end

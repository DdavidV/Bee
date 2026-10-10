defmodule Bee.Plugins.VSCode.ManifestTest do
  use ExUnit.Case, async: true

  alias Bee.Plugins.VSCode.Manifest

  setup do
    dir =
      Path.join(System.tmp_dir!(), "bee_vscode_manifest_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp put(dir, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  test "a folder is an extension with the VSIX marker and a package.json", %{dir: dir} do
    refute Manifest.extension?(dir)
    put(dir, "package.json", "{}")
    refute Manifest.extension?(dir)
    put(dir, ".vsix.json", "{}")
    assert Manifest.extension?(dir)
  end

  test "name, texts from package.nls.json, version", %{dir: dir} do
    put(dir, "package.nls.json", ~s({"title": "Cool Things", "about": {"message": "So cool"}}))

    package = %{
      "name" => "Cool.Things",
      "displayName" => "%title%",
      "description" => "%about%",
      "version" => "1.2.3"
    }

    assert {:ok, manifest, []} = Manifest.from_package(package, dir)

    assert manifest == %{
             "name" => "cool-things",
             "displayName" => "Cool Things",
             "description" => "So cool",
             "version" => "1.2.3",
             "contributes" => %{}
           }

    # A text that isn't translated: the extension's name.
    assert {:ok, %{"displayName" => "x"}, []} =
             Manifest.from_package(%{"name" => "x", "displayName" => "%nope%"}, dir)

    assert {:error, "the extension has no name"} = Manifest.from_package(%{"name" => "!"}, dir)
  end

  test "reads the package.json of a folder", %{dir: dir} do
    assert {:error, "the extension has no package.json"} = Manifest.read(dir)
    put(dir, "package.json", "[]")
    assert {:error, "package.json is not a JSON object"} = Manifest.read(dir)
    # Comments are allowed.
    put(dir, "package.json", ~s({"name": "x" /* its name */}))
    assert {:ok, %{"name" => "x"}, []} = Manifest.read(dir)
  end

  test "keeps the entries Bee can use, and says why it left out the others", %{dir: dir} do
    put(dir, "syntaxes/a.json", "{}")
    put(dir, "snippets/a.json", "{}")
    put(dir, "lang.json", "{}")
    put(dir, "schema.json", "{}")

    package = %{
      "name" => "mixed",
      "contributes" => %{
        "languages" => [
          %{
            "id" => "a",
            "aliases" => ["A", 1],
            "extensions" => [".a", "a"],
            "configuration" => "./lang.json",
            "firstLine" => "^#!.*\\ba\\b",
            "icon" => %{"light" => "a.png"}
          },
          %{"id" => "b", "configuration" => "./missing.json", "firstLine" => "(?<!a"},
          %{"id" => "c d"},
          %{"aliases" => ["No id"]},
          "nope"
        ],
        "grammars" => [
          %{
            "language" => "a",
            "scopeName" => "source.a",
            "path" => "./syntaxes/a.json",
            "embeddedLanguages" => %{"meta.embedded.js" => "javascript", "x" => 1}
          },
          %{"scopeName" => "source.b", "path" => "./syntaxes/b.json"},
          %{"language" => "c"}
        ],
        "snippets" => [
          %{"language" => "a", "path" => "./snippets/a.json"},
          %{"path" => "./snippets/a.json"},
          %{"language" => "a", "path" => "../outside.json"}
        ],
        "jsonValidation" => [
          %{"fileMatch" => "a.json", "url" => "./schema.json"},
          %{"fileMatch" => ["b.json"], "url" => "https://example.com/b.json"},
          %{"fileMatch" => "c.json", "url" => "./missing.json"},
          %{"fileMatch" => [], "url" => "./schema.json"}
        ],
        "themes" => [
          %{"label" => "Dark", "uiTheme" => "vs-dark", "path" => "./t.json", "extra" => 1},
          %{"label" => "Sepia", "uiTheme" => "sepia", "path" => "./t.json"},
          %{"label" => "No file", "uiTheme" => "vs"}
        ],
        "commands" => [%{"command" => "mixed.run", "title" => "No code to run it"}]
      }
    }

    assert {:ok, %{"contributes" => contributes}, warnings} = Manifest.from_package(package, dir)

    assert contributes == %{
             "languages" => [
               %{
                 "id" => "a",
                 "aliases" => ["A"],
                 "extensions" => [".a"],
                 "configuration" => "./lang.json",
                 "firstLine" => "^#!.*\\ba\\b"
               },
               %{"id" => "b"}
             ],
             "grammars" => [
               %{
                 "language" => "a",
                 "scopeName" => "source.a",
                 "path" => "./syntaxes/a.json",
                 "embeddedLanguages" => %{"meta.embedded.js" => "javascript"}
               }
             ],
             "snippets" => [
               %{"language" => "a", "path" => "./snippets/a.json"},
               %{"path" => "./snippets/a.json"}
             ],
             "jsonValidation" => [
               %{"fileMatch" => ["a.json"], "url" => "./schema.json"},
               %{"fileMatch" => ["b.json"], "url" => "https://example.com/b.json"}
             ],
             "themes" => [%{"label" => "Dark", "uiTheme" => "vs-dark", "path" => "./t.json"}]
           }

    assert warnings == [
             "contributes.commands[0] (mixed.run) needs the extension's code, and it has no main",
             ~s(contributes.languages[2] has the id "c d", which Bee can't use),
             "contributes.languages[3] has no id",
             "contributes.languages[4] is not an object",
             "contributes.grammars[1] names the file ./syntaxes/b.json, which the extension doesn't have",
             "contributes.grammars[2] needs a scopeName and a path",
             "contributes.snippets[2] names the file ../outside.json, which the extension doesn't have",
             "contributes.jsonValidation[2] names the file ./missing.json, which the extension doesn't have",
             "contributes.jsonValidation[3] has no fileMatch",
             ~s(contributes.themes[1] has the uiTheme "sepia", which Bee doesn't know),
             "contributes.themes[2] needs a label, a uiTheme and a path"
           ]

    # What it gives is a valid Bee manifest.
    assert :ok =
             Bee.JSON.Schema.validate("manifest", "#", %{
               "name" => "mixed",
               "contributes" => contributes
             })
  end

  describe "the hello fixture extension" do
    setup do
      dir = Bee.Test.Extensions.fixture("hello")
      {:ok, manifest, warnings} = Manifest.read(dir)
      %{dir: dir, manifest: manifest, contributes: manifest["contributes"], warnings: warnings}
    end

    test "is a valid manifest with an extension part", %{manifest: manifest, dir: dir} do
      assert :ok = Bee.JSON.Schema.validate("manifest", "#", manifest)
      assert {:ok, _data} = Bee.Contributions.normalize({:plugin, "hello"}, manifest, dir: dir)

      assert manifest["displayName"] == "Hello Extension"
      assert manifest["extension"] == %{"main" => "./extension.js"}

      assert manifest["activationEvents"] == [
               "onCommand:hello.sayHello",
               "workspaceContains:**/.hello"
             ]
    end

    test "commands: titles, icons, enablement", %{contributes: contributes, warnings: warnings} do
      commands = Map.new(contributes["commands"], &{&1["command"], &1})

      assert commands["hello.sayHello"] == %{
               "command" => "hello.sayHello",
               "title" => "Say Hello",
               "category" => "Hello",
               "icon" => "$(megaphone)",
               "runtime" => "extension"
             }

      assert %{
               "title" => "Shout Selection",
               "enablement" => "editorHasSelection",
               "icon" => %{"light" => "./media/shout-light.svg", "dark" => "media/shout-dark.svg"}
             } = commands["hello.shout"]

      # An enablement Bee can't read: the command stays, always enabled.
      assert commands["hello.broken"] == %{
               "command" => "hello.broken",
               "title" => "Broken Enablement",
               "runtime" => "extension"
             }

      assert Map.keys(commands) |> Enum.sort() ==
               ~w(hello.broken hello.insert hello.pick hello.reveal hello.sayHello hello.shout)

      assert "contributes.commands[5] has an enablement Bee can't read, left out: " <> _ =
               Enum.find(warnings, &(&1 =~ "commands[5]"))

      assert ~s(contributes.commands[6] has the id "hello bad id", which Bee can't use) in warnings
      assert "contributes.commands[7] (hello.untitled) has no title" in warnings
    end

    test "keybindings: platforms, arguments, keys Bee can't bind", %{
      contributes: contributes,
      warnings: warnings
    } do
      assert contributes["keybindings"] == [
               %{"command" => "hello.sayHello", "key" => "ctrl+alt+h", "mac" => "cmd+alt+h"},
               %{
                 "command" => "hello.shout",
                 "key" => "ctrl+alt+u",
                 "linux" => "ctrl+alt+shift+u",
                 "when" => "editorTextFocus"
               },
               %{
                 "command" => "hello.insert",
                 "key" => "ctrl+alt+[KeyI]",
                 "args" => %{"text" => "inserted"}
               },
               %{"command" => "hello.pick", "mac" => "cmd+alt+p"},
               # A command of Bee's (or of nobody's: then it does nothing).
               %{"command" => "workbench.action.togglePanel", "key" => "ctrl+alt+oem_3"}
             ]

      assert Enum.any?(warnings, &(&1 =~ "keybindings[5] (hello.pick) has a key Bee can't bind"))

      assert "contributes.keybindings[6] (hello.pick) has a when clause Bee can't read" in warnings
    end

    test "menus and submenus", %{contributes: contributes, warnings: warnings} do
      assert contributes["submenus"] == [
               %{"id" => "hello.more", "label" => "More Greetings"},
               %{"id" => "hello.empty", "label" => "Empty"}
             ]

      assert contributes["menus"]["editor/context"] == [
               %{"command" => "hello.sayHello", "group" => "navigation@1"},
               # Orders are whole numbers.
               %{
                 "command" => "hello.shout",
                 "group" => "1_modification@3",
                 "when" => "editorHasSelection"
               },
               %{"submenu" => "hello.more", "group" => "1_modification@3"},
               %{"submenu" => "hello.empty", "group" => "1_modification@4"},
               %{"command" => "hello.pick", "when" => "resourceLangId == nope"}
             ]

      # `alt` isn't used.
      assert contributes["menus"]["hello.more"] == [
               %{"command" => "hello.pick", "group" => "a@1"},
               %{"command" => "hello.insert", "group" => "b"}
             ]

      # A menu Bee doesn't draw is kept all the same.
      assert contributes["menus"]["scm/title"] == [%{"command" => "hello.sayHello"}]

      assert "contributes.menus.editor/context[5] (hello.pick) has a when clause Bee can't read" in warnings
    end

    test "settings: sections, descriptions, schemas Bee can't use, defaults", %{
      contributes: contributes,
      warnings: warnings
    } do
      assert [%{"title" => "Hello", "order" => 1} = hello, %{"title" => "Hello: Advanced"}] =
               contributes["configuration"]

      assert hello["properties"]["hello.greeting"]["description"] == "What it says."
      assert hello["properties"]["hello.volume"]["maximum"] == 11

      # No schema to check values with.
      assert hello["properties"]["hello.colors"] == %{
               "default" => %{},
               "description" => "Schema from VS Code."
             }

      refute Map.has_key?(hello["properties"], "hello")

      assert "contributes.configuration[0] hello is a name Bee can't use" in warnings

      assert "contributes.configuration[0] hello.colors has a schema Bee can't use: its values aren't checked" in warnings

      assert contributes["configurationDefaults"] == %{
               "editor.tabSize" => 3,
               "hello.volume" => 7,
               "files.exclude" => %{"**/.hello-cache" => true},
               "[plaintext]" => %{"editor.wordWrap" => "on"}
             }

      assert length(warnings) == 8
    end
  end

  test "a bee section adds a server and a browser part", %{dir: dir} do
    package = %{
      "name" => "hybrid",
      "main" => "./out/extension.js",
      "bee" => %{
        "server" => %{"module" => "Hybrid"},
        "browser" => "bee/browser.js",
        "other" => true
      }
    }

    assert {:ok, manifest, []} = Manifest.from_package(package, dir)
    assert manifest["extension"] == %{"main" => "./out/extension.js"}
    assert manifest["server"] == %{"module" => "Hybrid"}
    assert manifest["browser"] == "bee/browser.js"
    refute Map.has_key?(manifest, "other")
    assert :ok = Bee.JSON.Schema.validate("manifest", "#", manifest)
  end
end

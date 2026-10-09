defmodule Bee.Languages.ConfigurationTest do
  # Plugins' language configurations (language-configuration.json), as
  # Bee.Languages reads them for the editor. Plugins are global.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bee.Languages
  alias Bee.Plugins

  @moduletag :capture_log

  setup do
    dir = Plugins.user_dir()
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Plugins.reload()
    end)

    %{dir: dir}
  end

  defp plugin(dir, name, languages, files) do
    folder = Path.join(dir, name)
    File.mkdir_p!(folder)
    for {rel, text} <- files, do: File.write!(Path.join(folder, rel), text)

    File.write!(
      Path.join(folder, "plugin.json"),
      Jason.encode!(%{"name" => name, "contributes" => %{"languages" => languages}})
    )

    Plugins.reload()
    Plugins.get(name)
  end

  # VS Code's own format: comments allowed, pairs as lists or objects,
  # regexes as strings or {pattern, flags}.
  @configuration """
  {
    // as in VS Code's extensions
    "comments": {"lineComment": "#", "blockComment": ["/*", "*/"]},
    "brackets": [["(", ")"], ["do", "end"], ["bad"]],
    "autoClosingPairs": [["(", ")"], {"open": "\\"", "close": "\\"", "notIn": ["string"]}, "bad"],
    "surroundingPairs": [["(", ")"]],
    "autoCloseBefore": ";:.,=}])> \\n\\t",
    "indentationRules": {
      "increaseIndentPattern": "\\\\bdo\\\\s*$",
      "decreaseIndentPattern": {"pattern": "^\\\\s*end\\\\b", "flags": "i"},
      "unknownPattern": "x"
    },
    "onEnterRules": [
      {"beforeText": "^\\\\s*#", "action": {"indent": "none", "appendText": "# "}},
      {"beforeText": "x", "action": {"indent": "sideways"}}
    ],
    "folding": {"markers": {"start": "^\\\\s*#region", "end": "^\\\\s*#endregion"}},
    "wordPattern": "\\\\w+"
  }
  """

  test "a plugin's language configuration, normalized for the editor", %{dir: dir} do
    plugin(
      dir,
      "tml",
      [
        %{
          "id" => "tml",
          "extensions" => [".tml"],
          "configuration" => "./language-configuration.json"
        }
      ],
      %{"language-configuration.json" => @configuration}
    )

    assert %{errors: []} = Plugins.get("tml")

    assert Languages.configuration("tml") == %{
             "comments" => %{"lineComment" => "#", "blockComment" => ["/*", "*/"]},
             "brackets" => [["(", ")"], ["do", "end"]],
             "autoClosingPairs" => [
               %{"open" => "(", "close" => ")"},
               %{"open" => "\"", "close" => "\"", "notIn" => ["string"]}
             ],
             "surroundingPairs" => [%{"open" => "(", "close" => ")"}],
             "autoCloseBefore" => ";:.,=}])> \n\t",
             "indentationRules" => %{
               "increaseIndentPattern" => %{"pattern" => "\\bdo\\s*$", "flags" => ""},
               "decreaseIndentPattern" => %{"pattern" => "^\\s*end\\b", "flags" => "i"}
             },
             "onEnterRules" => [
               %{
                 "beforeText" => %{"pattern" => "^\\s*#", "flags" => ""},
                 "action" => %{"indent" => "none", "appendText" => "# "}
               }
             ],
             "folding" => %{
               "markers" => %{
                 "start" => %{"pattern" => "^\\s*#region", "flags" => ""},
                 "end" => %{"pattern" => "^\\s*#endregion", "flags" => ""}
               }
             }
           }

    assert Languages.configuration("elixir") == nil
  end

  test "the last one contributed for a language wins", %{dir: dir} do
    plugin(dir, "a", [%{"id" => "elixir", "configuration" => "c.json"}], %{
      "c.json" => ~s({"comments": {"lineComment": "#a"}})
    })

    plugin(dir, "b", [%{"id" => "elixir", "configuration" => "c.json"}], %{
      "c.json" => ~s({"comments": {"lineComment": "#b"}})
    })

    assert %{"comments" => %{"lineComment" => "#b"}} = Languages.configuration("elixir")
  end

  test "a configuration that can't be read is the plugin's problem", %{dir: dir} do
    missing = plugin(dir, "missing", [%{"id" => "m", "configuration" => "nope.json"}], %{})
    assert [%{message: message}] = missing.errors
    assert message =~ "language m: configuration nope.json: no such file or directory"

    bad = plugin(dir, "bad", [%{"id" => "b", "configuration" => "c.json"}], %{"c.json" => "[1]"})
    assert [%{message: message}] = bad.errors
    assert message =~ "language b: configuration c.json is not a JSON object"

    outside =
      plugin(dir, "outside", [%{"id" => "o", "configuration" => "../bad/c.json"}], %{})

    assert [%{message: message}] = outside.errors
    assert message =~ "language o: configuration must be inside the plugin"
  end

  test "the editor gets a file's configuration with its highlighting", %{conn: conn, dir: dir} do
    plugin(
      dir,
      "tml",
      [%{"id" => "tml", "extensions" => [".tml"], "configuration" => "c.json"}],
      %{
        "c.json" => ~s({"comments": {"lineComment": "#"}})
      }
    )

    root = Bee.Workspace.root()
    File.mkdir_p!(root)
    file = Path.join(root, "a.tml")
    File.write!(file, "x")
    on_exit(fn -> File.rm(file) end)

    {:ok, view, _html} = live(conn, "/")

    render_hook(view, "run_command", %{
      "command" => "bee.openFile",
      "args" => Jason.encode!([file])
    })

    assert_push_event(view, "cm:open", %{
      lang: "tml",
      config: %{"comments" => %{"lineComment" => "#"}}
    })
  end

  test "a VSIX's language configuration is installed with it" do
    package = %{
      "name" => "tml-lang",
      "contributes" => %{
        "languages" => [
          %{
            "id" => "tml",
            "extensions" => [".tml"],
            "configuration" => "./language-configuration.json"
          },
          %{"id" => "gone", "configuration" => "./missing.json"}
        ]
      }
    }

    tmp = Path.join(System.tmp_dir!(), "bee-lc-#{System.unique_integer([:positive])}.vsix")

    {:ok, _} =
      :zip.create(String.to_charlist(tmp), [
        {~c"extension/package.json", Jason.encode!(package)},
        {~c"extension/language-configuration.json", ~s({"comments": {"lineComment": "--"}})}
      ])

    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, "tml-lang"} = Bee.Plugins.Vsix.install(tmp)
    assert %{errors: []} = Plugins.get("tml-lang")
    assert %{"comments" => %{"lineComment" => "--"}} = Languages.configuration("tml")
    assert Languages.configuration("gone") == nil
  end
end

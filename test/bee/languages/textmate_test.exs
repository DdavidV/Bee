defmodule Bee.Languages.TextMateTest do
  # TextMate grammars contributed by plugins (Bee.Languages), served to the
  # browser, and installed from a VSIX. Plugins are global.
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

  @grammar ~s({"scopeName": "source.tmt", "patterns": [{"match": "\\\\bdef\\\\b", "name": "keyword.control.tmt"}]})

  defp plugin(dir, name, contributes, files \\ %{}) do
    folder = Path.join(dir, name)

    for {rel, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(folder, rel)))
      File.write!(Path.join(folder, rel), text)
    end

    File.mkdir_p!(folder)

    File.write!(
      Path.join(folder, "plugin.json"),
      Jason.encode!(%{"name" => name, "contributes" => contributes})
    )

    Plugins.reload()
    Plugins.get(name)
  end

  test "a plugin's TextMate grammar highlights its language", %{dir: dir} do
    plugin(
      dir,
      "tmt",
      %{
        "languages" => [%{"id" => "tmt", "extensions" => [".tmt"]}],
        "grammars" => [
          %{"language" => "tmt", "scopeName" => "source.tmt", "path" => "./syntaxes/tmt.json"},
          %{
            "scopeName" => "text.injected.tmt",
            "path" => "syntaxes/Injected Thing.tmLanguage",
            "injectTo" => ["source.tmt"]
          }
        ]
      },
      %{"syntaxes/tmt.json" => @grammar, "syntaxes/Injected Thing.tmLanguage" => "<plist/>"}
    )

    assert %{status: :inactive, errors: []} = Plugins.get("tmt")
    assert Languages.detect("/x/a.tmt") == "tmt"
    assert Languages.highlight("tmt") == %{scope: "source.tmt"}
    assert Languages.mode("tmt") == nil

    assert %{
             "source.tmt" => %{
               scope: "source.tmt",
               url: "/plugins/tmt/syntaxes/tmt.json",
               injectTo: [],
               language: "tmt"
             },
             "text.injected.tmt" => %{
               url: "/plugins/tmt/syntaxes/Injected%20Thing.tmLanguage",
               injectTo: ["source.tmt"],
               language: nil
             }
           } = Languages.grammars()

    # Served: its grammars, not its other files.
    folder = Path.join(dir, "tmt")
    assert {:ok, _, :grammar} = Plugins.asset_path("tmt", "syntaxes/tmt.json")
    assert :error = Plugins.asset_path("tmt", "plugin.json")

    conn = get(build_conn(), "/plugins/tmt/syntaxes/tmt.json")
    assert conn.status == 200
    assert conn.resp_body == @grammar
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    conn = get(build_conn(), "/plugins/tmt/syntaxes/Injected%20Thing.tmLanguage")
    assert conn.resp_body == "<plist/>"

    # Disabled: not served.
    :ok = Plugins.set_enabled("tmt", false)
    Plugins.reload()
    assert Languages.grammars() == %{}
    assert :error = Plugins.asset_path("tmt", "syntaxes/tmt.json")
    :ok = Plugins.set_enabled("tmt", true)
    assert File.dir?(folder)
  after
    Bee.Settings.update(:user, "plugins.disabled", fn _ -> [] end)
  end

  test "a TextMate grammar replaces Bee's CodeMirror mode for a language", %{dir: dir} do
    assert Languages.highlight("erlang") == %{mode: "erlang"}

    plugin(
      dir,
      "erlang-tm",
      %{
        "grammars" => [
          %{"language" => "erlang", "scopeName" => "source.erlang", "path" => "e.json"}
        ]
      },
      %{"e.json" => "{}"}
    )

    assert Languages.highlight("erlang") == %{scope: "source.erlang"}

    File.rm_rf!(Path.join(dir, "erlang-tm"))
    Plugins.reload()
    assert Languages.highlight("erlang") == %{mode: "erlang"}
  end

  test "a grammar must be a file inside its plugin", %{dir: dir} do
    missing =
      plugin(dir, "missing", %{
        "grammars" => [%{"scopeName" => "source.x", "path" => "nope.json"}]
      })

    assert [%{message: message}] = missing.errors
    assert message =~ "grammar source.x: no file nope.json"

    outside =
      plugin(dir, "outside", %{
        "grammars" => [%{"scopeName" => "source.y", "path" => "../missing/plugin.json"}]
      })

    assert [%{message: message}] = outside.errors
    assert message =~ "grammar source.y: path must be inside the plugin"
    assert Languages.grammars() == %{}
  end

  test "a VSIX's languages and grammars are installed", %{dir: _dir} do
    package = %{
      "name" => "erlang-ls",
      "version" => "0.0.39",
      "contributes" => %{
        "languages" => [
          %{
            "id" => "erlang",
            "aliases" => ["Erlang"],
            "extensions" => [".erl", ".hrl", "bad"],
            "configuration" => "./language-configuration.json",
            "firstLine" => "(?<!x"
          }
        ],
        "grammars" => [
          %{
            "language" => "erlang",
            "scopeName" => "source.erlang",
            "path" => "./grammar/Erlang.plist"
          },
          %{"scopeName" => "source.gone", "path" => "./grammar/gone.json"}
        ],
        "commands" => [%{"command" => "erlang.x", "title" => "X"}]
      }
    }

    tmp = Path.join(System.tmp_dir!(), "bee-tm-#{System.unique_integer([:positive])}.vsix")

    {:ok, _} =
      :zip.create(String.to_charlist(tmp), [
        {~c"extension/package.json", Jason.encode!(package)},
        {~c"extension/grammar/Erlang.plist", "<plist/>"}
      ])

    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, "erlang-ls"} = Bee.Plugins.Vsix.install(tmp)
    assert %{errors: []} = Plugins.get("erlang-ls")

    manifest = Plugins.get("erlang-ls").manifest

    assert manifest["contributes"] == %{
             "languages" => [
               %{"id" => "erlang", "aliases" => ["Erlang"], "extensions" => [".erl", ".hrl"]}
             ],
             "grammars" => [
               %{
                 "language" => "erlang",
                 "scopeName" => "source.erlang",
                 "path" => "./grammar/Erlang.plist"
               }
             ]
           }

    assert Languages.highlight("erlang") == %{scope: "source.erlang"}
    assert Languages.detect("/x/a.hrl") == "erlang"
  end

  test "token colors: the theme's, else VS Code's defaults for its base" do
    dark = Bee.ColorThemes.Theme.plain(%{id: "dark", label: "Dark", base: :dark})
    assert [%{"settings" => editor} | rules] = Bee.ColorThemes.Theme.token_colors(dark)
    assert editor == %{"foreground" => "#d4d4d4", "background" => "#1e1e1e"}
    assert Enum.any?(rules, &(&1["scope"] == "comment"))

    light = Bee.ColorThemes.Theme.plain(%{id: "light", label: "Light", base: :light})

    assert [%{"settings" => %{"foreground" => "#000000"}} | _] =
             Bee.ColorThemes.Theme.token_colors(light)

    own =
      Bee.ColorThemes.Theme.new(%{id: "own", label: "Own", base: :dark}, %{
        colors: %{"editor.foreground" => "#abcdef"},
        token_colors: [%{"scope" => "keyword", "settings" => %{"foreground" => "#ff0000"}}]
      })

    assert Bee.ColorThemes.Theme.token_colors(own) == [
             %{"settings" => %{"foreground" => "#abcdef", "background" => "#1e1e1e"}},
             %{"scope" => "keyword", "settings" => %{"foreground" => "#ff0000"}}
           ]
  end

  test "the editor gets the grammars, and a file's scope", %{conn: conn, dir: dir} do
    plugin(
      dir,
      "tmt",
      %{
        "languages" => [%{"id" => "tmt", "extensions" => [".tmt"]}],
        "grammars" => [%{"language" => "tmt", "scopeName" => "source.tmt", "path" => "tmt.json"}]
      },
      %{"tmt.json" => @grammar}
    )

    root = Bee.Workspace.root()
    File.mkdir_p!(root)
    file = Path.join(root, "a.tmt")
    File.write!(file, "def x")
    on_exit(fn -> File.rm(file) end)

    {:ok, view, _html} = live(conn, "/")

    grammars =
      view
      |> element("#editor")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-grammars")
      |> hd()
      |> Jason.decode!()

    assert %{"source.tmt" => %{"url" => "/plugins/tmt/tmt.json"}} = grammars

    render_hook(view, "run_command", %{
      "command" => "bee.openFile",
      "args" => Jason.encode!([file])
    })

    assert_push_event(view, "cm:open", %{
      lang: "tmt",
      scope: "source.tmt",
      mode: nil
    })
  end
end

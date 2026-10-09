defmodule Bee.Console.HelpersTest do
  # Plugins are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bee.Plugins

  @moduletag :capture_log

  setup do
    dir = Plugins.user_dir()
    File.rm_rf!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Plugins.reload()
    end)

    %{dir: dir}
  end

  defp plugin(dir, name, grammars) do
    folder = Path.join(dir, name)
    File.mkdir_p!(folder)
    for %{"path" => path} <- grammars, do: File.write!(Path.join(folder, path), "{}")

    File.write!(
      Path.join(folder, "plugin.json"),
      Jason.encode!(%{"name" => name, "contributes" => %{"grammars" => grammars}})
    )
  end

  # The printed lines, without colors.
  defp grammars(filter) do
    capture_io(fn -> Bee.Console.Helpers.grammars(filter) end)
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim_trailing/1)
  end

  test "grammars(): who highlights a language, and which one Bee uses", %{dir: dir} do
    assert grammars("erlang") == [
             "erlang (Erlang)",
             "  * Bee (languages)  CodeMirror mode erlang",
             "1 languages"
           ]

    plugin(dir, "a-erlang", [
      %{"language" => "erlang", "scopeName" => "source.erlang", "path" => "a.json"}
    ])

    plugin(dir, "b-erlang", [
      %{"language" => "erlang", "scopeName" => "source.erlang", "path" => "b.json"}
    ])

    plugin(dir, "c-todo", [
      %{"scopeName" => "text.todo", "path" => "todo.json", "injectTo" => ["source.erlang"]}
    ])

    Plugins.reload()

    assert grammars("erlang") == [
             "erlang (Erlang)",
             "    Bee (languages)  CodeMirror mode erlang  overridden",
             "    a-erlang         TextMate source.erlang  a.json  overridden",
             "  * b-erlang         TextMate source.erlang  b.json",
             "(no language) included by other grammars, or injected",
             "    c-todo           TextMate text.todo  todo.json  -> injected into source.erlang",
             "1 languages"
           ]

    # By plugin, too; and everything.
    assert ["erlang (Erlang)" | _] = grammars("a-erlang")
    assert Enum.any?(grammars(""), &(&1 == "elixir (Elixir)"))
    assert grammars("nothing-like-this") == ["0 languages"]
  end

  test "grammars(): a scope's file comes from the last plugin contributing it", %{dir: dir} do
    plugin(dir, "a-erlang", [
      %{"language" => "erlang", "scopeName" => "source.erlang", "path" => "a.json"}
    ])

    # The same scope, for no language: its file is the one loaded.
    plugin(dir, "b-scope", [%{"scopeName" => "source.erlang", "path" => "b.json"}])
    Plugins.reload()

    assert [
             "erlang (Erlang)",
             "    Bee (languages)  CodeMirror mode erlang  overridden",
             "  * a-erlang         TextMate source.erlang  b.json (the file of b-scope)"
             | _
           ] = grammars("erlang")
  end

  defp features(filter) do
    capture_io(fn -> Bee.Console.Helpers.features(filter) end)
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim_trailing/1)
  end

  defp write_plugin(dir, name, manifest, files \\ %{}) do
    folder = Path.join(dir, name)
    File.mkdir_p!(folder)
    for {rel, text} <- files, do: File.write!(Path.join(folder, rel), text)
    File.write!(Path.join(folder, "plugin.json"), Jason.encode!(Map.put(manifest, "name", name)))
  end

  test "features(): each plugin's features, active or not", %{dir: dir} do
    # Installed from a VSIX: a grammar and a theme Bee uses, the rest not.
    write_plugin(
      dir,
      "erlang-ls",
      %{
        "version" => "0.0.39",
        "contributes" => %{
          "languages" => [%{"id" => "erlang", "extensions" => [".erl"]}],
          "grammars" => [
            %{"language" => "erlang", "scopeName" => "source.erlang", "path" => "e.json"}
          ],
          "themes" => [%{"label" => "Owl", "uiTheme" => "vs-dark", "path" => "owl.json"}]
        }
      },
      %{
        "e.json" => "{}",
        "owl.json" => "{}",
        ".vsix.json" => ~s({"name": "erlang-ls", "openVsx": "erlang-ls.erlang-ls"}),
        "package.json" =>
          Jason.encode!(%{
            "contributes" => %{"grammars" => [], "debuggers" => [], "configuration" => %{}}
          })
      }
    )

    # A later plugin's grammar for the same language wins.
    write_plugin(
      dir,
      "z-erlang",
      %{
        "contributes" => %{
          "grammars" => [
            %{"language" => "erlang", "scopeName" => "source.erlang2", "path" => "z.json"}
          ]
        }
      },
      %{"z.json" => "{}"}
    )

    write_plugin(dir, "off", %{
      "contributes" => %{
        "commands" => [%{"command" => "off.x", "title" => "X", "runtime" => "client"}]
      }
    })

    :ok = Bee.Settings.update(:user, "plugins.disabled", fn _ -> ["off"] end)
    Plugins.reload()
    on_exit(fn -> Bee.Settings.update(:user, "plugins.disabled", fn _ -> [] end) end)

    assert features("") == [
             "erlang-ls 0.0.39  user · installed",
             "  Languages",
             "    erlang .erl  active",
             "  Grammars",
             "    source.erlang (erlang)  e.json  overridden by z-erlang",
             "  Color Themes",
             "    Owl  available",
             "  Not supported by Bee yet: configuration, debuggers",
             "off  user · disabled",
             "  Commands",
             "    off.x  X  inactive: plugin disabled",
             "z-erlang  user · installed",
             "  Grammars",
             "    source.erlang2 (erlang)  z.json  active",
             "3 plugins"
           ]

    # The theme selected is in use.
    :ok = Bee.Settings.update(:user, "workbench.colorTheme", fn _ -> "Owl" end)
    on_exit(fn -> Bee.Settings.update(:user, "workbench.colorTheme", fn _ -> nil end) end)
    assert "    Owl  in use" in features("owl")

    # Filtering: by kind, by feature, by plugin.
    assert features("grammars") == [
             "erlang-ls 0.0.39  user · installed",
             "  Grammars",
             "    source.erlang (erlang)  e.json  overridden by z-erlang",
             "z-erlang  user · installed",
             "  Grammars",
             "    source.erlang2 (erlang)  z.json  active",
             "2 plugins"
           ]

    assert features("off.x") == [
             "off  user · disabled",
             "  Commands",
             "    off.x  X  inactive: plugin disabled",
             "1 plugins"
           ]

    assert ["z-erlang  user · installed" | _] = features("z-erl")

    assert features("debuggers") == [
             "erlang-ls 0.0.39  user · installed",
             "  Not supported by Bee yet: debuggers",
             "1 plugins"
           ]

    assert features("nothing-like-this") == ["0 plugins"]
  end
end

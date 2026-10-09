defmodule Bee.SnippetsTest do
  # Plugins' snippets (Bee.Snippets), the editor's payload, Insert Snippet,
  # and snippets installed from a VSIX. Plugins are global.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bee.Plugins
  alias Bee.Snippets

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

  defp plugin(dir, name, snippets, files) do
    folder = Path.join(dir, name)
    File.mkdir_p!(folder)

    for {rel, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(folder, rel)))
      File.write!(Path.join(folder, rel), text)
    end

    File.write!(
      Path.join(folder, "plugin.json"),
      Jason.encode!(%{
        "name" => name,
        "contributes" => %{
          "languages" => [%{"id" => "tml", "extensions" => [".tml"]}],
          "snippets" => snippets
        }
      })
    )

    Plugins.reload()
    Plugins.get(name)
  end

  # VS Code's format: comments, a body as lines or text, one prefix or many.
  @tml """
  {
    // a function
    "Define a function": {
      "prefix": ["def", "fn"],
      "body": ["def ${1:name} do", "\\t$0", "end"],
      "description": "A function"
    },
    "Comment": {"prefix": "todo", "body": "# TODO: $0"},
    "No body": {"prefix": "x"},
    "Bad body": {"prefix": "y", "body": [1, 2]}
  }
  """

  @global """
  {
    "Copyright": {"prefix": "copy", "body": "(c) $CURRENT_YEAR", "scope": "tml, other"},
    "Everywhere": {"prefix": "ev", "body": "everywhere"}
  }
  """

  test "a plugin's snippets, by language", %{dir: dir} do
    plugin(
      dir,
      "snips",
      [
        %{"language" => "tml", "path" => "./snippets/tml.json"},
        %{"path" => "global.code-snippets"}
      ],
      %{"snippets/tml.json" => @tml, "global.code-snippets" => @global}
    )

    assert %{errors: []} = Plugins.get("snips")

    assert [
             %{name: "Comment", prefixes: ["todo"], body: "# TODO: $0", description: nil},
             %{
               name: "Define a function",
               prefixes: ["def", "fn"],
               body: "def ${1:name} do\n\t$0\nend",
               description: "A function"
             },
             %{name: "Copyright", languages: ["tml", "other"]},
             %{name: "Everywhere", languages: :all}
           ] = Snippets.for_language("tml")

    assert Enum.map(Snippets.for_language("elixir"), & &1.name) == ["Everywhere"]
    assert Enum.map(Snippets.for_language("other"), & &1.name) == ["Copyright", "Everywhere"]

    assert %{prefix: ["def", "fn"], body: "def ${1:name} do\n\t$0\nend"} =
             Enum.find(Snippets.editor_snippets("tml"), &(&1.name == "Define a function"))
  end

  test "a snippets file that can't be read is the plugin's problem", %{dir: dir} do
    missing = plugin(dir, "missing", [%{"language" => "tml", "path" => "nope.json"}], %{})
    assert [%{message: message}] = missing.errors
    assert message =~ "snippets nope.json: no such file or directory"

    bad = plugin(dir, "bad", [%{"path" => "s.json"}], %{"s.json" => "[]"})
    assert [%{message: message}] = bad.errors
    assert message =~ "snippets s.json: not a JSON object"

    outside = plugin(dir, "outside", [%{"path" => "../bad/s.json"}], %{})
    assert [%{message: message}] = outside.errors
    assert message =~ "snippets ../bad/s.json: must be inside the plugin"
  end

  describe "in the editor" do
    setup %{dir: dir} do
      plugin(dir, "snips", [%{"language" => "tml", "path" => "tml.json"}], %{"tml.json" => @tml})

      root = Bee.Workspace.root()
      File.mkdir_p!(root)
      file = Path.join(root, "a.tml")
      File.write!(file, "x")
      on_exit(fn -> File.rm(file) end)
      %{tml: file}
    end

    test "a file gets its language's snippets", %{conn: conn, tml: file} do
      {:ok, view, _html} = live(conn, "/")
      run(view, "bee.openFile", [file])

      assert_push_event(view, "cm:open", %{lang: "tml", snippets: snippets})
      assert Enum.map(snippets, & &1.name) == ["Comment", "Define a function"]
    end

    test "Insert Snippet picks one and sends it to the editor", %{conn: conn, tml: file} do
      {:ok, view, _html} = live(conn, "/")

      # No file: it's disabled (enablement).
      refute run(view, "editor.action.insertSnippet") =~ "Select a snippet"

      run(view, "bee.openFile", [file])
      html = run(view, "editor.action.insertSnippet")
      assert html =~ "Select a snippet"
      assert html =~ "Define a function"
      assert html =~ "def, fn"

      run(view, "bee.insertSnippet", ["tml", "Define a function"])
      assert_push_event(view, "cm:snippet", %{path: ^file, body: "def ${1:name} do\n\t$0\nend"})
    end
  end

  test "a VSIX's snippets are installed with it" do
    package = %{
      "name" => "tml-snips",
      "contributes" => %{
        "snippets" => [
          %{"language" => "tml", "path" => "./snippets.json"},
          %{"language" => "tml", "path" => "./missing.json"}
        ]
      }
    }

    tmp = Path.join(System.tmp_dir!(), "bee-snip-#{System.unique_integer([:positive])}.vsix")

    {:ok, _} =
      :zip.create(String.to_charlist(tmp), [
        {~c"extension/package.json", Jason.encode!(package)},
        {~c"extension/snippets.json", ~s({"S": {"prefix": "s", "body": "snip"}})}
      ])

    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, "tml-snips"} = Bee.Plugins.Vsix.install(tmp)
    assert %{errors: []} = Plugins.get("tml-snips")
    assert [%{name: "S", body: "snip"}] = Snippets.for_language("tml")
  end

  defp run(view, command, args \\ []),
    do: render_hook(view, "run_command", %{"command" => command, "args" => Jason.encode!(args)})
end

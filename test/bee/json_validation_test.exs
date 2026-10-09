defmodule Bee.JSONValidationTest do
  # Plugins' JSON schemas (jsonValidation): matching, validation, remote
  # schemas (a Req.Test stub), the editor's diagnostics. Plugins are global.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bee.JSONValidation
  alias Bee.Plugins

  @moduletag :capture_log

  setup do
    Req.Test.set_req_test_to_shared()
    Cachex.clear(Bee.JSONValidation.Schemas.Cache)
    dir = Plugins.user_dir()
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Cachex.clear(Bee.JSONValidation.Schemas.Cache)
      Plugins.reload()
    end)

    %{dir: dir}
  end

  @schema Jason.encode!(%{
            "$schema" => "http://json-schema.org/draft-04/schema#",
            "type" => "object",
            "required" => ["name"],
            "additionalProperties" => false,
            "properties" => %{
              "name" => %{"$ref" => "./defs.json#/definitions/name"},
              "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
              "info" => %{"type" => "object"}
            }
          })

  @defs ~s({"definitions": {"name": {"type": "string", "minLength": 3}}})

  defp plugin(dir, name, validation, files) do
    folder = Path.join(dir, name)
    File.mkdir_p!(folder)
    for {rel, text} <- files, do: File.write!(Path.join(folder, rel), text)

    File.write!(
      Path.join(folder, "plugin.json"),
      Jason.encode!(%{"name" => name, "contributes" => %{"jsonValidation" => validation}})
    )

    Plugins.reload()
    Plugins.get(name)
  end

  defp schema_plugin(dir) do
    plugin(
      dir,
      "pets",
      [
        %{
          "fileMatch" => ["*.pets.json", "!skip.pets.json", "/conf/pets.json"],
          "url" => "./schema.json"
        }
      ],
      %{"schema.json" => @schema, "defs.json" => @defs}
    )
  end

  # The text each diagnostic is on, with its message.
  defp shown(text, diagnostics),
    do:
      for(d <- diagnostics, do: {binary_part(text, d.from, d.to - d.from), d.severity, d.message})

  test "which files a schema is for", %{dir: dir} do
    schema_plugin(dir)
    schema = Path.join([dir, "pets", "schema.json"])

    assert JSONValidation.schemas_for("/w/a.pets.json") == [schema]
    assert JSONValidation.schemas_for("/w/sub/conf/pets.json") == [schema]
    assert JSONValidation.schemas_for("/w/skip.pets.json") == []
    assert JSONValidation.schemas_for("/w/pets.json") == []
    assert JSONValidation.schemas_for("/w/a.pets.jsonc") == []
  end

  test "errors are placed on what they're about", %{dir: dir} do
    schema_plugin(dir)
    text = ~s({\n  "name": "ab",\n  "tags": ["x", 2],\n  "extra": 1,\n  "info": [1]\n})

    assert shown(text, JSONValidation.validate("/w/a.pets.json", text)) == [
             {~s("ab"), :warning, "Expected value to have a minimum length of 3 but was 2."},
             {"2", :warning, ~s(Incorrect type. Expected "string".)},
             {~s("extra"), :warning, ~s(Property "extra" is not allowed.)},
             {~s("info"), :warning, ~s(Incorrect type. Expected "object".)}
           ]

    assert [%{line: 2}, %{line: 3}, %{line: 4}, %{line: 5}] =
             JSONValidation.validate("/w/a.pets.json", text)

    # A missing property: on the object.
    assert shown("{}", JSONValidation.validate("/w/a.pets.json", "{}")) ==
             [{"{", :warning, ~s(Missing property "name".)}]

    # Valid; comments and trailing commas are fine.
    assert JSONValidation.validate("/w/a.pets.json", ~s({// hi\n "name": "rex",})) == []
  end

  test "a syntax error, schema or not" do
    text = ~s({"a": 1,\n "b" 2})

    assert [%{line: 2, severity: :error, message: "Colon expected"}] =
             JSONValidation.validate("/w/x.json", text)

    assert JSONValidation.validate("/w/x.json", ~s({"a": 1})) == []
  end

  test "a schema at a web address: fetched once; a failure says why", %{dir: dir} do
    counter = :counters.new(1, [])

    Req.Test.stub(Bee.JSONValidation.Schemas, fn conn ->
      :counters.add(counter, 1, 1)

      case conn.request_path do
        "/schema.json" ->
          Plug.Conn.send_resp(conn, 200, ~s({"type": "object", "required": ["id"]}))

        _ ->
          Plug.Conn.send_resp(conn, 404, "no")
      end
    end)

    plugin(
      dir,
      "remote",
      [
        %{"fileMatch" => "*.remote.json", "url" => "https://schemas.test/schema.json"},
        %{"fileMatch" => "*.gone.json", "url" => "https://schemas.test/gone.json"}
      ],
      %{}
    )

    assert [%{message: ~s(Missing property "id".)}] =
             JSONValidation.validate("/w/a.remote.json", "{}")

    assert [_] = JSONValidation.validate("/w/b.remote.json", "{}")
    assert :counters.get(counter, 1) == 1

    assert [%{severity: :warning, message: message}] =
             JSONValidation.validate("/w/a.gone.json", "{}")

    assert message == "Can't use the schema https://schemas.test/gone.json: HTTP 404"
    # Not asked again right away.
    JSONValidation.validate("/w/a.gone.json", "{}")
    assert :counters.get(counter, 1) == 2
  end

  test "a schema Bee can't use says so", %{dir: dir} do
    plugin(
      dir,
      "new-draft",
      [%{"fileMatch" => "*.x.json", "url" => "s.json"}],
      %{"s.json" => ~s({"$schema": "https://json-schema.org/draft/2020-12/schema"})}
    )

    assert [%{message: "Can't use the schema " <> rest}] =
             JSONValidation.validate("/w/a.x.json", "{}")

    assert rest =~ "only draft 4, 6, and 7 are supported"
  end

  test "a schema must be a file in the plugin", %{dir: dir} do
    missing = plugin(dir, "missing", [%{"fileMatch" => "*.y", "url" => "nope.json"}], %{})
    assert [%{message: message}] = missing.errors
    assert message =~ "jsonValidation nope.json: no such file"

    outside = plugin(dir, "outside", [%{"fileMatch" => "*.y", "url" => "../pets/s.json"}], %{})
    assert [%{message: message}] = outside.errors
    assert message =~ "the schema must be inside the plugin"
  end

  test "the editor gets a file's diagnostics, again as it changes", %{conn: conn, dir: dir} do
    schema_plugin(dir)
    root = Bee.Workspace.root()
    File.mkdir_p!(root)
    path = Path.join(root, "a.pets.json")
    File.write!(path, ~s({"name": "ab"}))
    on_exit(fn -> File.rm(path) end)

    {:ok, view, _html} = live(conn, "/")

    render_hook(view, "run_command", %{
      "command" => "bee.openFile",
      "args" => Jason.encode!([path])
    })

    assert_push_event(
      view,
      "cm:diagnostics",
      %{path: ^path, size: 14, diagnostics: [diagnostic]},
      2000
    )

    assert %{from: 9, to: 13, severity: :warning} = diagnostic
    assert render(view) =~ "1 problem"

    render_hook(view, "doc_changed", %{"path" => path, "text" => ~s({"name": "abc"})})
    assert_push_event(view, "cm:diagnostics", %{path: ^path, size: 15, diagnostics: []}, 2000)
    refute render(view) =~ "1 problem"
  end

  test "a VSIX's schemas are installed with it" do
    package = %{
      "name" => "pets-ext",
      "contributes" => %{
        "jsonValidation" => [
          %{"fileMatch" => "*.pets.json", "url" => "./schema.json"},
          %{"fileMatch" => ["*.web.json"], "url" => "https://schemas.test/web.json"},
          %{"fileMatch" => "*.gone.json", "url" => "./missing.json"}
        ]
      }
    }

    tmp = Path.join(System.tmp_dir!(), "bee-jv-#{System.unique_integer([:positive])}.vsix")

    {:ok, _} =
      :zip.create(String.to_charlist(tmp), [
        {~c"extension/package.json", Jason.encode!(package)},
        {~c"extension/schema.json", ~s({"type": "object"})}
      ])

    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, "pets-ext"} = Bee.Plugins.Vsix.install(tmp)
    assert %{errors: []} = Plugins.get("pets-ext")
    assert [_] = JSONValidation.schemas_for("/w/a.pets.json")
    assert ["https://schemas.test/web.json"] = JSONValidation.schemas_for("/w/a.web.json")
    assert JSONValidation.schemas_for("/w/a.gone.json") == []
  end
end

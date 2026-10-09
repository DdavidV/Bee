defmodule Bee.JSONValidation.AssistTest do
  # Completion and hover from JSON schemas; the context of a position in
  # JSON being typed. Plugins are global.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bee.JSON.Context
  alias Bee.JSONValidation
  alias Bee.JSONValidation.Assist
  alias Bee.Plugins

  @moduletag :capture_log

  # `text` with the cursor at "|": {text, offset}.
  defp at(text) do
    [a, b] = String.split(text, "|")
    {a <> b, byte_size(a)}
  end

  describe "the context of a position" do
    defp ctx(text) do
      {text, offset} = at(text)
      c = Context.at(text, offset)
      {c.kind, c.path, binary_part(text, c.from, c.to - c.from)}
    end

    test "keys and values, while typing" do
      assert ctx(~s({"a": 1, "na|)) == {:key, [], ~s("na)}
      assert ctx(~s({"a": 1, |})) == {:key, [], ""}
      assert ctx(~s({"a": 1 "b|"})) == {:key, [], ~s("b")}
      assert ctx(~s({"a": {"b": |}})) == {:value, ["a", "b"], ""}
      assert ctx(~s({"a": {"b": "x|y"}})) == {:value, ["a", "b"], ~s("xy")}
      assert ctx(~s({"a": [1, {"c": 2}, |]})) == {:value, ["a", "2"], ""}
      assert ctx(~s({"a": [1, {"c": 2, "|"}]})) == {:key, ["a", "1"], ~s("")}
      assert ctx(~s({"a": tr|})) == {:value, ["a"], "tr"}
      assert ctx(~s(|{})) == {:value, [], ""}
      assert ctx(~s({\n  // "x": \n  "y": |\n})) == {:value, ["y"], ""}
    end

    test "every object's keys" do
      {text, _} = at(~s({"s": 1, "o": {"t": 1}, "x": [{"q": 1}]}|))

      assert Context.at(text, 0).keys == %{
               [] => ["s", "o", "x"],
               ["o"] => ["t"],
               ["x", "0"] => ["q"]
             }
    end
  end

  describe "from a plugin's schema" do
    setup do
      Cachex.clear(Bee.JSONValidation.Schemas.Cache)
      dir = Plugins.user_dir()
      File.rm_rf!(dir)
      folder = Path.join(dir, "pets")
      File.mkdir_p!(folder)

      schema = %{
        "$schema" => "http://json-schema.org/draft-07/schema#",
        "type" => "object",
        "properties" => %{
          "name" => %{"$ref" => "./defs.json#/definitions/name"},
          "kind" => %{"enum" => ["cat", "dog"], "description" => "What it is"},
          "age" => %{"type" => "integer", "default" => 1},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "vet" => %{"type" => "object", "properties" => %{"phone" => %{"type" => "string"}}},
          "good" => %{"type" => "boolean"}
        },
        "dependencies" => %{
          "kind" => %{"properties" => %{"breed" => %{"type" => "string", "title" => "Breed"}}}
        }
      }

      File.write!(Path.join(folder, "schema.json"), Jason.encode!(schema))

      File.write!(
        Path.join(folder, "defs.json"),
        ~s({"definitions": {"name": {"type": "string", "description": "Its name"}}})
      )

      File.write!(
        Path.join(folder, "plugin.json"),
        Jason.encode!(%{
          "name" => "pets",
          "contributes" => %{
            "jsonValidation" => [%{"fileMatch" => "*.pets.json", "url" => "./schema.json"}]
          }
        })
      )

      Plugins.reload()
      on_exit(fn -> File.rm_rf!(dir) && Plugins.reload() end)
      :ok
    end

    defp complete(text) do
      {text, offset} = at(text)
      # Validation loads the schema; completion only uses loaded ones.
      JSONValidation.validate("/w/a.pets.json", text)
      Assist.complete("/w/a.pets.json", text, offset)
    end

    test "keys: the ones the object doesn't have, with a value to fill in" do
      %{items: items} = complete(~s({"age": 2, |}))
      by = Map.new(items, &{&1.display, &1})

      assert Map.keys(by) == ~w(good kind name tags vet)

      assert by["name"] == %{
               label: ~s("name"),
               display: "name",
               detail: "string",
               info: "Its name",
               snippet: ~s("name": "$1")
             }

      assert by["good"].snippet == ~s("good": ${1:false})
      assert by["tags"].snippet == ~s("tags": [$1])
      assert by["vet"].snippet == ~s("vet": {$1})
      assert by["kind"].info == "What it is"

      # The default, to change.
      assert %{items: [%{snippet: ~s("age": ${1:1})} | _]} = complete(~s({"a|"}))
    end

    test "keys: where the cursor's key is, replaced" do
      {text, offset} = at(~s({"kind": "cat", "na|"}))
      JSONValidation.validate("/w/a.pets.json", text)
      %{from: from, to: to, items: items} = Assist.complete("/w/a.pets.json", text, offset)
      assert binary_part(text, from, to - from) == ~s("na")
      # dependencies: kind is there, so breed is too.
      assert "breed" in Enum.map(items, & &1.display)
      refute "breed" in Enum.map(complete(~s({|})).items, & &1.display)
      # Nested.
      assert [%{display: "phone"}] = complete(~s({"vet": {|}})).items
    end

    test "values: enum, booleans, containers" do
      assert Enum.map(complete(~s({"kind": |})).items, & &1.label) == [~s("cat"), ~s("dog")]
      assert Enum.map(complete(~s({"good": |})).items, & &1.label) == ["true", "false"]
      assert Enum.map(complete(~s({"tags": |})).items, & &1.label) == ["[]"]
      assert Enum.map(complete(~s({"age": |})).items, & &1.label) == ["1"]
    end

    test "hover: what the schema says" do
      {text, offset} = at(~s({"ki|nd": "cat"}))
      JSONValidation.validate("/w/a.pets.json", text)

      assert %{text: "What it is\n\nAllowed: \"cat\", \"dog\"", from: 1, to: 7} =
               Assist.hover("/w/a.pets.json", text, offset)

      {text, offset} = at(~s({"name": "Re|x"}))
      assert %{text: "Its name\n\nType: string"} = Assist.hover("/w/a.pets.json", text, offset)

      {text, offset} = at(~s({"unknown|": 1}))
      assert Assist.hover("/w/a.pets.json", text, offset) == nil
    end

    test "a schema not loaded yet: nothing (completion never waits)" do
      {text, offset} = at(~s({|}))
      assert Assist.complete("/w/a.pets.json", text, offset).items == []
    end

    test "the editor asks the window", %{conn: conn} do
      root = Bee.Workspace.root()
      File.mkdir_p!(root)
      path = Path.join(root, "x.pets.json")
      File.write!(path, ~s({"kind": }))
      on_exit(fn -> File.rm(path) end)

      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "run_command", %{
        "command" => "bee.openFile",
        "args" => Jason.encode!([path])
      })

      assert_push_event(view, "cm:open", %{json: true})
      assert_push_event(view, "cm:diagnostics", %{path: ^path}, 2000)

      reply =
        render_hook_reply(view, %{
          "path" => path,
          "kind" => "complete",
          "offset" => 9,
          "size" => 10
        })

      assert Enum.map(reply.items, & &1.label) == [~s("cat"), ~s("dog")]

      # Another text than the window's: no answer.
      assert render_hook_reply(view, %{
               "path" => path,
               "kind" => "complete",
               "offset" => 9,
               "size" => 3
             }) == %{}
    end
  end

  # json_assist's reply.
  defp render_hook_reply(view, params) do
    render_hook(view, "json_assist", params)
    assert_reply(view, reply)
    reply
  end
end

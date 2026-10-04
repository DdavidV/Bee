defmodule Bee.SettingsTest do
  # Uses the (test) user config dir and workspace, shared with other sync tests.
  use ExUnit.Case, async: false

  # Invalid settings/keybindings are logged on purpose in some tests.
  @moduletag :capture_log

  alias Bee.Settings

  setup do
    File.mkdir_p!(Path.dirname(Settings.user_path()))
    File.mkdir_p!(Path.dirname(Settings.workspace_path()))
    Settings.subscribe()

    on_exit(fn ->
      File.rm(Settings.user_path())
      File.rm_rf!(Path.dirname(Settings.workspace_path()))
      Settings.reload()
    end)
  end

  defp write(path, text) do
    File.write!(path, text)
    Settings.reload()
  end

  test "defaults when no files exist" do
    Settings.reload()
    assert Settings.get("editor.fontSize") == 14
    assert Settings.errors() == []
  end

  test "workspace overrides user overrides defaults, and reload broadcasts" do
    write(Settings.user_path(), ~s({"editor.fontSize": 18, "editor.tabSize": 4}))
    write(Settings.workspace_path(), ~s({"editor.fontSize": 20}))

    assert Settings.get("editor.fontSize") == 20
    assert Settings.get("editor.tabSize") == 4
    assert_receive {:settings_changed, %{"editor.fontSize" => 20}, []}
  end

  test "comments and trailing commas are allowed" do
    write(Settings.user_path(), """
    // mine
    {
      "editor.fontSize": 16, // bigger
    }
    """)

    assert Settings.get("editor.fontSize") == 16
  end

  test "invalid values fall back to the layer below and are reported" do
    write(Settings.user_path(), ~s({"editor.fontSize": 18}))

    write(
      Settings.workspace_path(),
      ~s({"editor.fontSize": "huge", "editor.tabSize": 0, "workbench.colorTheme": "pink"})
    )

    assert Settings.get("editor.fontSize") == 18
    assert Settings.get("editor.tabSize") == 2
    assert Settings.get("workbench.colorTheme") == "dark"

    messages = Enum.map(Settings.errors(), & &1.message)
    assert ~s("editor.fontSize": Type mismatch. Expected Integer but got String.) in messages
    assert ~s("editor.tabSize": Expected the value to be >= 1) in messages

    assert ~s("workbench.colorTheme": value is not allowed, expected one of "dark", "light") in messages
  end

  test "nested values are validated too, naming the offending key" do
    write(Settings.user_path(), ~s({"files.exclude": {"**/tmp": "yes"}}))

    assert [%{message: message}] = Settings.errors()

    assert message ==
             ~s|"files.exclude": Type mismatch. Expected Boolean but got String. (at **/tmp)|
  end

  test "a broken file is reported and ignored" do
    write(Settings.user_path(), ~s({"editor.fontSize": 18,,}))
    assert Settings.get("editor.fontSize") == 14
    assert [%{path: path, message: message}] = Settings.errors()
    assert path == Settings.user_path()
    assert message =~ "line 1"

    write(Settings.user_path(), "[1, 2]")
    assert [%{message: "must contain a JSON object"}] = Settings.errors()
  end

  test "object settings merge with the defaults" do
    write(Settings.user_path(), ~s({"files.exclude": {"**/tmp": true, "**/deps": false}}))

    exclude = Settings.get("files.exclude")
    assert exclude["**/tmp"] == true
    assert exclude["**/deps"] == false
    assert exclude["**/.git"] == true

    globs = Enum.map(Settings.excluded_globs(), & &1.source)
    assert Enum.any?(globs, &(&1 =~ "tmp"))
    refute Enum.any?(globs, &(&1 =~ "deps"))
  end

  test "unknown keys are kept for plugins" do
    write(Settings.user_path(), ~s({"myPlugin.enabled": true}))
    assert Settings.get("myPlugin.enabled") == true
    assert Settings.errors() == []
  end

  test "the shipped schemas are valid draft 7 JSON Schemas" do
    for name <- ["settings", "keybindings"] do
      assert %ExJsonSchema.Schema.Root{} = Bee.JSON.Schema.load!(name)
      assert Bee.JSON.Schema.raw!(name)["$schema"] == "http://json-schema.org/draft-07/schema#"
    end

    for {key, spec} <- Settings.schema() do
      assert is_binary(spec["description"]), "#{key} needs a description"
      assert Settings.validate(key, spec["default"]) == :ok, "#{key}'s default must be valid"
    end
  end

  test "the generated user file documents every setting and is valid JSONC" do
    File.rm(Settings.user_path())
    path = Settings.ensure_user_file!()
    text = File.read!(path)

    for {key, %{"description" => description}} <- Settings.schema() do
      assert text =~ ~s("#{key}")
      assert text =~ description
    end

    assert {:ok, %{}} = Bee.JSON.JSONC.decode(text)
  end

  test "get_user/1 ignores the workspace layer" do
    write(Settings.user_path(), ~s({"editor.fontSize": 18}))

    write(
      Settings.workspace_path(),
      ~s({"editor.fontSize": 20, "plugins.workspace.enabled": true})
    )

    assert Settings.get("editor.fontSize") == 20
    assert Settings.get_user("editor.fontSize") == 18
    assert Settings.get("plugins.workspace.enabled") == true
    assert Settings.get_user("plugins.workspace.enabled") == false
  end

  describe "contributed settings (Bee.Settings.Configuration)" do
    @configuration %{
      "title" => "Test",
      "properties" => %{
        "test.level" => %{
          "type" => "integer",
          "minimum" => 1,
          "default" => 3,
          "description" => "A level."
        }
      }
    }

    defp contribute(source, configuration) do
      Bee.Contributions.register(source, %{
        "name" => "test",
        "contributes" => %{"configuration" => configuration}
      })
    end

    setup do
      on_exit(fn ->
        Bee.Contributions.unregister(:test_settings)
        Bee.Contributions.unregister(:test_settings_2)
      end)
    end

    test "add defaults, validation and documentation; go away when unregistered" do
      write(Settings.user_path(), ~s({"test.level": 0}))
      assert Settings.get("test.level") == 0
      assert Settings.errors() == []

      :ok = contribute(:test_settings, @configuration)
      # Settings reloads on its own when contributions change.
      assert_receive {:settings_changed, _, [%{message: ~s("test.level": ) <> message}]}
      assert message =~ ">= 1"
      assert Settings.get("test.level") == 3
      assert Settings.schema()["test.level"]["description"] == "A level."

      Bee.Contributions.unregister(:test_settings)
      assert_receive {:settings_changed, %{"test.level" => 0}, []}
    end

    test "names are unique, and the schema must be valid" do
      assert {:error, message} =
               contribute(:test_settings, %{
                 "properties" => %{"editor.fontSize" => %{"type" => "integer"}}
               })

      assert message =~ ~s(setting "editor.fontSize" is already defined)

      :ok = contribute(:test_settings, @configuration)
      assert {:error, message} = contribute(:test_settings_2, @configuration)
      assert message =~ ~s(setting "test.level" is already defined)

      assert {:error, "invalid configuration schema: " <> _} =
               contribute(:test_settings_2, %{
                 "properties" => %{"test.other" => %{"type" => "no-such-type"}}
               })
    end
  end
end

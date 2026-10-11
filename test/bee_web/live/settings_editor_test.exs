defmodule BeeWeb.SettingsEditorTest do
  # The settings page (BeeWeb.Workbench.SettingsEditor), in the window.
  use BeeWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias Bee.Settings

  setup %{conn: conn} do
    root = Bee.Workspace.root()
    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.rm(Settings.user_path())
    Settings.reload()

    on_exit(fn ->
      File.rm(Settings.user_path())
      File.rm_rf!(root)
      Settings.reload()
    end)

    {:ok, view, _html} = live(conn, "/")
    {:ok, view: view, root: root}
  end

  defp run(view, command), do: render_hook(view, "run_command", %{"command" => command})
  defp row(key), do: "#settings-editor [data-setting='#{key}']"

  # A list of values or a switch: its form changes. A number or a text: its
  # field is left with the value in it.
  defp set(view, key, value) do
    if has_element?(view, "#{row(key)} form") do
      view |> element("#{row(key)} form") |> render_change(%{"key" => key, "value" => value})
    else
      view |> element("#{row(key)} input") |> render_blur(%{"value" => value})
    end
  end

  defp user, do: Settings.layer(:user)

  test "opens in a tab, from its command; User and Workspace are the same tab", %{view: view} do
    run(view, "workbench.action.openSettings")

    assert has_element?(
             view,
             "[data-tabs] [data-tab][data-active=true][data-path='settings:']",
             "Settings"
           )

    assert has_element?(view, "#settings-editor[data-scope=user]")
    assert has_element?(view, "#settings-editor [role=tab][aria-selected=true]", "User")

    view |> element("#settings-editor [role=tab]", "Workspace") |> render_click()
    assert has_element?(view, "#settings-editor[data-scope=workspace]")
    refute has_element?(view, "[data-tabs] > [data-tab]:nth-child(2)")

    run(view, "workbench.action.openSettings")
    assert has_element?(view, "#settings-editor[data-scope=user]")
  end

  test "every setting is there, in its group, with the control for its kind", %{view: view} do
    run(view, "workbench.action.openSettings")

    for key <- Map.keys(Settings.builtin_schema()), do: assert(has_element?(view, row(key)), key)

    assert has_element?(
             view,
             "[data-settings-group=Editor] [data-setting='editor.fontSize'] input[type=number][min='6'][max='72'][value='14']"
           )

    assert has_element?(
             view,
             "#{row("editor.formatOnSave")} input[type=checkbox][role=switch]:not([checked])"
           )

    assert has_element?(view, "#{row("editor.wordWrap")} select option[value=off][selected]")

    assert has_element?(
             view,
             "#{row("workbench.colorTheme")} select option[value=dark][selected]",
             "Bee Dark"
           )

    assert has_element?(view, "#{row("extensions.nodePath")} input[type=text][value=node]")

    assert has_element?(
             view,
             "#{row("files.exclude")} [data-map] [data-item='**/.git'] input[role=switch][checked]"
           )

    assert has_element?(view, "#{row("plugins.disabled")} [data-list]", "None.")
    # Nothing is set yet: nothing to reset.
    refute has_element?(view, "#settings-editor [data-modified=true]")
    refute has_element?(view, "#settings-editor button", "Reset")
  end

  test "a change is written to the file and applies; Reset takes it out again", %{view: view} do
    run(view, "workbench.action.openSettings")

    set(view, "editor.fontSize", "20")
    assert user()["editor.fontSize"] == 20
    assert Settings.get("editor.fontSize") == 20
    assert has_element?(view, "#{row("editor.fontSize")}[data-modified=true] input[value='20']")

    set(view, "editor.wordWrap", "on")
    assert user()["editor.wordWrap"] == "on"

    # A switch: on sends its value, off sends none.
    view
    |> element("#{row("editor.formatOnSave")} form")
    |> render_change(%{"key" => "editor.formatOnSave", "value" => "true"})

    assert user()["editor.formatOnSave"] == true

    view
    |> element("#{row("editor.formatOnSave")} form")
    |> render_change(%{"key" => "editor.formatOnSave", "value" => "false"})

    assert user()["editor.formatOnSave"] == false

    view |> element("#{row("editor.fontSize")} button", "Reset") |> render_click()
    refute Map.has_key?(user(), "editor.fontSize")
    assert Settings.get("editor.fontSize") == 14
    assert has_element?(view, "#{row("editor.fontSize")}[data-modified=false] input[value='14']")
    # The others are still set.
    assert user()["editor.wordWrap"] == "on"
  end

  test "a value the setting doesn't allow isn't written: the reason is shown", %{view: view} do
    run(view, "workbench.action.openSettings")

    html = set(view, "editor.fontSize", "500")
    assert html =~ "72"
    assert has_element?(view, "#{row("editor.fontSize")} [role=alert]")
    refute Map.has_key?(user(), "editor.fontSize")

    set(view, "editor.fontSize", "lots")
    assert has_element?(view, "#{row("editor.fontSize")} [role=alert]", "whole number")

    # Enter in the field does what leaving it does.
    view
    |> element("#{row("editor.tabSize")} input")
    |> render_keydown(%{"key" => "Enter", "value" => "6"})

    assert user()["editor.tabSize"] == 6

    # A good one clears it.
    set(view, "editor.fontSize", "18")
    refute has_element?(view, "#{row("editor.fontSize")} [role=alert]")
    assert user()["editor.fontSize"] == 18
  end

  test "search narrows it down; nothing found says so", %{view: view} do
    run(view, "workbench.action.openSettings")
    form = element(view, "#settings-search")

    render_change(form, %{"query" => "font size"})
    assert has_element?(view, row("editor.fontSize"))
    assert has_element?(view, row("terminal.integrated.fontSize"))
    refute has_element?(view, row("editor.tabSize"))
    assert has_element?(view, "#settings-count", "2 of")
    refute has_element?(view, "[data-settings-group=Files]")

    render_change(form, %{"query" => "zzzz"})
    assert has_element?(view, "#settings-empty")

    render_change(form, %{"query" => ""})
    assert has_element?(view, row("editor.tabSize"))
  end

  test "lists and tables of patterns: add, switch, remove", %{view: view} do
    run(view, "workbench.action.openSettings")

    view
    |> element("#{row("plugins.disabled")} form")
    |> render_submit(%{"key" => "plugins.disabled", "value" => " word-count "})

    assert user()["plugins.disabled"] == ["word-count"]

    view
    |> element("#{row("plugins.disabled")} [data-item='word-count'] button")
    |> render_click()

    assert user()["plugins.disabled"] == []

    # A default pattern switched off: only that is written.
    view
    |> element("#{row("files.exclude")} [data-item='**/.git'] form")
    |> render_change(%{"key" => "files.exclude", "name" => "**/.git", "value" => "false"})

    assert user()["files.exclude"] == %{"**/.git" => false}
    assert Settings.get("files.exclude")["**/.elixir_ls"] == true

    view
    |> element("#setting-add-files-exclude")
    |> render_submit(%{"key" => "files.exclude", "name" => "**/*.log", "value" => "true"})

    assert user()["files.exclude"] == %{"**/.git" => false, "**/*.log" => true}
    # What the file added can be taken out; a default can only be switched.
    assert has_element?(
             view,
             "#{row("files.exclude")} [data-item='**/*.log'] button:not([disabled])"
           )

    assert has_element?(view, "#{row("files.exclude")} [data-item='**/.expert'] button[disabled]")
    view |> element("#{row("files.exclude")} [data-item='**/*.log'] button") |> render_click()
    assert user()["files.exclude"] == %{"**/.git" => false}

    view
    |> element("#setting-add-files-associations")
    |> render_submit(%{
      "key" => "files.associations",
      "name" => "*.conf",
      "value" => "shellscript"
    })

    assert user()["files.associations"] == %{"*.conf" => "shellscript"}
    view |> element("#{row("files.associations")} [data-item='*.conf'] button") |> render_click()
    refute Map.has_key?(user(), "files.associations")
  end

  test "Workspace: the folder's file; what it doesn't set shows the user's value", %{
    view: view,
    root: root
  } do
    File.write!(Settings.user_path(), ~s({"editor.fontSize": 18}))
    Settings.reload()
    run(view, "workbench.action.openWorkspaceSettings")

    assert has_element?(view, "#{row("editor.fontSize")}[data-modified=false] input[value='18']")
    set(view, "editor.fontSize", "24")
    assert Settings.layer({:workspace, root})["editor.fontSize"] == 24
    assert user()["editor.fontSize"] == 18
    assert Settings.get("editor.fontSize", root) == 24

    view |> element("#{row("editor.fontSize")} button", "Reset") |> render_click()
    assert Settings.get("editor.fontSize", root) == 18
    assert has_element?(view, "#{row("editor.fontSize")} input[value='18']")

    # What only the user's file may set can't be set here.
    assert has_element?(view, "#{row("plugins.workspace.enabled")} input[disabled]")

    assert has_element?(
             view,
             row("plugins.workspace.enabled"),
             "Only takes effect in the user settings"
           )

    run(view, "workbench.action.openSettings")
    assert has_element?(view, "#{row("plugins.workspace.enabled")} input:not([disabled])")
  end

  test "for one language: its block of the file, for the settings a language can have", %{
    view: view
  } do
    run(view, "workbench.action.openSettings")
    view |> element("#settings-language") |> render_change(%{"language" => "elixir"})

    assert has_element?(view, "#settings-editor[data-language=elixir]")
    assert has_element?(view, "#settings-language-note", "[elixir]")
    assert has_element?(view, row("editor.formatOnSave"))
    assert has_element?(view, row("editor.tabSize"))
    refute has_element?(view, row("editor.fontSize"))

    view
    |> element("#{row("editor.formatOnSave")} form")
    |> render_change(%{"key" => "editor.formatOnSave", "value" => "true"})

    set(view, "editor.tabSize", "4")
    assert user()["[elixir]"] == %{"editor.formatOnSave" => true, "editor.tabSize" => 4}
    refute Map.has_key?(user(), "editor.tabSize")
    assert Settings.get("editor.tabSize", nil, "elixir") == 4
    assert has_element?(view, "#settings-language option[value=elixir]", "Elixir •")

    # Another language: its own values (the general ones, so far).
    view |> element("#settings-language") |> render_change(%{"language" => "erlang"})
    assert has_element?(view, "#{row("editor.tabSize")}[data-modified=false] input[value='2']")

    view |> element("#settings-language") |> render_change(%{"language" => "elixir"})
    view |> element("#{row("editor.tabSize")} button", "Reset") |> render_click()
    assert user()["[elixir]"] == %{"editor.formatOnSave" => true}
    view |> element("#{row("editor.formatOnSave")} button", "Reset") |> render_click()
    refute Map.has_key?(user(), "[elixir]")

    # Back to all languages: everything again.
    view |> element("#settings-language") |> render_change(%{"language" => ""})
    assert has_element?(view, row("editor.fontSize"))
  end

  test "the file edited elsewhere shows on the page", %{view: view} do
    run(view, "workbench.action.openSettings")
    assert has_element?(view, "#{row("editor.fontSize")} input[value='14']")

    File.write!(Settings.user_path(), ~s({"editor.fontSize": 30}))
    Settings.reload()
    assert has_element?(view, "#{row("editor.fontSize")}[data-modified=true] input[value='30']")
  end

  test "a plugin's settings have a group of their own", %{view: view} do
    manifest = %{
      "name" => "pager",
      "contributes" => %{
        "configuration" => %{
          "title" => "Pager",
          "properties" => %{
            "pager.lines" => %{
              "type" => "integer",
              "default" => 40,
              "description" => "Lines a page."
            },
            "pager.mode" => %{"enum" => ["fast", "slow"], "default" => "fast"}
          }
        }
      }
    }

    :ok = Bee.Contributions.register({:plugin, "pager"}, manifest)
    on_exit(fn -> Bee.Contributions.unregister({:plugin, "pager"}) end)
    run(view, "workbench.action.openSettings")

    assert has_element?(
             view,
             "[data-settings-group=Pager] [data-setting='pager.lines'] input[type=number][value='40']"
           )

    assert has_element?(view, "#{row("pager.lines")}", "Lines a page.")
    set(view, "pager.mode", "slow")
    assert user()["pager.mode"] == "slow"
  end

  test "Ctrl+, and the gear open it; the JSON file is one click away", %{view: view} do
    assert view |> render() =~ "workbench.action.openSettings"
    run(view, "workbench.action.openSettings")
    view |> element("#settings-editor button", "Open Settings (JSON)") |> render_click()

    assert has_element?(
             view,
             "[data-tabs] [data-tab][data-active=true][data-path$='settings.json']"
           )
  end
end

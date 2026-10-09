defmodule BeeWeb.MarketplaceTest do
  # The Plugins view's Open VSX search, against a Req.Test stub of Open VSX.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bee.Plugins
  alias Bee.Plugins.OpenVsx

  @moduletag :capture_log

  setup do
    Req.Test.set_req_test_to_shared()
    OpenVsx.reset()
    File.rm_rf!(Plugins.user_dir())
    Plugins.reload()
    counter = :counters.new(1, [])
    config = Application.get_env(:bee, OpenVsx)
    Application.put_env(:bee, OpenVsx, Keyword.put(config, :target_platform, "linux-x64"))

    on_exit(fn ->
      Application.put_env(:bee, OpenVsx, config)
      OpenVsx.reset()
      File.rm_rf!(Plugins.user_dir())
      Plugins.reload()
    end)

    %{counter: counter}
  end

  defp rocket(version) do
    %{
      "namespace" => "acme",
      "name" => "rocket",
      "displayName" => "Rocket",
      "description" => "Goes up",
      "version" => version,
      "downloadCount" => 12_345,
      "averageRating" => 4.0,
      "verified" => true,
      "namespaceDisplayName" => "ACME Corp",
      "files" => %{
        "download" => "http://openvsx.test/api/acme/rocket/#{version}/file/rocket.vsix",
        "readme" => "http://openvsx.test/api/acme/rocket/#{version}/file/README.md"
      }
    }
  end

  defp vsix(version) do
    package = %{"name" => "rocket", "version" => version, "contributes" => %{}}

    {:ok, {_, zip}} =
      :zip.create(~c"x.vsix", [{~c"extension/package.json", Jason.encode!(package)}], [:memory])

    zip
  end

  # Open VSX with `total` search results (acme.rocket first, then fillers)
  # at version `version` (an Agent, so it can change).
  defp stub_open_vsx(counter, total, version) do
    Req.Test.stub(OpenVsx, fn conn ->
      :counters.add(counter, 1, 1)
      v = Agent.get(version, & &1)

      case conn.request_path do
        "/api/-/search" ->
          %{"offset" => offset, "size" => size} = Plug.Conn.fetch_query_params(conn).query_params
          {offset, size} = {String.to_integer(offset), String.to_integer(size)}

          all =
            [rocket(v)] ++
              for i <- 2..total//1, do: %{"namespace" => "filler", "name" => "ext#{i}"}

          Req.Test.json(conn, %{
            "offset" => offset,
            "totalSize" => total,
            "extensions" => Enum.slice(all, offset, size)
          })

        "/api/acme/rocket" ->
          Req.Test.json(conn, rocket(v))

        "/api/acme/rocket/" <> rest ->
          if String.ends_with?(rest, "README.md"),
            do: Req.Test.text(conn, "# Rocket\n\nGoes **up**."),
            else: Plug.Conn.send_resp(conn, 200, vsix(v))

        _ ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "Not found"})
      end
    end)
  end

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  defp search(view, query) do
    view |> element("#marketplace-form") |> render_change(%{"query" => query})
  end

  defp run(view, command, args),
    do: render_hook(view, "run_command", %{"command" => command, "args" => Jason.encode!(args)})

  test "searching replaces the installed plugins with Open VSX's results", %{
    conn: conn,
    counter: counter
  } do
    {:ok, version} = Agent.start_link(fn -> "1.0.0" end)
    stub_open_vsx(counter, 45, version)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-extensions") |> render_click()

    assert has_element?(view, "#marketplace-query")
    assert has_element?(view, "#plugins-workbench\\.extensions\\.installed")
    refute has_element?(view, "#marketplace")

    search(view, "rocket")
    refute has_element?(view, "#plugins-workbench\\.extensions\\.installed")
    eventually(fn -> has_element?(view, "#openvsx-acme\\.rocket") end)

    assert has_element?(view, "#openvsx-acme\\.rocket", "Rocket")
    assert has_element?(view, "#openvsx-acme\\.rocket", "12.3K")
    assert has_element?(view, "#openvsx-acme\\.rocket button", "Install")
    # 30 a page, the total in the header (one view: the container's).
    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#marketplace > [data-id]")
           |> Enum.count() == 30

    assert has_element?(view, "#marketplace-more", "30 of 45")

    view |> element("#marketplace-more") |> render_click()
    eventually(fn -> not has_element?(view, "#marketplace-more") end)
    assert has_element?(view, "#openvsx-filler\\.ext45")
    assert :counters.get(counter, 1) == 2

    # The same query again (typed blanks): no request.
    search(view, "rocket ")
    assert :counters.get(counter, 1) == 2

    # Clearing it shows the installed plugins again.
    run(view, "workbench.extensions.action.clearExtensionsSearchResults", [])
    assert has_element?(view, "#plugins-workbench\\.extensions\\.installed")
    refute has_element?(view, "#marketplace")

    # Searched again: from the cache.
    search(view, "rocket")
    eventually(fn -> has_element?(view, "#openvsx-acme\\.rocket") end)
    assert :counters.get(counter, 1) == 2
  end

  test "install, then update, from the results", %{conn: conn, counter: counter} do
    {:ok, version} = Agent.start_link(fn -> "1.0.0" end)
    stub_open_vsx(counter, 1, version)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-extensions") |> render_click()
    search(view, "rocket")
    eventually(fn -> has_element?(view, "#openvsx-acme\\.rocket") end)

    view |> element("#openvsx-acme\\.rocket button", "Install") |> render_click()
    eventually(fn -> has_element?(view, "#openvsx-acme\\.rocket", "installed") end)
    refute has_element?(view, "#openvsx-acme\\.rocket button", "Install")
    assert %{version: "1.0.0", scope: :user} = Plugins.get("rocket")
    assert render(view) =~ "Installed acme.rocket as the plugin rocket"

    # A newer version on Open VSX: Update.
    Agent.update(version, fn _ -> "1.1.0" end)
    OpenVsx.reset()
    search(view, "rocket2")
    search(view, "rocket")
    eventually(fn -> has_element?(view, "#openvsx-acme\\.rocket button", "Update") end)
    view |> element("#openvsx-acme\\.rocket button", "Update") |> render_click()
    eventually(fn -> match?(%{version: "1.1.0"}, Plugins.get("rocket")) end)
    eventually(fn -> has_element?(view, "#openvsx-acme\\.rocket", "installed") end)
  end

  test "Open VSX being down is a message with Try again", %{conn: conn} do
    Req.Test.stub(OpenVsx, &Req.Test.transport_error(&1, :econnrefused))
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-extensions") |> render_click()
    search(view, "rocket")

    eventually(fn -> has_element?(view, "#marketplace-error", "Can't reach Open VSX") end)
    refute has_element?(view, "#marketplace-empty")

    counter = :counters.new(1, [])
    {:ok, version} = Agent.start_link(fn -> "1.0.0" end)
    stub_open_vsx(counter, 1, version)
    view |> element("#marketplace-error button", "Try again") |> render_click()
    eventually(fn -> has_element?(view, "#openvsx-acme\\.rocket") end)
  end

  test "a result's details: README and Install", %{conn: conn, counter: counter} do
    {:ok, version} = Agent.start_link(fn -> "1.0.0" end)
    stub_open_vsx(counter, 1, version)
    {:ok, view, _html} = live(conn, ~p"/")

    run(view, "extension.open", ["acme.rocket"])
    eventually(fn -> has_element?(view, "#extension-acme\\.rocket[data-source=openvsx]") end)

    assert has_element?(view, "#extension-acme\\.rocket h1", "Rocket")
    assert has_element?(view, "#extension-acme\\.rocket", "ACME Corp")

    assert view
           |> element("#extension-acme\\.rocket-readme")
           |> render() =~ "Goes **up**."

    assert has_element?(view, "[data-path='extension:acme.rocket']", "Extension: Rocket")

    view |> element("#extension-acme\\.rocket button", "Install") |> render_click()
    eventually(fn -> has_element?(view, "#extension-acme\\.rocket button", "Uninstall") end)
    assert Plugins.get("rocket")

    # Its plugin's own details say where it came from.
    view |> element("#extension-acme\\.rocket button", "Show Installed") |> render_click()
    assert has_element?(view, "#extension-rocket", "From Open VSX (acme.rocket)")
  end

  test "a failed install is reported and leaves nothing", %{conn: conn} do
    Req.Test.stub(OpenVsx, fn conn ->
      case conn.request_path do
        "/api/acme/rocket" -> Req.Test.json(conn, rocket("1.0.0"))
        _ -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "Storage is down"})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    run(view, "workbench.extensions.installExtension", ["acme.rocket"])
    eventually(fn -> render(view) =~ "Can&#39;t install acme.rocket" end)
    assert Plugins.get("rocket") == nil
  end

  test "an extension without a package for this platform can't be installed", %{conn: conn} do
    json =
      Map.put(rocket("1.0.0"), "downloads", %{
        "win32-x64" => "http://openvsx.test/api/acme/rocket/win32-x64/1.0.0/file/rocket.vsix"
      })

    Req.Test.stub(OpenVsx, fn conn ->
      case conn.request_path do
        "/api/acme/rocket" -> Req.Test.json(conn, json)
        _ -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "Not found"})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    run(view, "extension.open", ["acme.rocket"])
    eventually(fn -> has_element?(view, "#extension-acme\\.rocket[data-source=openvsx]") end)

    assert has_element?(
             view,
             "#extension-acme\\.rocket-unavailable",
             "Not available for linux-x64 (only for win32-x64)."
           )

    refute has_element?(view, "#extension-acme\\.rocket button", "Install")
    refute has_element?(view, "#extension-acme\\.rocket-platform")
  end

  test "the details say which platform's package installs", %{conn: conn, counter: counter} do
    {:ok, version} = Agent.start_link(fn -> "1.0.0" end)
    stub_open_vsx(counter, 1, version)
    {:ok, view, _html} = live(conn, ~p"/")
    run(view, "extension.open", ["acme.rocket"])
    eventually(fn -> has_element?(view, "#extension-acme\\.rocket-platform") end)
    # Its package has no platform of its own.
    assert has_element?(view, "#extension-acme\\.rocket-platform[data-platform=universal]")
  end
end

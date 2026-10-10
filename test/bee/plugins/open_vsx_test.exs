defmodule Bee.Plugins.OpenVsxTest do
  # Plugins and the Open VSX client are global; Req.Test stubs are shared.
  use ExUnit.Case, async: false

  alias Bee.Plugins
  alias Bee.Plugins.OpenVsx

  @moduletag :capture_log

  setup do
    Req.Test.set_req_test_to_shared()
    OpenVsx.reset()
    File.rm_rf!(Plugins.user_dir())
    counter = :counters.new(1, [])
    # Packages are picked for this platform.
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

  # Open VSX, as a plug: `routes` maps a request path to a response
  # function (conn -> conn); every request is counted.
  defp stub(counter, routes) do
    Req.Test.stub(OpenVsx, fn conn ->
      :counters.add(counter, 1, 1)

      case Map.fetch(routes, conn.request_path) do
        {:ok, fun} -> fun.(conn)
        :error -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "Not found"})
      end
    end)
  end

  defp requests(counter), do: :counters.get(counter, 1)

  @search %{
    "offset" => 0,
    "totalSize" => 2,
    "extensions" => [
      %{
        "namespace" => "dracula-theme",
        "name" => "theme-dracula",
        "displayName" => "Dracula Official",
        "description" => "Official Dracula Theme",
        "version" => "2.25.1",
        "downloadCount" => 1_500_000,
        "averageRating" => 4.5,
        "verified" => true,
        "files" => %{"icon" => "http://openvsx.test/api/dracula-theme/theme-dracula/icon.png"}
      },
      %{"namespace" => "x", "name" => "bare"}
    ]
  }

  test "search parses Open VSX's answer and caches it", %{counter: counter} do
    stub(counter, %{
      "/api/-/search" => fn conn ->
        assert %{"query" => "dracula", "size" => "30"} =
                 Plug.Conn.fetch_query_params(conn).query_params

        Req.Test.json(conn, @search)
      end
    })

    assert {:ok, %{total: 2, offset: 0, extensions: [dracula, bare]}} = OpenVsx.search("dracula")

    assert dracula == %{
             id: "dracula-theme.theme-dracula",
             namespace: "dracula-theme",
             name: "theme-dracula",
             display_name: "Dracula Official",
             description: "Official Dracula Theme",
             version: "2.25.1",
             icon: "http://openvsx.test/api/dracula-theme/theme-dracula/icon.png",
             downloads: 1_500_000,
             rating: 4.5,
             verified: true,
             deprecated: false
           }

    assert %{id: "x.bare", display_name: "bare", icon: nil, downloads: 0} = bare

    # Again, and with blanks around it: from the cache.
    assert {:ok, %{total: 2}} = OpenVsx.search("  dracula ")
    assert requests(counter) == 1

    # Another page is another request.
    assert {:ok, _} = OpenVsx.search("dracula", offset: 30)
    assert requests(counter) == 2
  end

  test "the same request asked for at once goes out once", %{counter: counter} do
    test = self()

    stub(counter, %{
      "/api/-/search" => fn conn ->
        send(test, :requested)
        Process.sleep(100)
        Req.Test.json(conn, @search)
      end
    })

    tasks = for _ <- 1..5, do: Task.async(fn -> OpenVsx.search("slow") end)
    assert Enum.all?(Task.await_many(tasks), &match?({:ok, %{total: 2}}, &1))
    assert requests(counter) == 1
  end

  test "network errors and Open VSX's errors are messages", %{counter: counter} do
    Req.Test.stub(OpenVsx, fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, message} = OpenVsx.search("down")
    assert message =~ "Can't reach Open VSX"
    assert message =~ "connection refused"

    # Failures aren't cached: asked again, tried again.
    assert {:error, _} = OpenVsx.search("down")
    assert requests(counter) == 2

    stub(counter, %{
      "/api/-/search" => fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "Search is broken"})
      end
    })

    assert {:error, "Open VSX: Search is broken"} = OpenVsx.search("broken")
    assert {:error, "Open VSX: Not found"} = OpenVsx.extension("nobody.nothing")
    assert {:error, "not an extension id: ../etc" <> _} = OpenVsx.extension("../etc")
  end

  test "a 429 stops all requests until its Retry-After", %{counter: counter} do
    stub(counter, %{
      "/api/-/search" => fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "Too many requests"})
      end
    })

    assert {:error, message} = OpenVsx.search("a")
    assert message =~ "limiting Bee's requests; try again in 30 seconds"

    # Not even sent: other requests wait too.
    assert {:error, message} = OpenVsx.search("b")
    assert message =~ "try again in"
    assert {:error, _} = OpenVsx.extension("x.y")
    assert requests(counter) == 1
  end

  test "X-RateLimit-Remaining: 0 waits for X-RateLimit-Reset", %{counter: counter} do
    stub(counter, %{
      "/api/-/search" => fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", "20")
        |> Req.Test.json(@search)
      end
    })

    # This answer is fine, and cached.
    assert {:ok, _} = OpenVsx.search("a")
    assert {:ok, _} = OpenVsx.search("a")
    # The next one waits.
    assert {:error, message} = OpenVsx.search("b")
    assert message =~ "try again in 20 seconds"
    assert requests(counter) == 1
  end

  test "Bee itself sends at most 60 requests a minute", %{counter: counter} do
    stub(counter, %{"/api/-/search" => &Req.Test.json(&1, @search)})

    for i <- 1..60, do: assert({:ok, _} = OpenVsx.search("q#{i}"))
    assert {:error, message} = OpenVsx.search("one too many")
    assert message =~ "too many requests to Open VSX"
    assert requests(counter) == 60
    # Cached answers are still there.
    assert {:ok, _} = OpenVsx.search("q1")
  end

  # A .vsix (zip) of `package`, plus a README.
  defp vsix(package) do
    {:ok, {_, zip}} =
      :zip.create(
        ~c"x.vsix",
        [
          {~c"extension/package.json", Jason.encode!(package)},
          {~c"extension/README.md", "# Hi"}
        ],
        [:memory]
      )

    zip
  end

  defp extension_json(version, extra \\ %{}) do
    Map.merge(
      %{
        "namespace" => "acme",
        "name" => "rocket",
        "displayName" => "Rocket",
        "version" => version,
        "namespaceDisplayName" => "ACME Corp",
        "license" => "MIT",
        "repository" => "https://github.com/acme/rocket.git",
        "categories" => ["Programming Languages"],
        "files" => %{
          "download" => "http://openvsx.test/api/acme/rocket/#{version}/file/rocket.vsix",
          "readme" => "http://openvsx.test/api/acme/rocket/#{version}/file/README.md"
        }
      },
      extra
    )
  end

  test "details: metadata and README", %{counter: counter} do
    stub(counter, %{
      "/api/acme/rocket" => &Req.Test.json(&1, extension_json("1.0.0")),
      "/api/acme/rocket/1.0.0/file/README.md" => &Req.Test.text(&1, "# Rocket\n\nGoes up.")
    })

    assert {:ok, details} = OpenVsx.details("acme.rocket")

    assert %{
             id: "acme.rocket",
             display_name: "Rocket",
             publisher: "ACME Corp",
             license: "MIT",
             repository: "https://github.com/acme/rocket",
             categories: ["Programming Languages"],
             readme: "# Rocket\n\nGoes up."
           } = details

    assert {:ok, ^details} = OpenVsx.details("acme.rocket")
    assert requests(counter) == 2
  end

  test "a README elsewhere than Open VSX isn't fetched", %{counter: counter} do
    json = put_in(extension_json("1.0.0"), ["files", "readme"], "https://evil.example/x.md")
    stub(counter, %{"/api/acme/rocket" => &Req.Test.json(&1, json)})

    assert {:ok, %{readme: nil}} = OpenVsx.details("acme.rocket")
    assert requests(counter) == 1
  end

  test "install downloads the latest version and installs it; again updates it", %{
    counter: counter
  } do
    # Any extension installs, themes or not.
    package = %{"name" => "rocket", "version" => "1.0.0", "contributes" => %{"commands" => []}}
    version = :atomics.new(1, [])
    :atomics.put(version, 1, 1)
    current = fn -> "#{:atomics.get(version, 1)}.0.0" end

    stub(counter, %{
      "/api/acme/rocket" => fn conn -> Req.Test.json(conn, extension_json(current.())) end,
      "/api/acme/rocket/1.0.0/file/rocket.vsix" => fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, vsix(package))
      end,
      "/api/acme/rocket/2.0.0/file/rocket.vsix" => fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, vsix(%{package | "version" => "2.0.0"}))
      end
    })

    assert OpenVsx.installed() == %{}
    assert {:ok, "rocket"} = OpenVsx.install("acme.rocket")
    assert %{scope: :user, version: "1.0.0"} = Plugins.get("rocket")
    assert OpenVsx.installed() == %{"acme.rocket" => %{plugin: "rocket", version: "1.0.0"}}
    assert File.read!(Path.join([Plugins.user_dir(), "rocket", "README.md"])) == "# Hi"

    # A new version: installing asks Open VSX again (not the cache).
    :atomics.put(version, 1, 2)
    assert {:ok, "rocket"} = OpenVsx.install("acme.rocket")
    assert %{version: "2.0.0"} = Plugins.get("rocket")
    assert requests(counter) == 4

    # Another extension with the same name doesn't replace it.
    assert {:error, message} =
             Bee.Plugins.Vsix.install(
               write_vsix(vsix(%{package | "version" => "9.0.0"})),
               source: "other.rocket"
             )

    assert message =~ "acme.rocket, another extension named rocket, is installed"
  end

  test "install brings the extensions it needs, and theirs, once", %{counter: counter} do
    # rocket needs fuel (which needs rocket, and tank) and packs paint and
    # ghost, which Open VSX doesn't have; tank is installed already.
    packages = %{
      "rocket" => %{
        "extensionDependencies" => ["acme.fuel"],
        "extensionPack" => ["acme.paint", "acme.ghost"]
      },
      "fuel" => %{"main" => "./fuel.js", "extensionDependencies" => ["acme.Rocket", "acme.tank"]},
      "paint" => %{},
      "tank" => %{}
    }

    package = fn name ->
      Map.merge(%{"name" => name, "publisher" => "acme", "version" => "1.0.0"}, packages[name])
    end

    routes =
      for {name, _} <- packages, name != "tank", reduce: %{} do
        routes ->
          json =
            extension_json("1.0.0", %{
              "name" => name,
              "files" => %{
                "download" => "http://openvsx.test/api/acme/#{name}/1.0.0/file/#{name}.vsix"
              }
            })

          routes
          |> Map.put("/api/acme/#{name}", &Req.Test.json(&1, json))
          |> Map.put("/api/acme/#{name}/1.0.0/file/#{name}.vsix", fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream")
            |> Plug.Conn.send_resp(200, vsix(package.(name)))
          end)
      end

    stub(counter, routes)
    # From a VSIX file: not Open VSX's, but there.
    assert {:ok, "tank"} = Bee.Plugins.Vsix.install(write_vsix(vsix(package.("tank"))))

    assert {:ok, "rocket"} = OpenVsx.install("acme.rocket")

    assert OpenVsx.installed() |> Map.keys() |> Enum.sort() ==
             ["acme.fuel", "acme.paint", "acme.rocket"]

    # Each asked for and downloaded once; the missing one asked for once.
    assert requests(counter) == 7
    # Nothing is lacking now.
    assert Bee.Plugins.Details.get(Plugins.get("rocket")).missing_dependencies == []
    assert Bee.Plugins.Details.get(Plugins.get("fuel")).missing_dependencies == []

    # Without what its code needs, its page says so.
    Plugins.uninstall("tank")
    assert Bee.Plugins.Details.get(Plugins.get("fuel")).missing_dependencies == ["acme.tank"]
  end

  test "a failed download installs nothing", %{counter: counter} do
    stub(counter, %{"/api/acme/rocket" => &Req.Test.json(&1, extension_json("1.0.0"))})

    assert {:error, "Open VSX: not found"} = OpenVsx.install("acme.rocket")
    assert Plugins.get("rocket") == nil
  end

  test "newer?/2" do
    assert OpenVsx.newer?("1.10.0", "1.9.0")
    refute OpenVsx.newer?("1.9.0", "1.10.0")
    refute OpenVsx.newer?("1.0.0", "1.0.0")
    assert OpenVsx.newer?("2024.1", "2023.9")
    refute OpenVsx.newer?(nil, "1.0.0")
  end

  defp write_vsix(data) do
    path = Path.join(System.tmp_dir!(), "bee-test-#{System.unique_integer([:positive])}.vsix")
    File.write!(path, data)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "target platforms" do
    test "the platform Bee runs on, as Open VSX names it" do
      linux = {:unix, :linux}
      assert OpenVsx.platform_for(linux, "x86_64-pc-linux-gnu", nil) == "linux-x64"
      assert OpenVsx.platform_for(linux, "aarch64-unknown-linux-gnu", nil) == "linux-arm64"
      assert OpenVsx.platform_for(linux, "armv7l-unknown-linux-gnueabihf", nil) == "linux-armhf"
      assert OpenVsx.platform_for(linux, "x86_64-alpine-linux-musl", nil) == "alpine-x64"
      assert OpenVsx.platform_for(linux, "aarch64-alpine-linux-musl", nil) == "alpine-arm64"

      assert OpenVsx.platform_for({:unix, :darwin}, "aarch64-apple-darwin23.4.0", nil) ==
               "darwin-arm64"

      assert OpenVsx.platform_for({:unix, :darwin}, "x86_64-apple-darwin21.6.0", nil) ==
               "darwin-x64"

      assert OpenVsx.platform_for({:win32, :nt}, "win32", "AMD64") == "win32-x64"
      assert OpenVsx.platform_for({:win32, :nt}, "win32", "ARM64") == "win32-arm64"
      assert OpenVsx.platform_for({:win32, :nt}, "win32", "x86") == "win32-ia32"
      # None of Open VSX's.
      assert OpenVsx.platform_for({:unix, :freebsd}, "amd64-portbld-freebsd14.0", nil) ==
               "universal"

      assert OpenVsx.platform_for(linux, "riscv64-unknown-linux-gnu", nil) == "universal"
      assert OpenVsx.platform_for({:win32, :nt}, "win32", nil) == "universal"
    end

    defp package_routes(version, platforms) do
      for platform <- platforms, into: %{} do
        {"/api/acme/rocket/#{platform}/#{version}/file/rocket.vsix",
         fn conn ->
           package = %{"name" => "rocket", "version" => version, "contributes" => %{}}
           Plug.Conn.send_resp(conn, 200, vsix(package))
         end}
      end
    end

    defp downloads(version, platforms),
      do:
        Map.new(platforms, fn platform ->
          {platform,
           "http://openvsx.test/api/acme/rocket/#{platform}/#{version}/file/rocket.vsix"}
        end)

    test "installs this platform's package, else the universal one", %{counter: counter} do
      platforms = ~w(darwin-arm64 linux-x64 universal win32-x64)
      json = extension_json("1.0.0", %{"downloads" => downloads("1.0.0", platforms)})

      stub(
        counter,
        Map.put(package_routes("1.0.0", platforms), "/api/acme/rocket", &Req.Test.json(&1, json))
      )

      assert {:ok, ext} = OpenVsx.extension("acme.rocket")
      assert ext.target_platform == "linux-x64"
      assert ext.platforms == platforms

      assert ext.download ==
               "http://openvsx.test/api/acme/rocket/linux-x64/1.0.0/file/rocket.vsix"

      assert {:ok, "rocket"} = OpenVsx.install("acme.rocket")
      dir = Path.join(Plugins.user_dir(), "rocket")

      assert %{"openVsx" => "acme.rocket", "targetPlatform" => "linux-x64"} =
               Bee.Plugins.Vsix.marker(dir)

      assert %{target_platform: "linux-x64"} = Bee.Plugins.Details.get(Plugins.get("rocket"))

      # Without a linux-x64 one: universal.
      OpenVsx.reset()
      platforms = ~w(darwin-arm64 universal)
      json = extension_json("1.0.0", %{"downloads" => downloads("1.0.0", platforms)})

      stub(
        counter,
        Map.put(package_routes("1.0.0", platforms), "/api/acme/rocket", &Req.Test.json(&1, json))
      )

      assert {:ok, %{target_platform: "universal"}} = OpenVsx.extension("acme.rocket")
    end

    test "the latest version without one for this platform: the latest with one", %{
      counter: counter
    } do
      latest = extension_json("2.0.0", %{"downloads" => downloads("2.0.0", ~w(win32-x64))})

      older =
        extension_json("1.5.0", %{"downloads" => downloads("1.5.0", ~w(linux-x64 win32-x64))})

      stub(
        counter,
        package_routes("1.5.0", ~w(linux-x64))
        |> Map.put("/api/acme/rocket", &Req.Test.json(&1, latest))
        |> Map.put("/api/acme/rocket/linux-x64", &Req.Test.json(&1, older))
      )

      assert {:ok, %{version: "1.5.0", target_platform: "linux-x64"}} =
               OpenVsx.extension("acme.rocket")

      assert {:ok, "rocket"} = OpenVsx.install("acme.rocket")
      assert %{version: "1.5.0"} = Plugins.get("rocket")
    end

    test "no package for this platform: nothing to install, and said so", %{counter: counter} do
      json =
        extension_json("1.0.0", %{"downloads" => downloads("1.0.0", ~w(darwin-arm64 win32-x64))})

      stub(counter, %{"/api/acme/rocket" => &Req.Test.json(&1, json)})

      assert {:ok, ext} = OpenVsx.extension("acme.rocket")
      assert %{download: nil, target_platform: nil, platforms: ~w(darwin-arm64 win32-x64)} = ext
      # The metadata, then linux-x64's and universal's latest (404s).
      assert requests(counter) == 3
      # Those 404s are cached too.
      assert {:ok, _} = OpenVsx.extension("acme.rocket")
      assert requests(counter) == 3

      assert {:error, message} = OpenVsx.install("acme.rocket")

      assert message ==
               "acme.rocket has no package for linux-x64 (only for darwin-arm64, win32-x64)"

      assert Plugins.get("rocket") == nil
    end
  end
end

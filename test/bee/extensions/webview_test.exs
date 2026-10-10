defmodule Bee.Extensions.WebviewTest do
  # Webview panels of extensions (vscode.window.createWebviewPanel): the
  # store, the pages BeeWeb.WebviewController serves, and the hello-webview
  # fixture's code (test/fixtures/extensions/hello-webview) run in the
  # extension host, the test being its window.
  use BeeWeb.ConnCase, async: false

  alias Bee.Extensions.Host
  alias Bee.Plugins
  alias Bee.Plugins.Context
  alias Bee.Webviews

  @moduletag :capture_log

  defp eventually(fun, tries \\ 150) do
    cond do
      result = fun.() -> result
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  describe "Bee.Webviews" do
    setup do
      dir = Path.join(System.tmp_dir!(), "bee_webviews_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "media/sub"))
      File.mkdir_p!(Path.join(dir, "private"))
      File.write!(Path.join(dir, "media/a.css"), "a{}")
      File.write!(Path.join(dir, "media/sub/b.txt"), "b")
      File.write!(Path.join(dir, "private/secret.txt"), "secret")
      File.ln_s!(Path.join(dir, "private/secret.txt"), Path.join(dir, "media/link.txt"))
      Webviews.subscribe("/wv")

      on_exit(fn ->
        Webviews.clear("/wv")
        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "a panel's life is told to the workspace's windows", %{dir: dir} do
      panel =
        Webviews.open("/wv", "1", %{
          extension: "x",
          title: "One",
          scripts?: true,
          roots: [dir],
          bogus: 1
        })

      assert_receive {:webview, "1", :opened}
      assert %{id: "1", title: "One", html: "", version: 0, scripts?: true, state: nil} = panel
      assert byte_size(panel.token) >= 32
      refute Map.has_key?(panel, :bogus)
      assert Webviews.by_token(panel.token) == {"/wv", panel}
      assert Webviews.by_token("nope") == nil

      # Its HTML set – even the same again – is a page loaded afresh.
      Webviews.update("/wv", "1", %{html: "<p>hi</p>"})
      assert_receive {:webview, "1", :changed}
      Webviews.update("/wv", "1", %{html: "<p>hi</p>"})
      assert_receive {:webview, "1", :changed}
      assert %{html: "<p>hi</p>", version: 2} = Webviews.get("/wv", "1")

      Webviews.update("/wv", "1", %{title: "Uno"})
      assert_receive {:webview, "1", :changed}
      Webviews.update("/wv", "1", %{title: "Uno"})
      refute_receive {:webview, "1", :changed}, 50
      assert %{title: "Uno", version: 2} = Webviews.get("/wv", "1")

      Webviews.put_state("/wv", "1", %{"n" => 1})
      assert Webviews.get("/wv", "1").state == %{"n" => 1}
      Webviews.post("/wv", "1", %{"a" => 1})
      assert_receive {:webview, "1", {:message, %{"a" => 1}}}
      Webviews.reveal("/wv", "1")
      assert_receive {:webview, "1", :revealed}

      Webviews.open("/wv", "2", %{title: "Two"})
      Webviews.open("/wv", "10", %{title: "Ten"})
      assert Enum.map(Webviews.list("/wv"), & &1.id) == ["1", "2", "10"]
      assert Webviews.list("/other") == []

      Webviews.dispose("/wv", "1")
      assert_receive {:webview, "1", :disposed}
      assert Webviews.get("/wv", "1") == nil
      Webviews.update("/wv", "1", %{title: "gone"})
      Webviews.clear("/wv")
      assert_receive {:webview, "2", :disposed}
      assert_receive {:webview, "10", :disposed}
      assert Webviews.list("/wv") == []
    end

    test "a panel's files are those under its roots", %{dir: dir} do
      media = Path.join(dir, "media")
      panel = %{roots: [media]}
      assert Webviews.resource(panel, Path.join(media, "a.css")) == Path.join(media, "a.css")
      assert Webviews.resource(panel, Path.join(media, "sub/b.txt"))
      # Not outside them, however it is written; not a link leading out.
      refute Webviews.resource(panel, Path.join(dir, "private/secret.txt"))
      refute Webviews.resource(panel, Path.join(media, "../private/secret.txt"))
      refute Webviews.resource(panel, Path.join(media, "link.txt"))
      refute Webviews.resource(panel, media)
      refute Webviews.resource(panel, Path.join(media, "missing.css"))
      refute Webviews.resource(%{roots: []}, Path.join(media, "a.css"))
    end

    test "the controller serves its page, with Bee's part first, and its files", %{
      conn: conn,
      dir: dir
    } do
      media = Path.join(dir, "media")
      panel = Webviews.open("/wv", "1", %{title: "One", scripts?: true, roots: [media]})

      Webviews.update("/wv", "1", %{
        html:
          ~s(<!DOCTYPE html><html><head lang="en"><meta http-equiv="Content-Security-Policy" content="default-src 'none'">) <>
            ~s(<link rel="stylesheet" href="https://file.bee-webview.invalid#{media}/a.css"></head><body>hi</body></html>)
      })

      Webviews.put_state("/wv", "1", %{"x" => "</script>"})

      conn1 = get(conn, "/webview/#{panel.token}/")
      html = response(conn1, 200)
      assert response_content_type(conn1, :html)

      assert get_resp_header(conn1, "content-security-policy") == [
               "sandbox allow-scripts allow-forms allow-modals allow-popups allow-downloads"
             ]

      # Bee's part comes before the page's own policy, which would stop it.
      [before, _] = String.split(html, "<meta http-equiv")
      assert before =~ ~s(<head lang="en">)
      assert before =~ "acquireVsCodeApi"
      assert before =~ "--vscode-editor-background:#"
      assert before =~ ~s("kind":"vscode-dark")
      # The page's state, safely inside the script.
      assert before =~ ~S("state":{"x":"\u003C)
      assert length(String.split(html, "</script>")) == 2
      assert html =~ ~s(href="/webview/#{panel.token}/file#{media}/a.css")
      refute html =~ "bee-webview.invalid"

      conn2 = get(conn, "/webview/#{panel.token}/file#{media}/a.css")
      assert response(conn2, 200) == "a{}"
      assert response_content_type(conn2, :css)
      assert get_resp_header(conn2, "access-control-allow-origin") == ["*"]
      assert ["sandbox" <> _] = get_resp_header(conn2, "content-security-policy")

      assert response(get(conn, "/webview/#{panel.token}/file#{dir}/private/secret.txt"), 404)
      assert response(get(conn, "/webview/#{panel.token}/file#{media}/link.txt"), 404)
      assert response(get(conn, "/webview/#{panel.token}/other"), 404)
      assert response(get(conn, "/webview/wrong/"), 404)

      # A page without scripts, without a head.
      plain = Webviews.open("/wv", "2", %{title: "Two"})
      Webviews.update("/wv", "2", %{html: "<p>plain</p>"})
      conn3 = get(conn, "/webview/#{plain.token}/index.html")
      assert response(conn3, 200) =~ ~r/^<style id="_defaultStyles">.*<p>plain<\/p>$/s
      assert get_resp_header(conn3, "content-security-policy") == ["sandbox allow-forms"]

      Webviews.dispose("/wv", "1")
      assert response(get(conn, "/webview/#{panel.token}/"), 404)
    end

    test "the webview server gives a page its own origin, to local hosts only" do
      panel = Webviews.open("/wv", "1", %{title: "One", scripts?: true})
      Webviews.update("/wv", "1", %{html: "<p>hi</p>"})

      get = fn host, path ->
        Plug.Test.conn(:get, path)
        |> Map.put(:host, host)
        |> BeeWeb.WebviewServer.Plug.call([])
      end

      conn = get.("127.0.0.1", "/webview/#{panel.token}/")
      assert conn.status == 200
      assert conn.resp_body =~ "<p>hi</p>"

      assert Plug.Conn.get_resp_header(conn, "content-security-policy") == [
               "sandbox allow-scripts allow-forms allow-modals allow-popups allow-downloads allow-same-origin"
             ]

      # Nothing else of Bee's; not for a name pointed at this machine.
      assert get.("127.0.0.1", "/").status == 404
      assert get.("127.0.0.1", "/plugins/x/y").status == 404
      assert get.("evil.example", "/webview/#{panel.token}/").status == 404

      # It listens, on this machine, and windows here are told where.
      port = BeeWeb.WebviewServer.port()
      assert is_integer(port)
      assert BeeWeb.WebviewServer.origin("localhost") == "http://127.0.0.1:#{port}"
      assert BeeWeb.WebviewServer.origin("bee.example.com") == nil
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

      :ok =
        :gen_tcp.send(socket, "GET /webview/#{panel.token}/ HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")

      {:ok, answer} = :gen_tcp.recv(socket, 0, 2_000)
      assert answer =~ "200 OK"
      :gen_tcp.close(socket)
    end
  end

  describe "with the hello-webview extension" do
    @describetag :node

    setup do
      root = Bee.Workspace.root()
      File.rm_rf!(root)
      File.mkdir_p!(root)
      {:ok, ^root} = Bee.Workspace.open(root)
      File.rm_rf!(Plugins.user_dir())
      dir = Bee.Test.Extensions.install("hello-webview")
      Bee.API.subscribe_window(root)
      Webviews.subscribe(root)

      on_exit(fn ->
        File.rm_rf!(Plugins.user_dir())
        Plugins.reload()
        File.rm_rf!(root)
      end)

      %{root: root, dir: dir}
    end

    defp run(root, command) do
      Plugins.execute_extension("hello-webview", command, %Context{root: root, window: self()})
    end

    test "its panel: HTML, files, messages both ways, title, closing", %{
      root: root,
      dir: dir,
      conn: conn
    } do
      run(root, "helloWebview.open")
      assert_receive {:webview, id, :opened}, 5_000
      assert_receive {:webview, ^id, :changed}
      # Posted at once: for the page, when it is there.
      assert_receive {:webview, ^id, {:message, %{"type" => "hello"}}}

      panel = Webviews.get(root, id)

      assert %{
               extension: "hello-webview",
               view_type: "helloWebview",
               title: "Hello Webview",
               scripts?: true,
               version: 1
             } = panel

      assert panel.roots == [Path.join(dir, "media")]
      assert panel.html =~ ~s(<h1 id="heading">first</h1>)
      assert panel.html =~ ~s(img-src 'self';)

      # Its page as the frame gets it; its files, and not others.
      html = response(get(conn, "/webview/#{panel.token}/"), 200)
      assert html =~ ~s(href="/webview/#{panel.token}/file#{dir}/media/style.css")

      assert response(get(conn, "/webview/#{panel.token}/file#{dir}/media/bee.svg"), 200) =~
               "<svg"

      assert response(get(conn, "/webview/#{panel.token}/file#{dir}/package.json"), 404)

      # The page posts; the extension answers and renames the panel.
      Host.webview(root, id, {:message, %{"type" => "ping", "n" => 3}})
      assert_receive {:webview, ^id, {:message, %{"type" => "pong", "n" => 3}}}, 5_000
      eventually(fn -> Webviews.get(root, id).title == "Pong 3" end)

      # Its tab hidden and shown.
      Host.webview(root, id, {:state, false, false})
      eventually(fn -> "webview active false" in Host.log(root) end)

      # New HTML: loaded afresh. The command again: brought to the front.
      run(root, "helloWebview.update")
      eventually(fn -> match?(%{version: 2}, Webviews.get(root, id)) end)
      assert Webviews.get(root, id).html =~ ~s(<h1 id="heading">second</h1>)
      run(root, "helloWebview.open")
      assert_receive {:webview, ^id, :revealed}, 5_000

      # Closed by the user: the extension hears of it.
      Host.webview(root, id, :closed)
      assert_receive {:webview, ^id, :disposed}, 5_000
      eventually(fn -> "webview disposed" in Host.log(root) end)
      assert Webviews.list(root) == []
    end

    test "closed by its extension; gone with it; an address for the browser", %{root: root} do
      run(root, "helloWebview.open")
      assert_receive {:webview, id, :opened}, 5_000
      run(root, "helloWebview.close")
      assert_receive {:webview, ^id, :disposed}, 5_000

      run(root, "helloWebview.plain")
      assert_receive {:webview, plain, :opened}, 5_000
      eventually(fn -> match?(%{scripts?: false, version: 1}, Webviews.get(root, plain)) end)
      # No roots given: the workspace and the extension's folder.
      assert root in Webviews.get(root, plain).roots

      run(root, "helloWebview.external")
      assert_receive {:bee_api, {:open_external, "https://example.com/from-extension"}}, 5_000

      Plugins.uninstall("hello-webview")
      assert_receive {:webview, ^plain, :disposed}, 5_000
    end
  end
end

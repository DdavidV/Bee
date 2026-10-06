defmodule BeeWeb.AccessTest do
  # Changes Bee's access config, which is global.
  use BeeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @token "test-token-0123456789-0123456789-abcdef"

  setup do
    old = Map.new([:access_token, :allowed_hosts], &{&1, Application.get_env(:bee, &1)})

    on_exit(fn ->
      for {key, value} <- old, do: Application.put_env(:bee, key, value)
      Bee.Access.init()
    end)

    Application.put_env(:bee, :access_token, @token)
    Application.put_env(:bee, :allowed_hosts, ["localhost", "127.0.0.1", "[::1]"])
    Bee.Access.init()
    %{conn: %{build_conn() | host: "localhost"}}
  end

  test "without the token or its cookie, nothing is served", %{conn: conn} do
    assert conn |> get("/") |> response(401) =~ "needs its token"
    assert build_local() |> get("/?token=wrong") |> response(401)
    assert build_local() |> get("/plugins/git/browser.js") |> response(401)
  end

  test "the token is traded for a cookie and dropped from the address", %{conn: conn} do
    conn = get(conn, "/?token=#{@token}&folder=x")
    assert redirected_to(conn, 302) == "/?folder=x"

    # The cookie is enough from now on.
    conn = conn |> recycle() |> Map.put(:host, "localhost")
    assert {:ok, _view, html} = live(conn, "/")
    assert html =~ "explorer"
  end

  test "a new token logs every browser out", %{conn: conn} do
    conn = get(conn, "/?token=#{@token}") |> recycle() |> Map.put(:host, "localhost")
    assert {:ok, _view, _html} = live(conn, "/")

    Application.put_env(:bee, :access_token, "another-token-0123456789-0123456789")
    Bee.Access.init()
    assert conn |> get("/") |> response(401)
  end

  test "only local host names are answered (DNS rebinding)" do
    assert %{build_conn() | host: "evil.example"} |> get("/?token=#{@token}") |> response(403)
    assert %{build_conn() | host: "127.0.0.1"} |> get("/?token=#{@token}") |> response(302)
    # Static files too.
    assert %{build_conn() | host: "evil.example"} |> get("/favicon.ico") |> response(403)
  end

  test "LiveView checks the session again on mount" do
    refute BeeWeb.Plugs.RequireToken.authorized?(%{})
    refute BeeWeb.Plugs.RequireToken.authorized?(%{"bee_access" => "forged"})

    assert BeeWeb.Plugs.RequireToken.authorized?(%{
             "bee_access" => Bee.Access.session_value()
           })
  end

  test "the token file is made once, readable only by you" do
    path = Path.join(Bee.Settings.user_dir(), "token")
    File.rm(path)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:bee, :access_token, :file)
    token = Bee.Access.init()
    assert byte_size(token) >= 40
    assert File.read!(path) == token
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bee.Access.init() == token

    assert Bee.Access.url("127.0.0.1", 4321) == "http://127.0.0.1:4321/?token=#{token}"
  end

  test "desktop mode never serves over HTTP" do
    old = Application.get_env(:phoenix, :serve_endpoints)
    on_exit(fn -> Application.put_env(:phoenix, :serve_endpoints, old) end)

    Application.put_env(:bee, :mode, :desktop)
    on_exit(fn -> Application.delete_env(:bee, :mode) end)

    # `mix phx.server` sets this; desktop mode turns it off again.
    Application.put_env(:phoenix, :serve_endpoints, true)
    Bee.Mode.prepare()
    assert Application.get_env(:phoenix, :serve_endpoints) == false
  end

  defp build_local, do: %{build_conn() | host: "localhost"}
end

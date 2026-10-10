defmodule BeeWeb.Plugs.RequireToken do
  @moduledoc """
  Server mode: a browser gets in with Bee's token (`?token=…`, from the
  address Bee prints when it starts), which this trades for a session
  cookie and drops from the address; afterwards the cookie is enough.
  Anything else is refused. See `Bee.Access`.
  """
  @behaviour Plug
  import Plug.Conn

  @session_key "bee_access"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Bee.Access.required?() and not webview?(conn), do: check(conn), else: conn
  end

  # A webview panel's page and files (BeeWeb.WebviewController): its frame
  # is apart from Bee's page and has no cookie; the panel's own token, in
  # the address, lets it in.
  defp webview?(conn), do: match?(["webview", _token | _], conn.path_info)

  defp check(conn) do
    conn = conn |> fetch_session() |> fetch_query_params()

    cond do
      Map.has_key?(conn.query_params, "token") ->
        if Bee.Access.valid?(conn.query_params["token"]) do
          conn
          |> put_session(@session_key, Bee.Access.session_value())
          |> configure_session(renew: true)
          |> redirect_without_token()
        else
          refuse(conn)
        end

      get_session(conn, @session_key) == Bee.Access.session_value() ->
        conn

      true ->
        refuse(conn)
    end
  end

  @doc "Whether a LiveView's session came from a browser that showed the token."
  def authorized?(session),
    do: not Bee.Access.required?() or session[@session_key] == Bee.Access.session_value()

  @doc "LiveView `on_mount`: a second check, on the session the page was rendered with."
  def on_mount(:default, _params, session, socket) do
    if authorized?(session), do: {:cont, socket}, else: {:halt, socket}
  end

  defp redirect_without_token(conn) do
    query = conn.query_params |> Map.delete("token") |> URI.encode_query()
    location = conn.request_path <> if(query == "", do: "", else: "?" <> query)

    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
    |> halt()
  end

  defp refuse(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(401, """
    <!doctype html><meta charset="utf-8"><title>Bee</title>
    <link rel="icon" type="image/svg+xml" href="/images/bee.svg">
    <style>.logo { width: 1.2em; height: 1.2em; vertical-align: -0.15em }</style>
    <body style="font-family: system-ui; padding: 2rem">
    <h1>#{BeeWeb.Logo.svg("logo")} Bee needs its token</h1>
    <p>Open the address Bee printed when it started – it ends in <code>?token=…</code>.</p>
    </body>
    """)
    |> halt()
  end
end

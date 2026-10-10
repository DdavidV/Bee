defmodule BeeWeb.PluginAssetController do
  @moduledoc """
  Serves the files of a loaded plugin the browser needs, and nothing else
  from its folder: `GET /plugins/:name/*path` must name its browser part
  (ES module), its stylesheet, an icon of one of its icon themes, or a TextMate grammar
  (see `Bee.Plugins.asset_path/2`).
  """
  use BeeWeb, :controller

  def show(conn, %{"name" => name, "path" => path}) do
    case Bee.Plugins.asset_path(name, Path.join(path)) do
      {:ok, file, :module} ->
        conn
        |> put_resp_content_type("text/javascript")
        # The URL carries a version (?v=), so a changed file gets a new URL.
        |> put_resp_header("cache-control", "no-cache")
        |> send_file(200, file)

      {:ok, file, :style} ->
        conn
        |> put_resp_content_type("text/css")
        |> put_resp_header("cache-control", "no-cache")
        |> send_file(200, file)

      # Fetched as text by the editor (vscode-textmate reads JSON and plist).
      {:ok, file, :grammar} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("content-security-policy", "default-src 'none'")
        |> send_file(200, file)

      {:ok, file, :icon} ->
        conn
        |> put_resp_content_type(MIME.from_path(file), nil)
        # Icon URLs carry the theme's version (?v=); explorers show many.
        |> put_resp_header("cache-control", "public, max-age=86400")
        # An SVG opened on its own must not run scripts on Bee's origin.
        |> put_resp_header(
          "content-security-policy",
          "default-src 'none'; style-src 'unsafe-inline'"
        )
        |> send_file(200, file)

      :error ->
        send_resp(conn, 404, "not found")
    end
  end
end

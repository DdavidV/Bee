defmodule BeeWeb.PluginAssetController do
  @moduledoc """
  Serves the browser part (ES module) of a loaded plugin, and nothing else
  from its folder: `GET /plugins/:name/*path` must name the file its
  manifest's `"browser"` points to (see `Bee.Plugins.browser_path/2`).
  """
  use BeeWeb, :controller

  def show(conn, %{"name" => name, "path" => path}) do
    case Bee.Plugins.browser_path(name, Path.join(path)) do
      {:ok, file} ->
        conn
        |> put_resp_content_type("text/javascript")
        # The URL carries a version (?v=), so a changed file gets a new URL.
        |> put_resp_header("cache-control", "no-cache")
        |> send_file(200, file)

      :error ->
        send_resp(conn, 404, "not found")
    end
  end
end

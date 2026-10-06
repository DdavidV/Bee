defmodule BeeWeb.Router do
  use BeeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BeeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BeeWeb do
    pipe_through :browser

    live_session :default, on_mount: BeeWeb.Plugs.RequireToken do
      live "/", EditorLive
    end
  end

  scope "/plugins", BeeWeb do
    get "/:name/*path", PluginAssetController, :show
  end

  if Application.compile_env(:bee, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BeeWeb.Telemetry
    end
  end
end

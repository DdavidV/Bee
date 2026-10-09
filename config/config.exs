import Config

config :bee, BeeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: BeeWeb.ErrorHTML, json: BeeWeb.ErrorJSON], layout: false],
  pubsub_server: Bee.PubSub,
  check_origin: ["//localhost", "//127.0.0.1", "//[::1]"],
  live_view: [signing_salt: "jCmPSOGj"]

config :phoenix,
  json_library: Jason,
  filter_parameters: ["password", "token"]

config :phoenix_live_view, root_tag_attribute: "phx-r"

config :logger, :default_formatter, format: "$time [$level] $message\n"

config :esbuild,
  version: "0.25.4",
  bee: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=. --loader:.wasm=file --public-path=/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.3",
  bee: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/css/app.css),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

import_config "#{config_env()}.exs"

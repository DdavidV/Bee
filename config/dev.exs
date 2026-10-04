import Config

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :bee, BeeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "zAjMy7r/b6GGX1dxrjZbIC1U9/zgIaaWnFFY4gud94i6olLOlv2EmYSVjug3V9rR",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:bee, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:bee, ~w(--watch)]}
  ]

config :bee, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

import Config

config :bee, dev_routes: true

config :bee, BeeWeb.Endpoint,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:bee, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:bee, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"lib/bee_web/router\.ex$"E,
      ~r"lib/bee_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

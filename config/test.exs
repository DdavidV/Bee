import Config

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true

# Schemas at web addresses: a Req.Test stub (Bee.JSONValidation.Schemas).
config :bee, Bee.JSONValidation.Schemas,
  req_options: [plug: {Req.Test, Bee.JSONValidation.Schemas}]

# Open VSX is never reached from tests: a Req.Test stub answers.
config :bee, Bee.Plugins.OpenVsx,
  base_url: "http://openvsx.test",
  req_options: [plug: {Req.Test, Bee.Plugins.OpenVsx}]

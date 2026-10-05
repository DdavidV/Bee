import Config

if System.get_env("PHX_SERVER") do
  config :bee, BeeWeb.Endpoint, server: true
end

config :bee, BeeWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :test do
  config :bee,
    workspace_root: Path.join(System.tmp_dir!(), "bee_test_workspace"),
    config_dir: Path.join(System.tmp_dir!(), "bee_test_config"),
    watch_files: false,
    plugin_timeout: 500,
    # Tests that need a built-in plugin (git) turn this on themselves.
    builtin_plugins: false
else
  # BEE_CONFIG_DIR: where settings.json / keybindings.json live (default ~/.config/bee)
  config :bee,
    workspace_root: System.get_env("BEE_ROOT") || File.cwd!(),
    config_dir: System.get_env("BEE_CONFIG_DIR")
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :bee, BeeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/bee_web/router\.ex$"E,
        ~r"lib/bee_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :bee, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :bee, BeeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end

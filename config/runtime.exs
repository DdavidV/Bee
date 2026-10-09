import Config

mode =
  case System.get_env("BEE_MODE", "server") do
    "server" -> :server
    "desktop" -> :desktop
    other -> raise "BEE_MODE must be \"server\" or \"desktop\", got: #{inspect(other)}"
  end

config :bee, :mode, mode

# Where extensions are searched and installed from (the Plugins view).
if url = System.get_env("BEE_OPEN_VSX_URL") do
  config :bee, Bee.Plugins.OpenVsx, base_url: url
end

# Which platform's packages to install (default: the one Bee runs on).
if platform = System.get_env("BEE_TARGET_PLATFORM") do
  config :bee, Bee.Plugins.OpenVsx, target_platform: platform
end

port =
  System.get_env("BEE_PORT") || System.get_env("PORT") ||
    if(config_env() == :prod, do: "0", else: "4000")

config :bee, BeeWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]

case mode do
  :server ->
    if config_env() == :prod or System.get_env("PHX_SERVER"),
      do: config(:bee, BeeWeb.Endpoint, server: true)

    config :bee, :access_token, System.get_env("BEE_TOKEN") || :file

    if extra = System.get_env("BEE_ALLOWED_HOSTS") do
      config :bee,
        allowed_hosts: ["localhost", "127.0.0.1", "[::1]" | String.split(extra, ",", trim: true)]
    end

  :desktop ->
    config :bee, BeeWeb.Endpoint, server: false
    config :bee, :access_token, false
    config :bee, :allowed_hosts, :any
    config :logger, :default_handler, config: [type: :standard_error]
end

if config_env() == :test do
  config :bee, BeeWeb.Endpoint,
    secret_key_base: "HKdFjnJaG1aFJFKXONoP0gmMqZgVSeMLWit5FvrlUiEsJb1pvhtIsz4/oTJSeZwJ"

  config :bee,
    workspace_root: Path.join(System.tmp_dir!(), "bee_test_workspace"),
    config_dir: Path.join(System.tmp_dir!(), "bee_test_config"),
    watch_files: false,
    plugin_timeout: 500,
    builtin_plugins: false,
    access_token: false,
    allowed_hosts: :any
else
  config_dir = System.get_env("BEE_CONFIG_DIR") || Path.expand("~/.config/bee")

  config :bee,
    workspace_root: System.get_env("BEE_ROOT") || File.cwd!(),
    config_dir: config_dir

  secret_file = Path.join(config_dir, "secret_key_base")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      case File.read(secret_file) do
        {:ok, secret} when byte_size(secret) >= 64 ->
          String.trim(secret)

        _ ->
          secret = :crypto.strong_rand_bytes(48) |> Base.encode64()
          File.mkdir_p!(config_dir)
          File.write!(secret_file, secret)
          File.chmod!(secret_file, 0o600)
          secret
      end

  config :bee, BeeWeb.Endpoint, secret_key_base: secret_key_base
end

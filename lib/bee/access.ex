defmodule Bee.Access do
  @moduledoc """
  Who may use Bee in server (browser) mode. Bee can open terminals, so a
  browser has to prove it was given Bee's address: the token in it.

  Opening `http://127.0.0.1:<port>/?token=<token>` once trades the token for
  a session cookie (`BeeWeb.Plugs.RequireToken`); requests without either
  are refused. The token is kept in `<config_dir>/token` (only readable by
  you), so the cookie stays good across restarts; delete the file to
  revoke every browser.

  `config :bee, :access_token`:

    * `:file` (default) – the token in `<config_dir>/token`, created on first run
    * a string – that token (`BEE_TOKEN`)
    * `false` – no token needed (tests)

  Requests must also name Bee by a local host (`Host` header,
  `BeeWeb.Plugs.CheckHost`): a web page can't reach Bee through a domain of
  its own pointed at 127.0.0.1 (DNS rebinding).
  """

  @key {__MODULE__, :token}

  @doc "Reads (or creates) the token. Called once at startup."
  def init do
    token =
      case Application.get_env(:bee, :access_token, :file) do
        false -> nil
        :file -> read_or_create(Path.join(Bee.Settings.user_dir(), "token"))
        token when is_binary(token) and token != "" -> token
      end

    :persistent_term.put(@key, token)
    token
  end

  @doc "The token, or nil when none is needed."
  def token, do: :persistent_term.get(@key, nil)

  def required?, do: token() != nil

  @doc "Whether `given` is the token (constant time)."
  def valid?(given) when is_binary(given) do
    case token() do
      nil -> true
      token -> Plug.Crypto.secure_compare(given, token)
    end
  end

  def valid?(_given), do: false

  @doc """
  What a session stores once the token was shown: a digest of it, so a new
  token (the file deleted) logs every browser out.
  """
  def session_value, do: token() && :crypto.hash(:sha256, token()) |> Base.url_encode64()

  @doc "Bee's address for a browser, with the token."
  def url(host, port) do
    query = if token(), do: "?token=" <> token(), else: ""
    "http://#{host}:#{port}/#{query}"
  end

  @doc "Hosts a request may name (`Host` header), or `:any`."
  def allowed_hosts,
    do: Application.get_env(:bee, :allowed_hosts, ["localhost", "127.0.0.1", "[::1]"])

  defp read_or_create(path) do
    case File.read(path) do
      {:ok, token} when byte_size(token) >= 32 ->
        String.trim(token)

      _ ->
        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, token)
        File.chmod!(path, 0o600)
        token
    end
  end
end

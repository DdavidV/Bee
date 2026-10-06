defmodule Desktop.Conn do
  @moduledoc """
  HTTP without a server: a `Plug.Conn` adapter that runs one request
  through the endpoint in memory, for `Desktop.Bridge`.
  """
  @behaviour Plug.Conn.Adapter

  @doc "Runs a request through `endpoint`: `{status, headers, body}`."
  def request(endpoint, method, url, headers, body) do
    conn = method |> conn(url, headers, body) |> endpoint.call(endpoint.init([]))

    case conn do
      %Plug.Conn{adapter: {__MODULE__, %{resp: {status, headers, body}}}} ->
        {status, headers, body}

      %Plug.Conn{} ->
        {404, [], ""}
    end
  end

  @doc "A conn for `url` with `headers` (`[name, value]` pairs), from 127.0.0.1."
  def conn(method, url, headers, body \\ "") do
    uri = URI.parse(url)
    path = uri.path || "/"

    %Plug.Conn{
      adapter: {__MODULE__, %{body: body, resp: nil}},
      owner: self(),
      method: String.upcase(method),
      scheme: if(uri.scheme in ["https", "wss"], do: :https, else: :http),
      host: uri.host || "localhost",
      port: uri.port || 80,
      request_path: path,
      path_info: String.split(path, "/", trim: true),
      query_string: uri.query || "",
      req_headers: Enum.map(headers, fn [k, v] -> {String.downcase(k), v} end),
      remote_ip: {127, 0, 0, 1}
    }
  end

  ## Plug.Conn.Adapter

  @impl true
  def send_resp(payload, status, headers, body) do
    body = IO.iodata_to_binary(body)
    {:ok, body, %{payload | resp: {status, headers, body}}}
  end

  @impl true
  def send_file(payload, status, headers, path, offset, length) do
    data = File.read!(path)
    length = if length == :all, do: byte_size(data) - offset, else: length
    {:ok, nil, %{payload | resp: {status, headers, binary_part(data, offset, length)}}}
  end

  @impl true
  def send_chunked(payload, status, headers),
    do: {:ok, nil, %{payload | resp: {status, headers, ""}}}

  @impl true
  def chunk(%{resp: {status, headers, sent}} = payload, body),
    do: {:ok, body, %{payload | resp: {status, headers, sent <> IO.iodata_to_binary(body)}}}

  @impl true
  def read_req_body(payload, _opts), do: {:ok, payload.body, %{payload | body: ""}}

  @impl true
  def inform(_payload, _status, _headers), do: {:error, :not_supported}

  @impl true
  def push(_payload, _path, _headers), do: {:error, :not_supported}

  @impl true
  def upgrade(_payload, _protocol, _opts), do: {:error, :not_supported}

  @impl true
  def get_peer_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}

  @impl true
  def get_sock_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0}

  @impl true
  def get_ssl_data(_payload), do: nil

  @impl true
  def get_http_protocol(_payload), do: :"HTTP/1.1"
end

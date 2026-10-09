defmodule Bee.JSONValidation.Schemas do
  @moduledoc """
  The JSON Schemas of `Bee.JSONValidation`, resolved and cached (Cachex,
  `#{inspect(__MODULE__)}.Cache`):

    * a file (in a plugin): until it changes
    * an `http(s)` address: fetched, for an hour; a failure for a minute,
      so a schema that can't be fetched isn't asked for on every edit

  `$ref`s to other schemas are fetched the same way
  (`ex_json_schema`'s `remote_schema_resolver` is `fetch_remote/1`); a
  file schema's relative ones are files next to it, never outside its
  folder.
  """

  require Logger

  @cache __MODULE__.Cache
  @ttl :timer.hours(1)
  @failure_ttl :timer.minutes(1)
  @max_size 10_000_000

  def child_spec(_opts), do: Supervisor.child_spec({Cachex, [name: @cache]}, id: @cache)

  @doc "The resolved schema at `url` (a file path or an http(s) address)."
  @spec get(String.t()) :: {:ok, ExJsonSchema.Schema.Root.t()} | {:error, String.t()}
  def get(url) do
    key = key(url)

    case Cachex.get(@cache, key) do
      {:ok, nil} ->
        result = load(url)
        ttl = if match?({:ok, _}, result) or not remote?(url), do: @ttl, else: @failure_ttl
        Cachex.put(@cache, key, result, expire: ttl)
        result

      {:ok, result} ->
        result
    end
  end

  @doc "The schema at `url` if it's loaded already (never loads it): `{:ok, root}` or :none."
  def cached(url) do
    case Cachex.get(@cache, key(url)) do
      {:ok, {:ok, root}} -> {:ok, root}
      _ -> :none
    end
  end

  # A file's key changes with it.
  defp key(url) do
    if remote?(url) do
      url
    else
      case File.stat(url, time: :posix) do
        {:ok, %{mtime: mtime, size: size}} -> {url, mtime, size}
        _ -> {url, nil, nil}
      end
    end
  end

  defp remote?(url), do: String.starts_with?(url, ["http://", "https://"])

  defp load(url) do
    with {:ok, schema} <- read(url) do
      # Relative $refs of a file schema: next to it.
      schema =
        if remote?(url) or not is_map(schema),
          do: schema,
          else: Map.put_new(schema, id_key(schema), "file://" <> url)

      Process.put({__MODULE__, :root_dir}, if(remote?(url), do: nil, else: Path.dirname(url)))

      try do
        {:ok, ExJsonSchema.Schema.resolve(schema)}
      rescue
        e in ExJsonSchema.Schema.UnsupportedSchemaVersionError ->
          {:error, Exception.message(e)}

        e ->
          {:error, "invalid schema: " <> Exception.message(e)}
      after
        Process.delete({__MODULE__, :root_dir})
      end
    end
  end

  # Draft 4 calls it "id", later ones "$id".
  defp id_key(%{"$schema" => "http://json-schema.org/draft-04/" <> _}), do: "id"
  defp id_key(_schema), do: "$id"

  @doc false
  # ex_json_schema's remote_schema_resolver: the schema at a $ref's URL.
  def fetch_remote(url) do
    case read_ref(url) do
      {:ok, schema} -> schema
      {:error, message} -> raise "can't load #{url}: #{message}"
    end
  end

  defp read_ref("file://" <> path) do
    dir = Process.get({__MODULE__, :root_dir})
    path = Path.expand(path)

    if dir && String.starts_with?(path, dir <> "/"),
      do: read(path),
      else: {:error, "outside the schema's folder"}
  end

  defp read_ref(url) do
    if remote?(url), do: read(url), else: {:error, "not a file or an http(s) address"}
  end

  defp read(url) do
    text =
      if remote?(url) do
        fetch(url)
      else
        case File.read(url) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, :file.format_error(reason) |> to_string()}
        end
      end

    with {:ok, text} <- text do
      case Bee.JSON.JSONC.decode(text) do
        {:ok, %{} = schema} -> {:ok, schema}
        {:ok, _} -> {:error, "not a JSON object"}
        {:error, message} -> {:error, message}
      end
    end
  end

  defp fetch(url) do
    opts =
      [url: url, decode_body: false, retry: false, receive_timeout: 10_000, max_redirects: 5]
      |> Keyword.merge(Application.get_env(:bee, __MODULE__, [])[:req_options] || [])

    case Req.get(opts) do
      {:ok, %{status: 200, body: body}} when byte_size(body) <= @max_size ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, "too big"}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        Logger.warning("JSON schema #{url}: #{Exception.message(exception)}")
        {:error, Exception.message(exception)}
    end
  end
end

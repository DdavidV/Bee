defmodule Bee.Plugins.OpenVsx do
  @moduledoc """
  Searching and installing extensions from [Open VSX](https://open-vsx.org)
  (its REST API: `/api/-/search`, `/api/{namespace}/{name}`), like VS
  Code's Extensions view does from its marketplace. An extension's id is
  `namespace.name`; installing one downloads its `.vsix` and hands it to
  `Bee.Plugins.Vsix`, which records where it came from.

  Extensions with native code publish a package per target platform
  (`linux-x64`, `darwin-arm64`, …). Like VS Code, Bee installs the one
  for the platform it runs on (`target_platform/0`), else the `universal`
  one; when the latest version has neither, the latest version that has
  (`/api/{namespace}/{name}/{targetPlatform}`).

  Open VSX rate limits by address, so Bee is careful with it:

    * answers are cached (Cachex, `#{inspect(__MODULE__)}.Cache`): searches
      for 10 minutes, extensions' metadata and READMEs for an hour; at most
      500 of them, the oldest written going first
    * the same request asked for while it runs is made once, every caller
      gets its answer
    * at most 60 requests a minute leave Bee; past that, requests fail
      at once without reaching the network
    * a `429 Too Many Requests` (or `X-RateLimit-Remaining: 0`) stops all
      requests until its `Retry-After` (`X-RateLimit-Reset`) is over

  Failures are `{:error, message}` with a message for the user (network
  down, Open VSX's own error, rate limited).

  The server is `config :bee, #{inspect(__MODULE__)}, base_url: …`
  (`BEE_OPEN_VSX_URL` at runtime); `req_options` are added to every
  request (tests stub Open VSX with `Req.Test` there); `target_platform`
  overrides the detected platform (`BEE_TARGET_PLATFORM`).
  """
  use GenServer

  import Cachex.Spec, only: [hook: 1]

  require Logger

  alias Bee.Plugins.Vsix

  @cache __MODULE__.Cache
  @search_ttl :timer.minutes(10)
  @metadata_ttl :timer.hours(1)
  # Requests per window, and the window.
  @budget 60
  @window :timer.minutes(1)
  # Entries kept in the cache; past it, the oldest written go.
  @max_entries 500
  @page_size 30
  @max_page_size 100
  @max_download 200_000_000
  # Without a Retry-After.
  @default_backoff 60
  # Open VSX's target platforms, besides "universal" and "web".
  @platforms ~w(win32-x64 win32-ia32 win32-arm64 linux-x64 linux-arm64 linux-armhf
                alpine-x64 alpine-arm64 darwin-x64 darwin-arm64)

  @type entry :: %{
          id: String.t(),
          namespace: String.t(),
          name: String.t(),
          display_name: String.t(),
          description: String.t() | nil,
          version: String.t() | nil,
          icon: String.t() | nil,
          downloads: non_neg_integer(),
          rating: number() | nil,
          verified: boolean(),
          deprecated: boolean()
        }

  ## API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The cache's child spec (started before this server)."
  def cache_child_spec do
    {Cachex,
     [
       name: @cache,
       hooks: [hook(module: Cachex.Limit.Scheduled, args: {@max_entries, [], []})]
     ]}
  end

  @doc "The Open VSX server, e.g. `https://open-vsx.org`."
  def base_url, do: config(:base_url, "https://open-vsx.org") |> String.trim_trailing("/")

  @doc """
  Searches extensions (by relevance). Options: `offset`, `size` (default
  #{@page_size}). `{:ok, %{total: n, offset: offset, extensions: [entry]}}`.
  """
  @spec search(String.t(), keyword()) ::
          {:ok, %{total: non_neg_integer(), offset: non_neg_integer(), extensions: [entry]}}
          | {:error, String.t()}
  def search(query, opts \\ []) when is_binary(query) do
    query = String.trim(query)
    offset = max(Keyword.get(opts, :offset, 0), 0)
    size = opts |> Keyword.get(:size, @page_size) |> max(1) |> min(@max_page_size)

    params = [query: query, size: size, offset: offset, includeAllVersions: false]

    with {:ok, json} <-
           get_json({:search, query, offset, size}, "/api/-/search", params, @search_ttl) do
      extensions = for %{} = e <- List.wrap(json["extensions"]), e = entry(e), do: e
      {:ok, %{total: int(json["totalSize"]), offset: offset, extensions: extensions}}
    end
  end

  @doc """
  The platform Bee runs on, as Open VSX names it (`linux-x64`,
  `darwin-arm64`, `win32-x64`, `alpine-arm64`…), or `"universal"` for one
  it has no packages for. Configurable (`target_platform`).
  """
  def target_platform do
    case config(:target_platform, nil) do
      platform when is_binary(platform) and platform != "" ->
        platform

      _ ->
        platform_for(
          :os.type(),
          to_string(:erlang.system_info(:system_architecture)),
          System.get_env("PROCESSOR_ARCHITECTURE")
        )
    end
  end

  @doc false
  # `os` as :os.type/0 gives it, `arch` the system architecture
  # ("x86_64-pc-linux-gnu", "aarch64-apple-darwin23.4.0",
  # "x86_64-alpine-linux-musl"), `windows_arch` Windows' PROCESSOR_ARCHITECTURE.
  def platform_for(os, arch, windows_arch) do
    cpu = fn arch ->
      arch = String.downcase(arch || "")

      cond do
        arch =~ ~r/^(x86_64|amd64|x64)/ -> "x64"
        arch =~ ~r/^(aarch64|arm64)/ -> "arm64"
        arch =~ ~r/^arm/ -> "armhf"
        arch =~ ~r/^(i[3-6]86|x86)/ -> "ia32"
        true -> nil
      end
    end

    platform =
      case os do
        {:unix, :linux} ->
          if arch =~ "musl", do: "alpine-#{cpu.(arch)}", else: "linux-#{cpu.(arch)}"

        {:unix, :darwin} ->
          "darwin-#{cpu.(arch)}"

        {:win32, _} ->
          "win32-#{cpu.(windows_arch)}"

        _ ->
          nil
      end

    if platform in @platforms, do: platform, else: "universal"
  end

  @doc """
  Extension `id` (`namespace.name`): its metadata, the latest version's
  for this platform (see the module doc). `download` and
  `target_platform` are the package to install, nil when there is none
  for this platform; `platforms` the ones the version has packages for.
  `fresh: true` asks Open VSX again even when it's cached (installing).
  """
  def extension(id, opts \\ []) do
    platform = target_platform()

    with {:ok, namespace, name} <- parse_id(id),
         path = "/api/#{URI.encode(namespace)}/#{URI.encode(name)}",
         {:ok, json} <- get_json({:extension, namespace, name}, path, [], @metadata_ttl, opts),
         {:ok, ext} <- parse_details(json, platform) do
      if ext.download,
        do: {:ok, ext},
        else: for_platform(ext, namespace, name, Enum.uniq([platform, "universal"]), opts)
    end
  end

  # The latest version doesn't have a package for this platform: the
  # latest one that does (Open VSX 404s when none does; that's cached too).
  defp for_platform(ext, _namespace, _name, [], _opts), do: {:ok, ext}

  defp for_platform(ext, namespace, name, [platform | rest], opts) do
    path = "/api/#{URI.encode(namespace)}/#{URI.encode(name)}/#{platform}"

    case get_json({:extension, namespace, name, platform}, path, [], @metadata_ttl, [
           {:missing, true} | opts
         ]) do
      {:ok, :none} ->
        for_platform(ext, namespace, name, rest, opts)

      {:ok, json} ->
        case parse_details(json, target_platform()) do
          {:ok, %{download: url} = found} when is_binary(url) -> {:ok, found}
          _ -> for_platform(ext, namespace, name, rest, opts)
        end

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Extension `id`'s metadata and its README (`readme: nil` when it has none or it failed)."
  def details(id) do
    with {:ok, ext} <- extension(id) do
      readme =
        case ext.readme_url && get_text({:readme, ext.readme_url}, ext.readme_url, @metadata_ttl) do
          {:ok, text} -> text
          _ -> nil
        end

      {:ok, Map.put(ext, :readme, readme)}
    end
  end

  @doc """
  Installs (or updates) extension `id`: its latest version's `.vsix`, as a
  plugin of the user (`Bee.Plugins.Vsix`). `{:ok, plugin_name}` or
  `{:error, message}`.
  """
  def install(id) do
    with {:ok, ext} <- extension(id, fresh: true),
         {:ok, path} <- download(ext) do
      try do
        Vsix.install(path, source: ext.id, target_platform: ext.target_platform)
      after
        File.rm(path)
      end
    end
  end

  @doc """
  The extensions installed from Open VSX: `%{lowercase id => %{plugin:
  name, version: version}}`.
  """
  def installed do
    for %{scope: :user, dir: dir, name: plugin} <- Bee.Plugins.list(),
        %{"openVsx" => id} = marker <- [Vsix.marker(dir)],
        is_binary(id),
        into: %{},
        do: {String.downcase(id), %{plugin: plugin, version: marker["version"]}}
  end

  @doc "Whether version `latest` is newer than `installed`."
  def newer?(latest, installed) when is_binary(latest) and is_binary(installed) do
    case {Version.parse(latest), Version.parse(installed)} do
      {{:ok, l}, {:ok, i}} -> Version.compare(l, i) == :gt
      _ -> latest != installed
    end
  end

  def newer?(_latest, _installed), do: false

  @doc false
  # Tests: forgets the cache and the limits.
  def reset, do: GenServer.call(__MODULE__, :reset)

  ## Parsing

  defp entry(%{"namespace" => ns, "name" => name} = e) when is_binary(ns) and is_binary(name) do
    %{
      id: "#{ns}.#{name}",
      namespace: ns,
      name: name,
      display_name: string(e["displayName"]) || name,
      description: string(e["description"]),
      version: string(e["version"]),
      icon: url(get_in(e, ["files", "icon"])),
      downloads: int(e["downloadCount"]),
      rating: if(is_number(e["averageRating"]), do: e["averageRating"]),
      verified: e["verified"] == true,
      deprecated: e["deprecated"] == true
    }
  end

  defp entry(_e), do: nil

  defp parse_details(%{} = json, platform) do
    case entry(json) do
      nil ->
        {:error, "Open VSX sent an extension without a name"}

      entry ->
        files = if is_map(json["files"]), do: json["files"], else: %{}
        packages = packages(json, files)
        picked = Enum.find([platform, "universal"], &Map.has_key?(packages, &1))

        {:ok,
         Map.merge(entry, %{
           publisher: string(json["namespaceDisplayName"]) || entry.namespace,
           license: string(json["license"]),
           repository: url(json["repository"]),
           homepage: url(json["homepage"]),
           categories: Enum.filter(List.wrap(json["categories"]), &is_binary/1),
           tags: Enum.filter(List.wrap(json["tags"]), &is_binary/1),
           review_count: int(json["reviewCount"]),
           timestamp: string(json["timestamp"]),
           readme_url: url(files["readme"]),
           download: picked && packages[picked],
           target_platform: picked,
           platforms: packages |> Map.keys() |> Enum.sort()
         })}
    end
  end

  # Target platform → package URL: `downloads`, or (a server without it)
  # `files.download`, the package of `targetPlatform`.
  defp packages(json, files) do
    case json["downloads"] do
      %{} = downloads when map_size(downloads) > 0 ->
        for {platform, link} <- downloads, link = url(link), into: %{}, do: {platform, link}

      _ ->
        case url(files["download"]) do
          nil -> %{}
          link -> %{(string(json["targetPlatform"]) || "universal") => link}
        end
    end
  end

  # namespace.name: Open VSX's names are letters, digits, - and _.
  defp parse_id(id) when is_binary(id) do
    case String.split(id, ".", parts: 2) do
      [ns, name] ->
        if Enum.all?([ns, name], &Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/, &1)),
          do: {:ok, ns, name},
          else: {:error, "not an extension id: #{id}"}

      _ ->
        {:error, "not an extension id: #{id} (expected publisher.name)"}
    end
  end

  defp parse_id(id), do: {:error, "not an extension id: #{inspect(id)}"}

  defp string(s) when is_binary(s) and s != "", do: s
  defp string(_s), do: nil

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_n), do: 0

  defp url(url) when is_binary(url) do
    url = url |> String.replace_prefix("git+", "") |> String.replace_suffix(".git", "")
    if String.starts_with?(url, ["https://", "http://"]), do: url
  end

  defp url(_url), do: nil

  ## Requests

  # `missing: true`: a 404 is `{:ok, :none}` (and cached like an answer).
  defp get_json(key, path, params, ttl, opts \\ []) do
    missing? = opts[:missing] == true

    request(key, ttl, opts, fn ->
      case http(url: base_url() <> path, params: params, headers: [accept: "application/json"]) do
        {:ok, %{status: 404} = resp} when missing? -> {{:ok, :none}, resp}
        result -> json_result(result)
      end
    end)
  end

  # Only from Open VSX itself (a URL in its answers).
  defp get_text(key, url, ttl) do
    if same_origin?(url) do
      request(key, ttl, [], fn ->
        case http(url: url, decode_body: false) do
          {:ok, %{status: 200, body: body} = resp} when is_binary(body) -> {{:ok, body}, resp}
          other -> json_result(other)
        end
      end)
    else
      {:error, "not an Open VSX address: #{url}"}
    end
  end

  # Into a temporary file, at most @max_download bytes. Not cached.
  defp download(%{download: url, id: id}) when is_binary(url) do
    if same_origin?(url) do
      request({:download, url}, 0, [], fn -> download_to_file(url, id) end, :timer.minutes(5))
    else
      {:error, "not an Open VSX address: #{url}"}
    end
  end

  defp download(%{id: id, platforms: []}), do: {:error, "Open VSX has no package for #{id}"}

  defp download(%{id: id, platforms: platforms}),
    do:
      {:error,
       "#{id} has no package for #{target_platform()} (only for #{Enum.join(platforms, ", ")})"}

  defp download_to_file(url, id) do
    path = Path.join(System.tmp_dir!(), "bee-#{System.unique_integer([:positive])}.vsix")
    {:ok, file} = File.open(path, [:write, :binary])

    into = fn {:data, data}, {req, resp} ->
      size = Req.Response.get_private(resp, :size, 0) + byte_size(data)

      if size > @max_download do
        {:halt, {req, Req.Response.put_private(resp, :too_big, true)}}
      else
        IO.binwrite(file, data)
        {:cont, {req, Req.Response.put_private(resp, :size, size)}}
      end
    end

    result = http(url: url, into: into, receive_timeout: 60_000)
    File.close(file)

    case result do
      {:ok, %{status: 200} = resp} ->
        if Req.Response.get_private(resp, :too_big),
          do: {{:error, "the package of #{id} is too big"}, resp},
          else: {{:ok, path}, resp}

      other ->
        File.rm(path)
        json_result(other)
    end
  end

  defp same_origin?(url) do
    base = URI.parse(base_url())
    uri = URI.parse(url)
    {uri.scheme, uri.host, uri.port} == {base.scheme, base.host, base.port}
  end

  defp http(opts) do
    [retry: false, redirect: true, max_redirects: 5, receive_timeout: 15_000]
    |> Keyword.merge(config(:req_options, []))
    |> Keyword.merge(opts)
    |> Keyword.put(:headers, [{"user-agent", "Bee"} | Keyword.get(opts, :headers, [])])
    |> Req.request()
  end

  # {result, response or nil}: the response for its rate limit headers.
  defp json_result({:ok, %{status: 200, body: %{} = body} = resp}), do: {{:ok, body}, resp}

  defp json_result({:ok, %{status: 429} = resp}), do: {:rate_limited, resp}

  defp json_result({:ok, %{status: status, body: body} = resp}) do
    message =
      case body do
        %{"error" => error} when is_binary(error) -> error
        _ when status == 404 -> "not found"
        _ when status == 200 -> "unexpected answer"
        _ -> "HTTP #{status}"
      end

    {{:error, "Open VSX: #{message}"}, resp}
  end

  defp json_result({:error, exception}) do
    {{:error, "Can't reach Open VSX (#{base_url()}): #{Exception.message(exception)}"}, nil}
  end

  defp config(key, default),
    do: :bee |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  ## The cache, and the gate in front of the network

  defp request(key, ttl, opts, fun, timeout \\ 30_000) do
    case if(opts[:fresh], do: :miss, else: cached(key)) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        try do
          GenServer.call(__MODULE__, {:request, key, ttl, opts[:fresh] == true, fun}, timeout)
        catch
          :exit, {:timeout, _} -> {:error, "Open VSX didn't answer in time"}
          :exit, _ -> {:error, "Bee's Open VSX client isn't running"}
        end
    end
  end

  # Expired entries read as missing (Cachex checks on read).
  defp cached(key) do
    case Cachex.get(@cache, key) do
      {:ok, nil} -> :miss
      {:ok, value} -> {:ok, value}
      {:error, _} -> :miss
    end
  end

  @impl true
  def init(_opts), do: {:ok, initial()}

  # Monotonic time can be negative: no block, an expired window.
  defp initial do
    now = now()

    %{
      running: %{},
      waiting: %{},
      blocked_until: now,
      window_start: now - @window,
      window_count: 0
    }
  end

  @impl true
  def handle_call({:request, key, ttl, fresh?, fun}, from, state) do
    now = now()

    cond do
      not fresh? and match?({:ok, _}, cached(key)) ->
        {:reply, cached(key), state}

      Map.has_key?(state.waiting, key) ->
        {:noreply, update_in(state.waiting[key], &[from | &1])}

      state.blocked_until > now ->
        {:reply, {:error, rate_limited(state.blocked_until - now)}, state}

      true ->
        state = refill(state, now)

        if state.window_count >= @budget do
          wait = state.window_start + @window - now

          {:reply,
           {:error,
            "Bee made too many requests to Open VSX; try again in #{seconds(wait)} seconds"},
           state}
        else
          task = Task.Supervisor.async_nolink(Bee.Plugins.OpenVsx.TaskSup, fun)

          {:noreply,
           %{
             state
             | running: Map.put(state.running, task.ref, {key, ttl}),
               waiting: Map.put(state.waiting, key, [from]),
               window_count: state.window_count + 1
           }}
        end
    end
  end

  def handle_call(:reset, _from, state) do
    Cachex.clear(@cache)
    {:reply, :ok, %{initial() | running: state.running, waiting: state.waiting}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {{key, ttl}, running} = Map.pop(state.running, ref)
    state = %{state | running: running}

    {reply, state} =
      case result do
        {:rate_limited, resp} ->
          wait = header_seconds(resp, "retry-after") || @default_backoff
          Logger.warning("Open VSX rate limits Bee; waiting #{wait} s")
          {{:error, rate_limited(:timer.seconds(wait))}, block(state, :timer.seconds(wait))}

        {reply, resp} ->
          if ttl > 0 and match?({:ok, _}, reply), do: put_cache(key, elem(reply, 1), ttl)
          {reply, limit(state, resp)}
      end

    {:noreply, answer(state, key, reply)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    {{key, _ttl}, running} = Map.pop(state.running, ref)
    Logger.error("Open VSX request crashed: #{inspect(reason)}")
    state = %{state | running: running}
    {:noreply, answer(state, key, {:error, "Open VSX request failed: #{inspect(reason)}"})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp answer(state, key, reply) do
    {waiting, rest} = Map.pop(state.waiting, key, [])
    Enum.each(waiting, &GenServer.reply(&1, reply))
    %{state | waiting: rest}
  end

  # X-RateLimit-Remaining: 0 – nothing more until X-RateLimit-Reset.
  defp limit(state, %Req.Response{} = resp) do
    case Req.Response.get_header(resp, "x-ratelimit-remaining") do
      ["0" | _] -> block(state, :timer.seconds(header_seconds(resp, "x-ratelimit-reset") || 1))
      _ -> state
    end
  end

  defp limit(state, _resp), do: state

  defp block(state, ms), do: %{state | blocked_until: max(state.blocked_until, now() + ms)}

  defp header_seconds(resp, name) do
    with [value | _] <- Req.Response.get_header(resp, name),
         {n, _} <- Integer.parse(String.trim(value)) do
      n |> max(1) |> min(3600)
    else
      _ -> nil
    end
  end

  defp refill(state, now) do
    if now - state.window_start >= @window,
      do: %{state | window_start: now, window_count: 0},
      else: state
  end

  defp put_cache(key, value, ttl), do: Cachex.put(@cache, key, value, expire: ttl)

  defp rate_limited(ms),
    do: "Open VSX is limiting Bee's requests; try again in #{seconds(ms)} seconds"

  defp seconds(ms), do: max(div(ms + 999, 1000), 1)

  defp now, do: System.monotonic_time(:millisecond)
end

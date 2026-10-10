defmodule Bee.Webviews do
  @moduledoc """
  The webview panels of VS Code extensions (`window.createWebviewPanel`):
  pages of an extension's own HTML, shown in editor tabs.

  A panel belongs to a workspace's extension host (`Bee.Extensions.Host`),
  which files here what its extension sets – title, HTML, options – and
  what it posts; the windows of the workspace show every panel in a tab
  (`BeeWeb.Workbench.Webview`), in a sandboxed frame loaded from
  `BeeWeb.WebviewController` by the panel's `token` (unguessable: the
  frame has no session). A panel:

      %{
        id: "3", extension: "swagger-viewer", view_type: "swagger.preview",
        title: "Swagger Preview", html: "<html>…", version: 2,   # of the HTML
        scripts?: true,                # options.enableScripts
        roots: ["/ws", "/…/plugin"],   # localResourceRoots: files it may load
        token: "…", state: nil         # what its page kept with setState
      }

  Changes are broadcast on the workspace's topic (`subscribe/1`) as
  `{:webview, id, event}`: `:opened`, `:changed` (title, HTML, options),
  `:revealed`, `{:message, data}` (posted to its page), `:disposed`.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  def subscribe(root), do: Phoenix.PubSub.subscribe(Bee.PubSub, topic(root))

  defp topic(root), do: "webviews:" <> root

  defp tell(root, id, event),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, topic(root), {:webview, id, event})

  @doc "A new panel `id` of workspace `root`, from `attrs` (`:extension`, `:view_type`, `:title`, `:scripts?`, `:roots`)."
  def open(root, id, attrs) when is_binary(root) and is_binary(id) do
    panel =
      Map.merge(
        %{
          id: id,
          extension: nil,
          view_type: nil,
          title: "",
          html: "",
          version: 0,
          scripts?: false,
          roots: [],
          state: nil,
          token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        },
        Map.take(attrs, [:extension, :view_type, :title, :scripts?, :roots])
      )

    :ets.insert(@table, {{root, id}, panel})
    tell(root, id, :opened)
    panel
  end

  @doc "Changes panel `id`: `:title`, `:html` (its page loads again), `:scripts?`, `:roots`."
  def update(root, id, changes) do
    with %{} = panel <- get(root, id) do
      changes = Map.take(changes, [:title, :html, :scripts?, :roots])
      changed = Map.merge(panel, changes)

      if changed != panel or Map.has_key?(changes, :html) do
        # Setting the HTML loads the page afresh, even the same HTML.
        version = if Map.has_key?(changes, :html), do: panel.version + 1, else: panel.version
        :ets.insert(@table, {{root, id}, %{changed | version: version}})
        tell(root, id, :changed)
      end
    end

    :ok
  end

  @doc "What the panel's page keeps over reloads (`setState`)."
  def put_state(root, id, state) do
    with %{} = panel <- get(root, id),
         do: :ets.insert(@table, {{root, id}, %{panel | state: state}})

    :ok
  end

  @doc "Posts `message` (JSON data) to the panel's page, in every window showing it."
  def post(root, id, message), do: tell(root, id, {:message, message})

  @doc "Brings the panel's tab to the front."
  def reveal(root, id), do: tell(root, id, :revealed)

  def dispose(root, id) do
    if get(root, id) do
      :ets.delete(@table, {root, id})
      tell(root, id, :disposed)
    end

    :ok
  end

  @doc "Disposes of workspace `root`'s panels (its extension host stopped)."
  def clear(root) do
    for %{id: id} <- list(root), do: dispose(root, id)
    :ok
  end

  def get(root, id) do
    case :ets.lookup(@table, {root, id}) do
      [{_, panel}] -> panel
      [] -> nil
    end
  end

  @doc "The panels of workspace `root`, oldest first."
  def list(root) do
    @table
    |> :ets.match_object({{root, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(&String.to_integer(&1.id))
  rescue
    ArgumentError -> []
  end

  @doc "`{root, panel}` of the panel with `token`, or nil."
  def by_token(token) when is_binary(token) do
    case :ets.match_object(@table, {:_, %{token: token}}) do
      [{{root, _id}, panel}] -> {root, panel}
      _ -> nil
    end
  end

  @doc """
  The file `path` if the panel may load it: under one of its `roots`, with
  links followed (nil otherwise).
  """
  def resource(%{roots: roots}, path) when is_binary(path) do
    file = real(Path.expand(path))

    if Enum.any?(roots, &inside?(file, real(Path.expand(&1)))) and File.regular?(file),
      do: file
  end

  defp inside?(file, root), do: file == root or String.starts_with?(file, root <> "/")

  # `path` with its symbolic links followed (as far as it exists).
  defp real(path, depth \\ 0)
  defp real(path, depth) when depth > 32, do: path

  defp real(path, depth) do
    [first | rest] = Path.split(path)

    Enum.reduce(rest, first, fn part, acc ->
      joined = Path.join(acc, part)

      case File.read_link(joined) do
        {:ok, target} -> real(Path.expand(target, acc), depth + 1)
        _ -> joined
      end
    end)
  end
end

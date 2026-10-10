defmodule Bee.Plugins do
  @moduledoc """
  Plugins: folders with a `plugin.json` manifest
  (`priv/schemas/manifest.schema.json`) – or a VS Code extension installed
  from a VSIX, whose `package.json` is read as one
  (`Bee.Plugins.VSCode.Manifest`) – in

    * `priv/plugins/<name>/` – Bee's own (built-in); their server code is
      compiled with Bee, not at runtime

    * `<config_dir>/plugins/<name>/` – the user's plugins
    * `<workspace>/.bee/plugins/<name>/` – only with
      `"plugins.workspace.enabled": true` in user settings, since plugins run
      with your permissions; they run in their workspace only

  A plugin contributes commands, keybindings, menus, languages, grammars and
  settings like Bee's own manifests (`Bee.Contributions`), and may have

    * a server part – Elixir/Erlang code implementing `Bee.Plugin`, run by
      its own process (`Bee.Plugins.Host`)
    * a browser part – an ES module loaded by the page, exporting
      `activate(bee)` (`assets/js/plugins/`)

  Contributions are shared by every window. The server part runs once per
  open workspace (folder), like VS Code's extension host per window: each
  copy sees its workspace only (`Bee.Plugins.Context`'s `root`, its files,
  settings and buffers), and what it puts on screen (`Bee.UI`) is shown by
  that workspace's windows. Two workspaces' plugins can't share a name
  (or contribute the same command).

  `Bee.Plugins.Manager` does the work; this module is the API.
  """

  alias Bee.Plugins.{Context, Manager}

  @table Bee.Plugins

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, "plugins")

  @doc "Bee's own plugins (e.g. git), shipped in `priv/plugins/`, their code compiled with Bee."
  def builtin_dir, do: Path.join(:code.priv_dir(:bee), "plugins")

  def user_dir, do: Path.join(Bee.Settings.user_dir(), "plugins")
  def workspace_dir(root), do: Path.join([root, ".bee", "plugins"])

  @doc """
  Every plugin found, sorted by name (see `Bee.Plugins.Manager` for
  `status` and `hosts`, the status in each workspace).
  """
  def list do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.name)
  end

  @doc """
  The plugins of workspace `root`, as its windows see them: `status` and
  `errors` include its server part's there (`:activating`, `:active`,
  `:failed`). Other workspaces' workspace plugins are left out.
  """
  def list(root) do
    for plugin <- list(), plugin.workspace in [nil, root], do: in_workspace(plugin, root)
  end

  def get(name) do
    case :ets.lookup(@table, name) do
      [{^name, plugin}] -> plugin
      [] -> nil
    end
  end

  @doc "Plugin `name` as workspace `root` sees it (see `list/1`)."
  def get(name, root) do
    case get(name) do
      %{workspace: workspace} = plugin when workspace in [nil, root] -> in_workspace(plugin, root)
      _ -> nil
    end
  end

  defp in_workspace(%{status: :inactive} = plugin, root) do
    case plugin.hosts[root] do
      %{status: status, errors: errors} when status != :inactive ->
        %{plugin | status: status, errors: plugin.errors ++ errors}

      _ ->
        plugin
    end
  end

  defp in_workspace(plugin, _root), do: plugin

  @doc "Problems of workspace `root`'s plugins, `[%{path, message}]`."
  def errors(root), do: Enum.flat_map(list(root), & &1.errors)

  @doc "Browser parts for the windows of workspace `root`: `[%{name, url}]`."
  def browser_modules(root) do
    for %{browser: %{url: url}, name: name, status: status} <- list(root),
        status not in [:invalid, :disabled],
        do: %{name: name, url: url}
  end

  @doc """
  The file `rel` of plugin `name` that may be served to the browser: its
  browser module, an icon of one of its icon themes (`Bee.IconThemes`), a
  TextMate grammar (`Bee.Languages`), or an image in its folder (its icon,
  its README's pictures – of disabled plugins too, for their details
  page). `{:ok, absolute_path, :module | :icon | :grammar}` or `:error`.
  """
  def asset_path(name, rel) do
    case get(name) do
      %{dir: dir, status: status} = plugin ->
        path = Path.expand(rel, dir)
        usable? = status not in [:invalid, :disabled]

        cond do
          usable? and match?(%{browser: %{path: ^path}}, plugin) -> {:ok, path, :module}
          usable? and Bee.IconThemes.icon_file?(name, path) -> {:ok, path, :icon}
          usable? and Bee.Languages.grammar_file?(name, path) -> {:ok, path, :grammar}
          image?(path, dir) -> {:ok, path, :icon}
          true -> :error
        end

      _ ->
        :error
    end
  end

  @images ~w(.png .jpg .jpeg .gif .svg .webp)

  defp image?(path, dir),
    do:
      String.starts_with?(path, dir <> "/") and String.downcase(Path.extname(path)) in @images and
        File.regular?(path)

  @doc """
  Runs plugin `name`'s server command `id` in the workspace of `ctx.root`,
  activating the plugin there if needed. Returns at once; the plugin talks
  back through `Bee.API`.
  """
  @spec execute(String.t(), String.t(), Context.t()) :: :ok | {:error, String.t()}
  def execute(name, id, %Context{} = ctx), do: GenServer.call(Manager, {:execute, name, id, ctx})

  @doc """
  View `view_id` is shown in a window of workspace `root`: starts the plugin
  that contributed it there, so it can fill it.
  """
  def view_shown(view_id, root) do
    case Bee.Views.plugin(view_id) do
      nil -> :ok
      name -> GenServer.call(Manager, {:activate, name, root})
    end
  end

  @doc """
  A request from plugin `name`'s browser part (`bee.request(method, params)`)
  to its server part (`handle_request/4`) in the workspace of `ctx.root`.
  The answer goes to `ctx.window`
  as `{:bee_api, {:reply, ref, result}}`.
  """
  def request(name, method, params, %Context{} = ctx, ref),
    do: GenServer.call(Manager, {:request, name, method, params, ctx, ref})

  @doc """
  Enables or disables plugin `name` by editing `plugins.disabled` in the
  user's settings (plugins run for every workspace alike). The manager
  starts or stops the plugin when the settings reload. Returns `:ok` or
  `{:error, message}`.
  """
  def set_enabled(name, enabled?) when is_binary(name) and is_boolean(enabled?) do
    Bee.Settings.update(:user, "plugins.disabled", fn current ->
      current = if is_list(current), do: current, else: []
      if enabled?, do: List.delete(current, name), else: Enum.uniq(current ++ [name])
    end)
  end

  @doc "Stops every plugin and loads them again from disk."
  def reload, do: GenServer.call(Manager, :reload, 30_000)

  @doc "Stops plugin `name` (if loaded) and loads it again from disk, if it's still there."
  def reload(name), do: GenServer.call(Manager, {:reload, name}, 30_000)

  @doc """
  Uninstalls plugin `name` from the user's plugins folder: its folder is
  deleted (only the link, when it is a symlink to one elsewhere). Built-in
  and workspace plugins can't be uninstalled. Returns `:ok` or
  `{:error, message}`.
  """
  def uninstall(name) do
    case get(name) do
      # `dir` is the folder's entry in user_dir(), a symlink not resolved.
      %{scope: :user, dir: entry} ->
        result =
          case File.lstat(entry) do
            {:ok, %File.Stat{type: :symlink}} -> File.rm(entry)
            {:ok, _} -> with {:ok, _} <- File.rm_rf(entry), do: :ok
            {:error, reason} -> {:error, reason}
          end

        reload(name)

        case result do
          :ok ->
            :ok

          {:error, reason, _file} ->
            {:error, "can't delete #{entry}: #{:file.format_error(reason)}"}

          {:error, reason} ->
            {:error, "can't delete #{entry}: #{:file.format_error(reason)}"}
        end

      %{scope: scope} ->
        {:error, "#{name} is a #{scope} plugin; only plugins in #{user_dir()} can be uninstalled"}

      nil ->
        {:error, "no plugin #{inspect(name)}"}
    end
  end
end

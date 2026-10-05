defmodule Bee.Plugins do
  @moduledoc """
  Plugins: folders with a `plugin.json` manifest
  (`priv/schemas/manifest.schema.json`) in

    * `priv/plugins/<name>/` – Bee's own (built-in); their server code is
      compiled with Bee, not at runtime

    * `<config_dir>/plugins/<name>/` – the user's plugins
    * `<workspace>/.bee/plugins/<name>/` – only with
      `"plugins.workspace.enabled": true` in user settings, since plugins run
      with your permissions

  A plugin contributes commands, keybindings, menus, languages, grammars and
  settings like Bee's own manifests (`Bee.Contributions`), and may have

    * a server part – Elixir/Erlang code implementing `Bee.Plugin`, run by
      its own process (`Bee.Plugins.Host`)
    * a browser part – an ES module loaded by the page, exporting
      `activate(bee)` (`assets/js/plugins/`)

  `Bee.Plugins.Manager` does the work; this module is the API.
  """

  alias Bee.Plugins.{Context, Manager}

  @table Bee.Plugins

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, "plugins")

  @doc "Bee's own plugins (e.g. git), shipped in `priv/plugins/`, their code compiled with Bee."
  def builtin_dir, do: Path.join(:code.priv_dir(:bee), "plugins")

  def user_dir, do: Path.join(Bee.Settings.user_dir(), "plugins")
  def workspace_dir, do: Path.join([Bee.Workspace.root(), ".bee", "plugins"])

  @doc "Every plugin found, sorted by name (see `Bee.Plugins.Manager` for `status`)."
  def list do
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.name)
  end

  def get(name) do
    case :ets.lookup(@table, name) do
      [{^name, plugin}] -> plugin
      [] -> nil
    end
  end

  @doc "Problems of all plugins, `[%{path, message}]`."
  def errors, do: Enum.flat_map(list(), & &1.errors)

  @doc "Browser parts to load: `[%{name, url}]`."
  def browser_modules do
    for %{browser: %{url: url}, name: name, status: status} <- list(),
        status not in [:invalid, :disabled],
        do: %{name: name, url: url}
  end

  @doc """
  The file `rel` of plugin `name` that may be served to the browser: its
  browser module, or an icon of one of its icon themes (`Bee.IconThemes`).
  `{:ok, absolute_path, :module | :icon}` or `:error`.
  """
  def asset_path(name, rel) do
    case get(name) do
      %{dir: dir, status: status} = plugin when status not in [:invalid, :disabled] ->
        path = Path.expand(rel, dir)

        cond do
          match?(%{browser: %{path: ^path}}, plugin) -> {:ok, path, :module}
          Bee.IconThemes.icon_file?(name, path) -> {:ok, path, :icon}
          true -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Runs plugin `name`'s server command `id`, activating the plugin if needed.
  Returns at once; the plugin talks back through `Bee.API`.
  """
  @spec execute(String.t(), String.t(), Context.t()) :: :ok | {:error, String.t()}
  def execute(name, id, %Context{} = ctx), do: GenServer.call(Manager, {:execute, name, id, ctx})

  @doc "View `view_id` is shown: starts the plugin that contributed it, so it can fill it."
  def view_shown(view_id) do
    case Bee.Views.plugin(view_id) do
      nil -> :ok
      name -> GenServer.call(Manager, {:activate, name})
    end
  end

  @doc """
  A request from plugin `name`'s browser part (`bee.request(method, params)`)
  to its server part (`handle_request/4`). The answer goes to `ctx.window`
  as `{:bee_api, {:reply, ref, result}}`.
  """
  def request(name, method, params, %Context{} = ctx, ref),
    do: GenServer.call(Manager, {:request, name, method, params, ctx, ref})

  @doc """
  Enables or disables plugin `name` by editing `plugins.disabled` in the
  settings file that decides it: the workspace's when it sets the list,
  the user's otherwise. The manager starts or stops the plugin when the
  settings reload. Returns `:ok` or `{:error, message}`.
  """
  def set_enabled(name, enabled?) when is_binary(name) and is_boolean(enabled?) do
    key = "plugins.disabled"
    scope = if Map.has_key?(Bee.Settings.layer(:workspace), key), do: :workspace, else: :user

    Bee.Settings.update(scope, key, fn current ->
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

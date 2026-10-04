defmodule Bee.Plugins do
  @moduledoc """
  Plugins: folders with a `plugin.json` manifest
  (`priv/schemas/manifest.schema.json`) in

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

  @doc "Absolute path of a plugin's browser module, if `rel` is it."
  def browser_path(name, rel) do
    case get(name) do
      %{browser: %{path: path}, dir: dir, status: status}
      when status not in [:invalid, :disabled] ->
        if Path.expand(rel, dir) == path, do: {:ok, path}, else: :error

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

  @doc "Stops every plugin and loads them again from disk."
  def reload, do: GenServer.call(Manager, :reload, 30_000)
end

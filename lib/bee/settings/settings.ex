defmodule Bee.Settings do
  @moduledoc """
  VS Code style settings: defaults from the schema, overridden by the user
  file (`<config_dir>/settings.json`), overridden by a workspace's file
  (`<root>/.bee/settings.json`). Both files are JSONC.

  Each value is validated against its JSON Schema: Bee's own settings are in
  `priv/schemas/settings.schema.json` (see `Bee.JSON.Schema`), plugins
  contribute theirs (`Bee.Settings.Configuration`). An invalid value falls
  back to the next layer down and is reported in `errors/1`. Unknown keys
  are kept (a plugin defining them may not be loaded).

  Several workspaces can be open at once (`Bee.Workspace`): each one adds
  its own layer on top of the user's, kept while it is open (`track/1`).
  Reads take the workspace's root, or `nil` for the defaults and the user
  file only. They don't go through the GenServer (`:persistent_term`).

  Every reload broadcasts `{:settings_changed, scope}` on the `"settings"`
  topic: `:user` (every workspace changed with it) or `{:workspace, root}`.
  """
  use GenServer
  require Logger

  @topic "settings"

  @type error :: %{path: String.t(), message: String.t()}
  @type scope :: :user | {:workspace, String.t()}

  @schema "settings"

  @doc """
  The known settings, keyed by name: the `properties` of
  `priv/schemas/settings.schema.json` (JSON Schema, draft 7) and those
  contributed by plugins.
  """
  def schema do
    Enum.reduce(Bee.Settings.Configuration.contributed(), builtin_schema(), fn c, acc ->
      Map.merge(acc, c.properties)
    end)
  end

  @doc "Bee's own settings (`priv/schemas/settings.schema.json`)."
  def builtin_schema, do: Bee.JSON.Schema.raw!(@schema)["properties"]

  @doc """
  Default values from the schema, then those plugins give other settings
  (`configurationDefaults`, where they are valid; an object's keys are
  added to the schema's), plus defaults that depend on the environment.
  """
  def defaults do
    defaults = Map.new(schema(), fn {key, spec} -> {key, spec["default"]} end)

    Bee.Settings.Configuration.defaults()
    |> Enum.reduce(defaults, fn {key, value}, acc ->
      case validate(key, value) do
        :ok when is_map(value) -> Map.update(acc, key, value, &Map.merge(&1 || %{}, value))
        :ok -> Map.put(acc, key, value)
        {:error, _} -> acc
      end
    end)
    |> Map.merge(runtime_defaults())
  end

  defp runtime_defaults do
    case System.get_env("SHELL") do
      shell when shell in [nil, ""] -> %{}
      shell -> %{"terminal.integrated.shell" => shell}
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, @topic)

  ## Reading

  @doc "Every setting of workspace `root` (`nil`: the defaults and the user file)."
  def all(root \\ nil), do: elem(layer_state(root), 0)

  @doc "The problems of the files behind `all/1`."
  @spec errors(String.t() | nil) :: [error]
  def errors(root \\ nil), do: elem(layer_state(root), 1)

  def get(key, root \\ nil), do: Map.get(all(root), key, defaults()[key])

  @doc """
  A setting from the defaults and the user file only, whatever workspace:
  for settings a workspace must not be able to change, like
  `plugins.workspace.enabled`.
  """
  def get_user(key), do: get(key, nil)

  @doc "Globs from workspace `root`'s `files.exclude` that are switched on, compiled."
  def excluded_globs(root \\ nil) do
    for {pattern, true} <- get("files.exclude", root), do: Bee.Workspace.Glob.compile(pattern)
  end

  defp user_state, do: :persistent_term.get({__MODULE__, :user}, {defaults(), []})

  defp layer_state(nil), do: user_state()

  defp layer_state(root) do
    case :persistent_term.get({__MODULE__, :workspace, root}, nil) do
      nil -> compute(root, user_state())
      state -> state
    end
  end

  ## Workspaces

  @doc "Keeps workspace `root`'s layer loaded (and reloaded when its file changes)."
  def track(root), do: GenServer.call(__MODULE__, {:track, root})

  def untrack(root), do: GenServer.call(__MODULE__, {:untrack, root})

  @doc "Reads every file again."
  def reload, do: GenServer.call(__MODULE__, :reload)

  def user_dir, do: Application.get_env(:bee, :config_dir) || Path.expand("~/.config/bee")
  def user_path, do: Path.join(user_dir(), "settings.json")
  def workspace_path(root), do: Path.join([root, ".bee", "settings.json"])

  @doc "Creates the user settings file if missing, documenting every setting."
  def ensure_user_file! do
    ensure_file!(user_path(), template("User settings. These override Bee's defaults."))
  end

  @doc "Creates workspace `root`'s settings file if missing."
  def ensure_workspace_file!(root) do
    ensure_file!(
      workspace_path(root),
      template("Workspace settings. These override your user settings for this folder.")
    )
  end

  defp ensure_file!(path, contents) do
    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    path
  end

  defp template(header) do
    documented =
      schema()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n\n", fn {key, spec} ->
        "  // #{spec["description"]}\n  // \"#{key}\": #{Jason.encode!(spec["default"])},"
      end)

    "// #{header}\n// Uncomment and change any of the settings below.\n{\n#{documented}\n}\n"
  end

  ## Writing

  @doc """
  The settings a file (`:user` or `{:workspace, root}`) sets itself, `%{}`
  when it is missing or unreadable.
  """
  def layer(scope) do
    case read(path(scope)) do
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end

  @doc """
  Changes `key` in the `:user` or `{:workspace, root}` settings file to
  `fun.(value)`, where `value` is what the file sets it to (`nil` when it
  doesn't). Comments and formatting are kept (`Bee.JSON.JSONC.put/3`); the
  file is created if needed and the settings reloaded. Returns `:ok` or
  `{:error, message}` (an invalid value, an unreadable file).
  """
  def update(scope, key, fun) do
    path =
      case scope do
        :user -> ensure_user_file!()
        {:workspace, root} -> ensure_workspace_file!(root)
      end

    with {:ok, text} <- File.read(path),
         {:ok, current} <- read(path),
         value = fun.(current[key]),
         :ok <- validate(key, value),
         {:ok, text} <- Bee.JSON.JSONC.put(text, key, value) do
      File.write!(path, text)
      reload()
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end

  defp path(:user), do: user_path()
  defp path({:workspace, root}), do: workspace_path(root)

  ## Validation

  @doc """
  Validates one setting against its sub-schema (`#/properties/<key>`), so a
  bad value only affects that key. Keys the schema doesn't know are accepted.
  """
  def validate(key, value) do
    owner =
      if Map.has_key?(builtin_schema(), key),
        do: @schema,
        else: Bee.Settings.Configuration.root_for(key)

    with schema when schema != nil <- owner,
         {:error, messages} <-
           Bee.JSON.Schema.validate(schema, Bee.JSON.Schema.property_ref(key), value) do
      {:error, Enum.join(messages, "; ")}
    else
      _ -> :ok
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    File.mkdir_p(user_dir())
    Phoenix.PubSub.subscribe(Bee.PubSub, "fs")
    Bee.Contributions.subscribe()
    load_user()
    {:ok, %{roots: MapSet.new()}}
  end

  @impl true
  def handle_call({:track, root}, _from, s) do
    load_workspace(root, user_state())
    {:reply, :ok, %{s | roots: MapSet.put(s.roots, root)}}
  end

  def handle_call({:untrack, root}, _from, s) do
    :persistent_term.erase({__MODULE__, :workspace, root})
    {:reply, :ok, %{s | roots: MapSet.delete(s.roots, root)}}
  end

  def handle_call(:reload, _from, s) do
    reload_all(s)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info({:fs_changed, path}, s) do
    cond do
      path == user_path() ->
        reload_all(s)

      root = Enum.find(s.roots, &(workspace_path(&1) == path)) ->
        load_workspace(root, user_state())
        broadcast({:workspace, root})

      true ->
        :ok
    end

    {:noreply, s}
  end

  # Plugin settings appeared or went away: re-validate, new defaults.
  def handle_info({:contributions_changed, keys}, s) do
    if :configuration in keys, do: reload_all(s)
    {:noreply, s}
  end

  defp reload_all(s) do
    user = load_user()
    Enum.each(s.roots, &load_workspace(&1, user))
    broadcast(:user)
  end

  defp load_user do
    {settings, errors} = apply_file({defaults(), []}, user_path())
    state = {settings, errors}
    :persistent_term.put({__MODULE__, :user}, state)
    log(errors)
    state
  end

  defp load_workspace(root, user) do
    {_settings, errors} = state = compute(root, user)
    :persistent_term.put({__MODULE__, :workspace, root}, state)
    log(errors -- elem(user, 1))
  end

  # The user's settings with workspace `root`'s file on top.
  defp compute(root, user), do: apply_file(user, workspace_path(root))

  defp apply_file({settings, errors}, path) do
    case read(path) do
      {:ok, overrides} -> apply_overrides(settings, errors, path, overrides)
      {:error, message} -> {settings, errors ++ [%{path: path, message: message}]}
    end
  end

  defp apply_overrides(settings, errors, path, overrides) do
    Enum.reduce(overrides, {settings, errors}, fn {key, value}, {settings, errors} ->
      case validate(key, value) do
        # Object settings (e.g. files.exclude) merge with the layer below, so
        # adding one pattern keeps the defaults and `false` switches one off.
        :ok when is_map(value) ->
          {Map.update(settings, key, value, &Map.merge(&1 || %{}, value)), errors}

        :ok ->
          {Map.put(settings, key, value), errors}

        {:error, reason} ->
          {settings, errors ++ [%{path: path, message: "\"#{key}\": #{reason}"}]}
      end
    end)
  end

  defp log(errors) do
    for %{path: path, message: message} <- errors,
        do: Logger.warning("Bee: #{path}: #{message}")
  end

  defp broadcast(scope),
    do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:settings_changed, scope})

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = map} <- Bee.JSON.JSONC.decode(text) do
      {:ok, map}
    else
      {:error, :enoent} -> {:ok, %{}}
      {:ok, _not_an_object} -> {:error, "must contain a JSON object"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end

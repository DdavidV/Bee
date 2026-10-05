defmodule Bee.Settings do
  @moduledoc """
  VS Code style settings: defaults from the schema, overridden by the user
  file (`<config_dir>/settings.json`), overridden by the workspace file
  (`<root>/.bee/settings.json`). Both files are JSONC.

  Each value is validated against its JSON Schema: Bee's own settings are in
  `priv/schemas/settings.schema.json` (see `Bee.JSON.Schema`), plugins
  contribute theirs (`Bee.Settings.Configuration`). An invalid value falls
  back to the next layer down and is reported in `errors/0`. Unknown keys
  are kept (a plugin defining them may not be loaded).

  The merged map lives in `:persistent_term`, so reads never go through the
  GenServer. Every reload broadcasts `{:settings_changed, settings, errors}`
  on the `"settings"` topic.
  """
  use GenServer
  require Logger

  @topic "settings"
  @key {__MODULE__, :state}

  @type error :: %{path: String.t(), message: String.t()}

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

  @doc "Default values from the schema, plus defaults that depend on the environment."
  def defaults do
    schema()
    |> Map.new(fn {key, spec} -> {key, spec["default"]} end)
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

  def all, do: elem(state(), 0)

  @spec errors() :: [error]
  def errors, do: elem(state(), 1)

  def get(key), do: Map.get(all(), key, defaults()[key])

  @doc """
  A setting from the defaults and the user file only. For settings a
  workspace must not be able to change, like `plugins.workspace.enabled`.
  """
  def get_user(key), do: Map.get(elem(state(), 2), key, defaults()[key])

  defp state do
    case :persistent_term.get(@key, nil) do
      nil -> {defaults(), [], defaults()}
      state -> state
    end
  end

  @doc "Globs from `files.exclude` that are switched on, compiled."
  def excluded_globs do
    for {pattern, true} <- get("files.exclude"), do: Bee.Workspace.Glob.compile(pattern)
  end

  def reload, do: GenServer.call(__MODULE__, :reload)

  def user_dir, do: Application.get_env(:bee, :config_dir) || Path.expand("~/.config/bee")
  def user_path, do: Path.join(user_dir(), "settings.json")
  def workspace_path, do: Path.join([Bee.Workspace.root(), ".bee", "settings.json"])

  def paths, do: [user_path(), workspace_path()]

  @doc "Creates the user settings file if missing, documenting every setting."
  def ensure_user_file! do
    ensure_file!(user_path(), template("User settings. These override Bee's defaults."))
  end

  @doc "Creates the workspace settings file if missing."
  def ensure_workspace_file! do
    ensure_file!(
      workspace_path(),
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
  The settings a file (`:user` or `:workspace`) sets itself, `%{}` when it
  is missing or unreadable.
  """
  def layer(scope) do
    case read(path(scope)) do
      {:ok, map} -> map
      {:error, _} -> %{}
    end
  end

  @doc """
  Changes `key` in the `:user` or `:workspace` settings file to
  `fun.(value)`, where `value` is what the file sets it to (`nil` when it
  doesn't). Comments and formatting are kept (`Bee.JSON.JSONC.put/3`); the
  file is created if needed and the settings reloaded. Returns `:ok` or
  `{:error, message}` (an invalid value, an unreadable file).
  """
  def update(scope, key, fun) when scope in [:user, :workspace] do
    path = if scope == :user, do: ensure_user_file!(), else: ensure_workspace_file!()

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
  defp path(:workspace), do: workspace_path()

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
    load(false)
    {:ok, nil}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    load(true)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:fs_changed, path}, state) do
    if path in paths(), do: load(true)
    {:noreply, state}
  end

  # Plugin settings appeared or went away: re-validate, new defaults.
  def handle_info({:contributions_changed, keys}, state) do
    if :configuration in keys, do: load(true)
    {:noreply, state}
  end

  defp load(broadcast?) do
    {layers, errors} =
      Enum.map_reduce(paths(), [], fn path, errors ->
        case read(path) do
          {:ok, overrides} -> {overrides, errors}
          {:error, message} -> {%{}, errors ++ [%{path: path, message: message}]}
        end
      end)

    {[user, settings], errors} =
      paths()
      |> Enum.zip(layers)
      |> Enum.map_reduce({defaults(), errors}, fn {path, overrides}, {settings, errors} ->
        {settings, errors} = apply_overrides(settings, errors, path, overrides)
        {settings, {settings, errors}}
      end)
      |> then(fn {merged, {_, errors}} -> {merged, errors} end)

    :persistent_term.put(@key, {settings, errors, user})

    for %{path: path, message: message} <- errors,
        do: Logger.warning("Bee: #{path}: #{message}")

    if broadcast?,
      do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:settings_changed, settings, errors})
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

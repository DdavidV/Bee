defmodule Bee.Settings do
  @moduledoc """
  VS Code style settings: defaults from the schema, overridden by the user
  file (`<config_dir>/settings.json`), overridden by the workspace file
  (`<root>/.bee/settings.json`). Both files are JSONC.

  Each value is validated against the JSON Schema in
  `priv/schemas/settings.schema.json` (see `Bee.JSON.Schema`); an invalid value falls back to
  the next layer down and is reported in `errors/0`. Unknown keys are kept
  (plugins may define them later).

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
  The known settings: the `properties` of `priv/schemas/settings.schema.json`
  (JSON Schema, draft 7), keyed by setting name.
  """
  def schema, do: Bee.JSON.Schema.raw!(@schema)["properties"]

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

  def all, do: elem(:persistent_term.get(@key, {defaults(), []}), 0)

  @spec errors() :: [error]
  def errors, do: elem(:persistent_term.get(@key, {defaults(), []}), 1)

  def get(key), do: Map.get(all(), key, defaults()[key])

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

  ## Validation

  @doc """
  Validates one setting against its sub-schema (`#/properties/<key>`), so a
  bad value only affects that key. Keys the schema doesn't know are accepted.
  """
  def validate(key, value) do
    if Map.has_key?(schema(), key) do
      case Bee.JSON.Schema.validate(@schema, Bee.JSON.Schema.property_ref(key), value) do
        :ok -> :ok
        {:error, messages} -> {:error, Enum.join(messages, "; ")}
      end
    else
      :ok
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    File.mkdir_p(user_dir())
    Phoenix.PubSub.subscribe(Bee.PubSub, "fs")
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

  defp load(broadcast?) do
    {settings, errors} =
      Enum.reduce(paths(), {defaults(), []}, fn path, {settings, errors} ->
        case read(path) do
          {:ok, overrides} -> apply_overrides(settings, errors, path, overrides)
          {:error, message} -> {settings, errors ++ [%{path: path, message: message}]}
        end
      end)

    :persistent_term.put(@key, {settings, errors})

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

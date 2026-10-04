defmodule Bee.Commands.Keybindings do
  @moduledoc """
  Resolves the active keybindings: the defaults contributed to
  `Bee.Commands.Registry`, then the user's `<config_dir>/keybindings.json` (JSONC
  array, each entry validated against `priv/schemas/keybindings.schema.json`),
  with VS Code semantics:

    * entries are `{"key": "ctrl+k ctrl+s", "command": "...", "when": "..."}`
    * later entries win when several match (the client walks the list
      backwards and takes the first one whose `when` holds)
    * `"command": "-some.command"` removes earlier bindings of that command;
      if `key` and/or `when` are given, only the bindings that match them

  Resolved bindings: `%{key: strokes, mac: strokes, command: id, when: ast}`.
  The result lives in `:persistent_term`; reloads broadcast
  `{:keybindings_changed, bindings, errors}` on the `"keybindings"` topic.
  """
  use GenServer
  require Logger

  @topic "keybindings"
  @key {__MODULE__, :state}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Bee.PubSub, @topic)

  def all, do: elem(:persistent_term.get(@key, {[], []}), 0)
  def errors, do: elem(:persistent_term.get(@key, {[], []}), 1)

  @doc "Label of the binding that wins for `command`, e.g. \"Ctrl+Shift+P\", or nil."
  def label(command, bindings \\ all()) do
    case bindings |> Enum.reverse() |> Enum.find(&(&1.command == command)) do
      nil -> nil
      binding -> Bee.Commands.Keys.label(binding.key)
    end
  end

  def reload, do: GenServer.call(__MODULE__, :reload)

  def user_path, do: Path.join(Bee.Settings.user_dir(), "keybindings.json")

  def ensure_user_file! do
    path = user_path()

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      // Keyboard shortcuts. Entries here override Bee's defaults; later entries win.
      // See all commands with Ctrl+Shift+P. Examples:
      //
      //   { "key": "ctrl+alt+t", "command": "workbench.action.terminal.new" },
      //   { "key": "ctrl+w", "command": "workbench.action.closeActiveEditor", "when": "activeEditor" },
      //   { "key": "ctrl+b", "command": "-workbench.action.toggleSidebarVisibility" }
      [
      ]
      """)
    end

    path
  end

  @doc """
  Resolves `defaults` (contribution maps) and `user` (decoded JSON entries).
  Returns `{bindings, errors}`.
  """
  def resolve(defaults, user, known_commands \\ nil) do
    {bindings, errors} =
      Enum.reduce(defaults, {[], []}, fn binding, {acc, errors} ->
        case build(binding.key, binding.mac, binding.command, binding.when) do
          {:ok, b} -> {[b | acc], errors}
          {:error, reason} -> {acc, [reason | errors]}
        end
      end)

    {bindings, errors} =
      user
      |> Enum.with_index(1)
      |> Enum.reduce({bindings, errors}, fn {entry, index}, {acc, errors} ->
        case validate_and_apply(entry, acc, known_commands) do
          {:ok, acc, nil} -> {acc, errors}
          {:ok, acc, warning} -> {acc, ["entry #{index}: #{warning}" | errors]}
          {:error, reason} -> {acc, ["entry #{index}: #{reason}" | errors]}
        end
      end)

    {Enum.reverse(bindings), Enum.reverse(errors)}
  end

  # `acc` is in reverse order (newest first).
  defp apply_user(%{"command" => "-" <> command} = entry, acc, _known) do
    with {:ok, key} <- optional_key(entry["key"]),
         {:ok, when_ast} <- optional_when(entry["when"]) do
      remaining =
        Enum.reject(acc, fn b ->
          b.command == command and (key == nil or key in [b.key, b.mac]) and
            (when_ast == nil or when_ast == b.when)
        end)

      {:ok, remaining, nil}
    end
  end

  defp apply_user(%{"key" => key, "command" => command} = entry, acc, known)
       when is_binary(command) do
    with {:ok, binding} <- build(key, nil, command, entry["when"]) do
      warning = if known && command not in known, do: "unknown command #{inspect(command)}"
      {:ok, [binding | acc], warning}
    end
  end

  # Shape first (priv/schemas/keybindings.schema.json), then key and `when` syntax.
  defp validate_and_apply(entry, acc, known) do
    case Bee.JSON.Schema.validate("keybindings", "#/definitions/keybinding", entry) do
      :ok -> apply_user(entry, acc, known)
      {:error, messages} -> {:error, Enum.join(messages, "; ")}
    end
  end

  defp build(key, mac, command, when_source) do
    with {:ok, strokes} <- Bee.Commands.Keys.parse(key),
         {:ok, mac_strokes} <- if(mac, do: Bee.Commands.Keys.parse(mac), else: {:ok, strokes}),
         {:ok, when_ast} <- Bee.Commands.When.parse(when_source) do
      {:ok, %{key: strokes, mac: mac_strokes, command: command, when: when_ast}}
    end
  end

  defp optional_key(nil), do: {:ok, nil}
  defp optional_key(key), do: Bee.Commands.Keys.parse(key)
  defp optional_when(nil), do: {:ok, nil}
  defp optional_when(source), do: Bee.Commands.When.parse(source)

  ## Server

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Bee.PubSub, "fs")
    Bee.Commands.Registry.subscribe()
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
    if path == user_path(), do: load(true)
    {:noreply, state}
  end

  def handle_info({:contributions_changed, keys}, state) do
    if :commands in keys, do: load(true)
    {:noreply, state}
  end

  defp load(broadcast?) do
    known = Enum.map(Bee.Commands.Registry.commands(), & &1.id)

    {user, read_errors} =
      case read(user_path()) do
        {:ok, entries} -> {entries, []}
        {:error, message} -> {[], [message]}
      end

    {bindings, errors} = resolve(Bee.Commands.Registry.keybindings(), user, known)
    errors = Enum.map(read_errors ++ errors, &%{path: user_path(), message: &1})

    :persistent_term.put(@key, {bindings, errors})
    for %{message: message} <- errors, do: Logger.warning("Bee: keybindings.json: #{message}")

    if broadcast?,
      do: Phoenix.PubSub.broadcast(Bee.PubSub, @topic, {:keybindings_changed, bindings, errors})
  end

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, entries} when is_list(entries) <- Bee.JSON.JSONC.decode(text) do
      {:ok, entries}
    else
      {:error, :enoent} -> {:ok, []}
      {:ok, _} -> {:error, "must contain a JSON array"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end

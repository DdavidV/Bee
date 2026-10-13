defmodule BeeWeb.Workbench.SettingsEditor do
  @moduledoc """
  The settings page (VS Code's Settings editor), in an editor tab
  (`Bee.Workbench.open_settings/2`; the tab's path is "settings:"): every
  setting there is, grouped and searchable, each with the control its
  schema calls for (`Bee.Settings.Catalog`) – a switch, a list of values,
  a number, a text, a list, a table of patterns – and a way back to its
  default.

  It edits the user's settings file or the folder's (`scope`), as the
  files' own text: a change is written there (comments kept,
  `Bee.Settings.update/3`), a reset takes the setting out of the file
  (`Bee.Settings.unset/2`), and what the file says is what the page shows
  – also when the file is edited elsewhere.

  With a language picked it edits that language's block of the file
  (`"[elixir]": {…}`), for the settings a block can change
  (`Bee.Settings.language_overridable/0`).

  A value the setting's schema refuses isn't written: the reason is shown
  under its control.
  """
  use BeeWeb, :live_component

  alias Bee.Settings
  alias Bee.Settings.Catalog

  @impl true
  def mount(socket), do: {:ok, assign(socket, query: "", language: nil, errors: %{})}

  @impl true
  def update(assigns, socket) do
    # (A change of scope starts afresh: other values, other problems.)
    socket =
      if socket.assigns[:scope] not in [nil, assigns.scope],
        do: assign(socket, errors: %{}),
        else: socket

    # Opened to look for something (`search`: `{text, ref}`, once per ref).
    socket =
      case assigns[:search] do
        {query, _ref} = search ->
          if search == socket.assigns[:search], do: socket, else: assign(socket, query: query)

        _ ->
          socket
      end

    {:ok, socket |> assign(assigns) |> load()}
  end

  # What the page shows, from the schemas and the files as they are now.
  defp load(socket) do
    %{scope: scope, root: root, query: query, language: language} = socket.assigns
    file = file_scope(scope, root)
    below = if scope == :workspace, do: root

    groups =
      if language do
        keys = Settings.language_overridable()

        Catalog.groups()
        |> Enum.map(fn group ->
          %{group | settings: Enum.filter(group.settings, &(&1.key in keys))}
        end)
        |> Enum.reject(&(&1.settings == []))
      else
        Catalog.groups()
      end

    assign(socket,
      file: file,
      layer:
        if(language, do: Settings.language_layer(file, language), else: Settings.layer(file)),
      # What holds in this scope, the file's settings included.
      values: if(language, do: Settings.for_language(below, language), else: Settings.all(below)),
      groups: Catalog.search(groups, query),
      total: groups |> Enum.map(&length(&1.settings)) |> Enum.sum(),
      languages: languages(file),
      user_only: if(scope == :workspace, do: Settings.user_only(), else: [])
    )
  end

  defp file_scope(:workspace, root), do: {:workspace, root}
  defp file_scope(_user, _root), do: :user

  # Every language, by name; those the file has a block for first.
  defp languages(file) do
    with_block = Settings.block_languages(file)

    Bee.Languages.all()
    |> Enum.map(&%{id: &1.id, name: Bee.Languages.name(&1.id), block: &1.id in with_block})
    |> Enum.sort_by(&{not &1.block, String.downcase(&1.name)})
  end

  ## Events

  @impl true
  def handle_event("search", %{"query" => query}, socket),
    do: {:noreply, socket |> assign(query: query) |> load()}

  def handle_event("language", %{"language" => language}, socket) do
    language = if language == "", do: nil, else: language
    {:noreply, socket |> assign(language: language, errors: %{}) |> load()}
  end

  # A number or a text: its field left, or Enter in it (which sends the
  # key's name as "key"). It names its language itself (the page may have
  # gone on to another meanwhile).
  def handle_event("set", %{"setting" => key, "value" => input} = params, socket),
    do: set(socket, key, input, params["language"])

  # A switch or a list of values (a form's change).
  def handle_event("set", %{"key" => key, "value" => input}, socket),
    do: set(socket, key, input, socket.assigns.language)

  def handle_event("reset", %{"key" => key}, socket) do
    %{file: file, language: language} = socket.assigns

    result =
      if language,
        do: Settings.unset_language(file, language, key),
        else: Settings.unset(file, key)

    {:noreply, socket |> done(key, result) |> load()}
  end

  # A list: one more, or one fewer.
  def handle_event("list_add", %{"key" => key, "value" => value}, socket) do
    case String.trim(value) do
      "" -> {:noreply, socket}
      item -> write(socket, key, Enum.uniq(list(socket, key) ++ [item]))
    end
  end

  def handle_event("list_remove", %{"key" => key, "item" => item}, socket),
    do: write(socket, key, list(socket, key) -- [item])

  # A table of names: one's value; one more; one taken out of the file.
  def handle_event("map_put", %{"setting" => key} = params, socket),
    do: handle_event("map_put", params |> Map.delete("setting") |> Map.put("key", key), socket)

  def handle_event("map_put", %{"key" => key, "name" => name} = params, socket) do
    case {Catalog.get(key), String.trim(name)} do
      {_setting, ""} ->
        {:noreply, socket}

      {%{control: {:map, :boolean}}, name} ->
        write(socket, key, Map.put(own_map(socket, key), name, params["value"] in ["true", "on"]))

      {%{control: {:map, :string}}, name} ->
        case String.trim(params["value"] || "") do
          "" -> {:noreply, error(socket, key, "#{name}: a value is needed")}
          value -> write(socket, key, Map.put(own_map(socket, key), name, value))
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("map_remove", %{"key" => key, "name" => name}, socket) do
    case Map.delete(own_map(socket, key), name) do
      rest when map_size(rest) == 0 -> handle_event("reset", %{"key" => key}, socket)
      rest -> write(socket, key, rest)
    end
  end

  defp list(socket, key) do
    case value(socket.assigns, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # What the file itself says for a table (the rest comes from below it).
  defp own_map(socket, key) do
    case socket.assigns.layer[key] do
      %{} = map -> map
      _ -> %{}
    end
  end

  # What a control sent, for `language` (nil: every language).
  defp set(socket, key, input, language) do
    case Catalog.get(key) do
      %{control: control} ->
        with {:ok, value} <- Catalog.parse(control, input) do
          # (Left as it was – a field only passed through: nothing to write.)
          if unchanged?(socket, key, value, language),
            do: {:noreply, socket |> done(key, :ok) |> load()},
            else: write(socket, key, value, language)
        else
          {:error, message} -> {:noreply, error(socket, key, message)}
        end

      nil ->
        {:noreply, socket}
    end
  end

  defp unchanged?(socket, key, value, language) do
    %{scope: scope, root: root} = socket.assigns
    below = if scope == :workspace, do: root

    current =
      if language,
        do: Settings.get(key, below, language),
        else: Settings.get(key, below)

    current == value
  end

  defp write(socket, key, value), do: write(socket, key, value, socket.assigns.language)

  defp write(socket, key, value, language) do
    %{file: file} = socket.assigns

    result =
      cond do
        key in socket.assigns.user_only -> {:error, "only takes effect in the user settings"}
        language -> Settings.put_language(file, language, key, value)
        true -> Settings.update(file, key, fn _ -> value end)
      end

    {:noreply, socket |> done(key, result) |> load()}
  end

  defp done(socket, key, :ok), do: update(socket, :errors, &Map.delete(&1, key))
  defp done(socket, key, {:error, message}), do: error(socket, key, message)

  # (Without the file's path: the page says which file it is.)
  defp error(socket, key, message) do
    message = message |> to_string() |> String.replace(~r/^.*settings\.json: /, "")
    update(socket, :errors, &Map.put(&1, key, message))
  end

  ## The page

  # A setting's value on the page: what holds in this scope – the file's,
  # over what is below it (a table of patterns: both, merged).
  defp value(assigns, key), do: Map.get(assigns.values, key)

  defp modified?(assigns, key), do: Map.has_key?(assigns.layer, key)

  defp scope_name(:workspace), do: "Workspace"
  defp scope_name(_user), do: "User"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      data-scope={@scope}
      data-language={@language}
      class="h-full flex flex-col bg-editor text-editor-fg text-sm"
    >
      <header class="shrink-0 px-6 pt-4 pb-3 border-b border-tab-border space-y-3">
        <form id="settings-search" phx-change="search" phx-submit="search" phx-target={@myself}>
          <input
            type="search"
            name="query"
            value={@query}
            placeholder="Search settings"
            aria-label="Search settings"
            autocomplete="off"
            phx-debounce="150"
            class="input input-sm w-full bg-input text-input-fg"
          />
        </form>
        <div class="flex items-center gap-4">
          <div role="tablist" aria-label="Settings scope" class="flex gap-4">
            <button
              :for={
                {scope, command} <- [
                  user: "workbench.action.openSettings",
                  workspace: "workbench.action.openWorkspaceSettings"
                ]
              }
              type="button"
              role="tab"
              aria-selected={to_string(@scope == scope)}
              class={[
                "pb-1 border-b-2 cursor-pointer",
                if(@scope == scope,
                  do: "border-panel-title-border",
                  else: "border-transparent opacity-60 hover:opacity-100"
                )
              ]}
              phx-click="run_command"
              phx-value-command={command}
            >
              {scope_name(scope)}
            </button>
          </div>
          <form
            id="settings-language"
            phx-change="language"
            phx-target={@myself}
            class="flex items-center gap-2"
          >
            <label for="settings-language-select" class="opacity-70">For</label>
            <select
              id="settings-language-select"
              name="language"
              aria-label="Language"
              class="select select-sm bg-input text-input-fg"
            >
              <option value="" selected={@language == nil}>all languages</option>
              <option
                :for={language <- @languages}
                value={language.id}
                selected={@language == language.id}
              >
                {language.name}{if language.block, do: " •"}
              </option>
            </select>
          </form>
          <span class="flex-1" />
          <span id="settings-count" class="opacity-60">
            {count(@groups)} of {@total} settings
          </span>
          <button
            type="button"
            class="btn btn-xs btn-ghost"
            title={"Open #{scope_name(@scope)} Settings (JSON)"}
            phx-click="run_command"
            phx-value-command={
              if @scope == :workspace,
                do: "workbench.action.openWorkspaceSettingsFile",
                else: "workbench.action.openSettingsJson"
            }
          >
            Open Settings (JSON)
          </button>
        </div>
        <p :if={@language} id="settings-language-note" class="text-xs opacity-70">
          Settings for {Bee.Languages.name(@language)} files only, written to the
          <code>"{Settings.block_key(@language)}"</code>
          block of the {String.downcase(scope_name(@scope))} settings. These are the settings a language can have its own value for so far.
        </p>
      </header>

      <div class="flex-1 min-h-0 flex">
        <nav
          aria-label="Setting groups"
          class="shrink-0 w-52 overflow-y-auto py-3 border-r border-tab-border"
        >
          <button
            :for={group <- @groups}
            type="button"
            class="w-full px-6 py-1 text-left truncate cursor-pointer hover:bg-list-hover"
            phx-click={JS.dispatch("bee:scroll-to", to: "#settings-group-#{group.id}")}
          >
            {group.title}
            <span class="opacity-50">({length(group.settings)})</span>
          </button>
        </nav>

        <div id="settings-list" class="flex-1 min-w-0 overflow-y-auto px-6 pb-16">
          <p :if={@groups == []} id="settings-empty" class="py-6 opacity-60">
            No settings found.
          </p>
          <section
            :for={group <- @groups}
            id={"settings-group-#{group.id}"}
            data-settings-group={group.title}
          >
            <h2 class="pt-5 pb-1 text-lg font-semibold">{group.title}</h2>
            <.setting
              :for={setting <- group.settings}
              setting={setting}
              value={value(assigns, setting.key)}
              modified={modified?(assigns, setting.key)}
              own={@layer[setting.key]}
              error={@errors[setting.key]}
              language={@language}
              locked={setting.key in @user_only}
              scope={@scope}
              myself={@myself}
            />
          </section>
        </div>
      </div>
    </div>
    """
  end

  defp count(groups), do: groups |> Enum.map(&length(&1.settings)) |> Enum.sum()

  attr :setting, :map, required: true
  attr :value, :any, required: true
  attr :modified, :boolean, required: true
  attr :own, :any, default: nil, doc: "what the file itself sets it to"
  attr :error, :string, default: nil
  attr :language, :string, default: nil
  attr :locked, :boolean, default: false, doc: "not this file's to set"
  attr :scope, :atom, required: true
  attr :myself, :any, required: true

  defp setting(assigns) do
    ~H"""
    <div
      id={"setting-#{@setting.key}"}
      data-setting={@setting.key}
      data-modified={to_string(@modified)}
      class={[
        "group/setting relative py-3 pl-3 border-l-2",
        if(@modified, do: "border-panel-title-border", else: "border-transparent"),
        @locked && "opacity-60"
      ]}
    >
      <div class="flex items-baseline gap-2">
        <span>
          <span :if={@setting.prefix != ""} class="opacity-70">{@setting.prefix}:</span>
          <span class="font-semibold">{@setting.title}</span>
        </span>
        <code class="text-xs opacity-50">{@setting.key}</code>
        <span :if={@modified} class="text-xs opacity-60">(modified)</span>
        <span class="flex-1" />
        <button
          :if={@modified and not @locked}
          type="button"
          class="btn btn-xs btn-ghost"
          title="Reset Setting"
          aria-label={"Reset #{@setting.title}"}
          phx-click="reset"
          phx-value-key={@setting.key}
          phx-target={@myself}
        >
          Reset
        </button>
      </div>
      <p :if={@setting.description != ""} class="mt-0.5 opacity-80">
        {@setting.description}
      </p>
      <p :if={@setting.deprecated} class="mt-0.5 text-warning">{@setting.deprecated}</p>
      <p :if={@locked} class="mt-0.5 text-xs">
        Only takes effect in the user settings: a folder can't set it for itself.
      </p>
      <div class="mt-1.5">
        <.control
          control={@setting.control}
          setting={@setting}
          value={@value}
          own={@own}
          language={@language}
          locked={@locked}
          scope={@scope}
          myself={@myself}
        />
      </div>
      <p :if={@error} role="alert" class="mt-1 text-error">{@error}</p>
    </div>
    """
  end

  attr :control, :any, required: true
  attr :setting, :map, required: true
  attr :value, :any, required: true
  attr :own, :any, default: nil
  attr :language, :string, default: nil
  attr :locked, :boolean, default: false
  attr :scope, :atom, required: true
  attr :myself, :any, required: true

  defp control(%{control: :boolean} = assigns) do
    ~H"""
    <form
      id={field_id(@setting.key, @language)}
      phx-change="set"
      phx-target={@myself}
      class="flex items-center gap-2"
    >
      <input type="hidden" name="key" value={@setting.key} />
      <%!-- (Off sends this; on, the switch's own value after it.) --%>
      <input type="hidden" name="value" value="false" />
      <input
        type="checkbox"
        role="switch"
        name="value"
        value="true"
        checked={@value == true}
        disabled={@locked}
        aria-label={@setting.title}
        class="toggle toggle-sm"
      />
      <span class="opacity-70">{if @value == true, do: "On", else: "Off"}</span>
    </form>
    """
  end

  defp control(%{control: {:enum, options}} = assigns) do
    assigns = assign(assigns, :options, options)

    ~H"""
    <form id={field_id(@setting.key, @language)} phx-change="set" phx-target={@myself}>
      <input type="hidden" name="key" value={@setting.key} />
      <select
        name="value"
        disabled={@locked}
        aria-label={@setting.title}
        class="select select-sm bg-input text-input-fg min-w-48"
      >
        <%!-- (A value that isn't one of them – set in the file – is shown as it is.) --%>
        <option :if={not Enum.any?(@options, &(elem(&1, 0) == @value))} value="" selected>
          {Catalog.encode(@value)}
        </option>
        <option
          :for={{value, label} <- @options}
          value={Catalog.encode(value)}
          selected={value == @value}
        >
          {label}
        </option>
      </select>
    </form>
    """
  end

  # A number or a text is written when its field is left, or on Enter (not
  # as it is typed). The field says what it is for – the language too – so
  # that what it sends is written where it was typed.
  defp control(%{control: {:number, range}} = assigns) do
    assigns = assign(assigns, :range, range)

    ~H"""
    <div class="flex items-center gap-2">
      <input
        type="number"
        id={field_id(@setting.key, @language)}
        value={@value}
        min={@range.min}
        max={@range.max}
        step={if @range.integer, do: "1", else: "any"}
        disabled={@locked}
        aria-label={@setting.title}
        phx-blur="set"
        phx-keydown="set"
        phx-key="Enter"
        phx-value-setting={@setting.key}
        phx-value-language={@language}
        phx-target={@myself}
        class="input input-sm bg-input text-input-fg w-32"
      />
      <span :if={@range.min || @range.max} class="text-xs opacity-60">
        {range_text(@range)}
      </span>
    </div>
    """
  end

  defp control(%{control: {:string, _}} = assigns) do
    ~H"""
    <input
      type="text"
      id={field_id(@setting.key, @language)}
      value={@value}
      disabled={@locked}
      aria-label={@setting.title}
      autocomplete="off"
      spellcheck="false"
      phx-blur="set"
      phx-keydown="set"
      phx-key="Enter"
      phx-value-setting={@setting.key}
      phx-value-language={@language}
      phx-target={@myself}
      class="input input-sm bg-input text-input-fg w-full max-w-xl"
    />
    """
  end

  defp control(%{control: :list} = assigns) do
    assigns = assign(assigns, :items, if(is_list(assigns.value), do: assigns.value, else: []))

    ~H"""
    <div class="max-w-xl" data-list>
      <p :if={@items == []} class="opacity-60">None.</p>
      <div
        :for={item <- @items}
        data-item={item}
        class="flex items-center gap-2 py-0.5 hover:bg-list-hover"
      >
        <code class="flex-1 truncate">{item}</code>
        <button
          type="button"
          class="btn btn-xs btn-ghost"
          title={"Remove #{item}"}
          aria-label={"Remove #{item}"}
          phx-click="list_remove"
          phx-value-key={@setting.key}
          phx-value-item={item}
          phx-target={@myself}
        >
          Remove
        </button>
      </div>
      <form
        id={add_id(@setting.key)}
        phx-submit={
          JS.push("list_add")
          |> JS.dispatch("bee:clear", to: "##{add_id(@setting.key)} [name=value]")
        }
        phx-target={@myself}
        class="flex gap-2 mt-1"
      >
        <input type="hidden" name="key" value={@setting.key} />
        <input
          type="text"
          name="value"
          placeholder="Add an item"
          aria-label={"Add to #{@setting.title}"}
          autocomplete="off"
          class="input input-sm bg-input text-input-fg flex-1"
        />
        <button type="submit" class="btn btn-sm">Add</button>
      </form>
    </div>
    """
  end

  defp control(%{control: {:map, kind}} = assigns) do
    rows = if is_map(assigns.value), do: Enum.sort(assigns.value), else: []
    own = if is_map(assigns.own), do: assigns.own, else: %{}
    assigns = assign(assigns, kind: kind, rows: rows, own_map: own)

    ~H"""
    <div class="max-w-xl" data-map>
      <p :if={@rows == []} class="opacity-60">None.</p>
      <div
        :for={{name, value} <- @rows}
        data-item={name}
        class="flex items-center gap-2 py-0.5 hover:bg-list-hover"
      >
        <code class="flex-1 truncate">{name}</code>
        <form
          :if={@kind == :boolean}
          id={field_id(@setting.key <> "/" <> name, nil)}
          phx-change="map_put"
          phx-target={@myself}
          class="flex items-center"
        >
          <input type="hidden" name="key" value={@setting.key} />
          <input type="hidden" name="name" value={name} />
          <input type="hidden" name="value" value="false" />
          <input
            type="checkbox"
            role="switch"
            name="value"
            value="true"
            checked={value == true}
            aria-label={name}
            class="toggle toggle-xs"
          />
        </form>
        <input
          :if={@kind == :string}
          type="text"
          id={field_id(@setting.key <> "/" <> name, nil)}
          value={value}
          aria-label={name}
          autocomplete="off"
          phx-blur="map_put"
          phx-keydown="map_put"
          phx-key="Enter"
          phx-value-setting={@setting.key}
          phx-value-name={name}
          phx-target={@myself}
          class="input input-xs bg-input text-input-fg w-40"
        />
        <%!-- Only what this file adds can be taken out of it. --%>
        <button
          type="button"
          class={["btn btn-xs btn-ghost", not Map.has_key?(@own_map, name) && "invisible"]}
          disabled={not Map.has_key?(@own_map, name)}
          title={"Remove #{name}"}
          aria-label={"Remove #{name}"}
          phx-click="map_remove"
          phx-value-key={@setting.key}
          phx-value-name={name}
          phx-target={@myself}
        >
          Remove
        </button>
      </div>
      <form
        id={add_id(@setting.key)}
        phx-submit={
          JS.push("map_put")
          |> JS.dispatch("bee:clear", to: "##{add_id(@setting.key)} [name=name]")
        }
        phx-target={@myself}
        class="flex gap-2 mt-1"
      >
        <input type="hidden" name="key" value={@setting.key} />
        <input
          type="text"
          name="name"
          placeholder={if @kind == :boolean, do: "Add a pattern", else: "Pattern"}
          aria-label={"Add to #{@setting.title}"}
          autocomplete="off"
          class="input input-sm bg-input text-input-fg flex-1"
        />
        <input :if={@kind == :boolean} type="hidden" name="value" value="true" />
        <input
          :if={@kind == :string}
          type="text"
          name="value"
          placeholder="Value"
          aria-label={"Value to add to #{@setting.title}"}
          autocomplete="off"
          class="input input-sm bg-input text-input-fg w-40"
        />
        <button type="submit" class="btn btn-sm">Add</button>
      </form>
    </div>
    """
  end

  # Anything else: its value as JSON, edited in the file.
  defp control(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <code class="truncate opacity-80 max-w-xl">{Jason.encode!(@value)}</code>
      <button
        type="button"
        class="link"
        phx-click="run_command"
        phx-value-command={
          if @scope == :workspace,
            do: "workbench.action.openWorkspaceSettingsFile",
            else: "workbench.action.openSettingsJson"
        }
      >
        Edit in settings.json
      </button>
    </div>
    """
  end

  # A field's id: another one for another language (its value isn't that
  # language's: the page mustn't carry what was typed over).
  defp field_id(key, language),
    do:
      "setting-field-" <>
        String.replace("#{key}#{language && "@" <> language}", ~r/[^A-Za-z0-9_@-]/, "-")

  # The id of a setting's "add" form (a setting's name has dots).
  defp add_id(key), do: "setting-add-" <> String.replace(key, ~r/[^A-Za-z0-9_-]/, "-")

  defp range_text(%{min: min, max: max}) when not is_nil(min) and not is_nil(max),
    do: "#{min} to #{max}"

  defp range_text(%{min: min}) when not is_nil(min), do: "#{min} or more"
  defp range_text(%{max: max}), do: "#{max} or less"
end

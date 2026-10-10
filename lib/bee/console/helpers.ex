defmodule Bee.Console.Helpers do
  @moduledoc """
  What the Bee Console (`Bee.Console`) imports, besides `IEx.Helpers`: Bee
  from the inside, acting on the console's window. `help()` lists them.
  """

  alias Bee.Commands.Keybindings
  alias Bee.Commands.Registry, as: CommandRegistry

  @silent :"do not show this result in output"

  @doc "Lists the helpers."
  def help do
    IO.puts("""
    \e[1mBee Console helpers\e[0m (plus IEx's: h/1, i/1, exports/1…)

      commands()          every command, with its title and key
      commands("term")    those matching
      run(id)             runs a command in this window, as if you had
      run(id, args)       with arguments, e.g. run("bee.openFile", ["/path"])
      window()            this window's state: folder, editors, panel…
      root()              this window's folder
      workspaces()        the open folders
      plugins()           the plugins of this window's folder and their status
      grammars()          each language's highlighting: who contributes it,
                          which one Bee uses (*); grammars("erlang") filters
      features()          each plugin's features, active or not, and what
                          Bee doesn't support yet; features("grammars") filters
      memory()            Bee's memory (MB), CPU time and process count

    Anything else is plain Elixir inside Bee: Bee.Settings.all(root()),
    Bee.Plugins.reload(), :sys.get_state(Bee.Plugins.Manager)…
    """)

    @silent
  end

  @doc "Prints the commands whose id or title contains `filter`."
  def commands(filter \\ "") do
    filter = String.downcase(filter)
    keys = Keybindings.all()

    rows =
      for command <- CommandRegistry.commands(),
          title = CommandRegistry.label(command),
          String.contains?(String.downcase(command.id <> " " <> title), filter) do
        {command.id, title, Keybindings.label(command.id, keys)}
      end

    width = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max(fn -> 0 end)

    for {id, title, key} <- Enum.sort(rows) do
      IO.puts(
        "#{String.pad_trailing(id, width)}  #{title}#{if key, do: "  \e[2m#{key}\e[0m", else: ""}"
      )
    end

    IO.puts("\e[2m#{length(rows)} commands\e[0m")
    @silent
  end

  @doc """
  Runs command `id` (with `args`) in the console's window, as the palette
  would. Returns at once.
  """
  def run(id, args \\ []) when is_binary(id) and is_list(args) do
    send(console().window, {:bee_api, {:execute_command, id, args}})
    :ok
  end

  @doc "The console's window state: its folder, editors, panel, palette…"
  def window do
    ref = make_ref()
    send(console().window, {:bee_console, :window, self(), ref})

    receive do
      {^ref, state} -> state
    after
      5_000 -> raise "the window didn't answer"
    end
  end

  @doc "The console's window's folder."
  def root, do: console().root

  @doc "The open folders."
  def workspaces, do: Bee.Workspace.list()

  @doc "The plugins of the window's folder: `%{name => status}`."
  def plugins, do: Map.new(Bee.Plugins.list(root()), &{&1.name, &1.status})

  @doc """
  Prints each language's highlighting (`Bee.Languages`): every grammar
  contributed for it – a TextMate grammar or a CodeMirror mode, by a plugin
  or by Bee – in contribution order, * on the one Bee uses (the last).
  For a TextMate grammar, the file loaded is the last one contributed for
  its scope, which another plugin may have. Then the grammars of no
  language (included by others, or injected). `filter` matches a
  language id, a plugin or a scope.
  """
  def grammars(filter \\ "") do
    filter = String.downcase(filter)

    contributed =
      for {source, %{grammars: grammars}} <- Bee.Contributions.entries(:languages),
          grammar <- grammars,
          do: {source(source), grammar}

    # The file the browser loads per scope: the last one contributed.
    files = Map.new(for {from, %{scope: scope} = g} <- contributed, do: {scope, {from, g}})

    matches? = fn key, entries ->
      filter == "" or String.contains?(String.downcase(key), filter) or
        Enum.any?(entries, fn {from, g} ->
          text = Enum.join([from, g[:scope] | Map.get(g, :inject_to, [])], " ")
          String.contains?(String.downcase(text), filter)
        end)
    end

    by_language =
      contributed
      |> Enum.filter(fn {_from, g} -> g.language end)
      |> Enum.group_by(fn {_from, g} -> g.language end)
      |> Enum.filter(fn {language, entries} -> matches?.(language, entries) end)
      |> Enum.sort()

    width =
      contributed |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max(fn -> 0 end)

    for {language, entries} <- by_language do
      name = Bee.Languages.name(language)
      IO.puts("\e[1m#{language}\e[0m#{if name != language, do: " (#{name})", else: ""}")
      used = length(entries) - 1

      entries
      |> Enum.with_index()
      |> Enum.each(fn {{from, g}, index} ->
        mark = if index == used, do: "\e[32m*\e[0m", else: " "
        note = if index == used, do: "", else: "  \e[2moverridden\e[0m"

        IO.puts(
          "  #{mark} #{String.pad_trailing(from, width)}  #{describe(g, index == used && files)}#{note}"
        )
      end)
    end

    helpers =
      for {from, %{language: nil} = g} <- contributed,
          matches?.("", [{from, g}]),
          do: {from, g}

    if helpers != [] do
      IO.puts("\e[1m(no language)\e[0m \e[2mincluded by other grammars, or injected\e[0m")

      for {from, g} <- helpers do
        into =
          if g.inject_to == [], do: "", else: "  -> injected into #{Enum.join(g.inject_to, ", ")}"

        IO.puts("    #{String.pad_trailing(from, width)}  #{describe(g, files)}#{into}")
      end
    end

    IO.puts("\e[2m#{length(by_language)} languages\e[0m")
    @silent
  end

  @doc """
  Prints each plugin's features – what its `plugin.json` contributes – and
  whether they're active in Bee:

    * `active` – registered and in effect
    * `in use` / `available` – a theme, selected or not
    * `overridden by …` – a grammar another one replaces
    * inactive – the plugin is disabled or invalid, or its contributions
      weren't registered (the reason is shown)

  Then its server and browser parts, and – for an extension installed from
  Open VSX or a VSIX – what it contributes in VS Code that Bee doesn't
  support yet. `filter` matches a plugin, a kind of feature ("grammars",
  "commands"…) or a feature (an id, a title).
  """
  def features(filter \\ "") do
    filter = String.downcase(filter)
    root = current_root()
    registered = MapSet.new(Bee.Contributions.sources())

    shown =
      for plugin <- Bee.Plugins.list(root),
          lines =
            plugin_features(
              plugin,
              MapSet.member?(registered, {:plugin, plugin.name}),
              filter,
              root
            ),
          lines != [] do
        Enum.each(lines, &IO.puts/1)
        plugin
      end

    IO.puts("\e[2m#{length(shown)} plugins\e[0m")
    @silent
  end

  # The lines printed for `plugin`, [] when nothing matches `filter`.
  defp plugin_features(plugin, registered?, filter, root) do
    contributes = (plugin.manifest || %{})["contributes"] || %{}
    whole? = filter == "" or matches?([plugin.name, plugin.display_name], filter)

    # Why nothing is in effect, or nil.
    inactive =
      cond do
        plugin.status == :disabled -> "inactive: plugin disabled"
        plugin.status == :invalid -> "inactive: plugin invalid"
        not registered? -> "inactive: not registered"
        true -> nil
      end

    state = fn item_state -> inactive || item_state end

    sections =
      for {title, items} <- feature_items(plugin, contributes, root),
          items != [],
          items =
            if(whole? or matches?([title], filter),
              do: items,
              else: Enum.filter(items, fn {text, _} -> matches?([text], filter) end)
            ),
          items != [] do
        width = items |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()

        ["  #{title}"] ++
          for {text, item_state} <- items,
              do: "    #{String.pad_trailing(text, width)}  #{color_state(state.(item_state))}"
      end

    unsupported =
      for key <- unsupported(plugin), whole? or matches?([key, "unsupported"], filter), do: key

    if sections == [] and unsupported == [] and not whole? do
      []
    else
      header =
        "\e[1m#{plugin.name}\e[0m#{if plugin.version, do: " #{plugin.version}", else: ""}" <>
          "  \e[2m#{plugin.scope} · #{status_text(plugin.status)}\e[0m"

      errors = for e <- plugin.errors, do: "  \e[31m#{e.message}\e[0m"
      parts = if whole?, do: parts(plugin, inactive), else: []

      unsupported_line =
        if unsupported == [],
          do: [],
          else: ["  \e[2mNot supported by Bee yet: #{Enum.join(unsupported, ", ")}\e[0m"]

      [header | errors] ++ List.flatten(sections) ++ parts ++ unsupported_line
    end
  end

  # {section title, [{item text, state}]} from the plugin's contributes.
  defp feature_items(plugin, contributes, root) do
    list = &List.wrap(contributes[&1])
    color_theme = Bee.Settings.get("workbench.colorTheme", root)
    icon_theme = Bee.Settings.get("workbench.iconTheme", root)
    theme_state = &if(&1 == &2, do: "in use", else: "available")

    [
      {"Commands", for(c <- list.("commands"), do: {"#{c["command"]}  #{c["title"]}", "active"})},
      {"Keybindings",
       for(k <- list.("keybindings"), do: {"#{k["key"]}  #{k["command"]}", "active"})},
      {"Menus",
       for(
         {menu, items} <- Enum.sort(contributes["menus"] || %{}),
         i <- List.wrap(items),
         do: {"#{menu}  #{i["command"]}", "active"}
       )},
      {"Settings",
       for(
         c <- list.("configuration"),
         {key, _} <- Enum.sort(c["properties"] || %{}),
         do: {key, "active"}
       )},
      {"Languages",
       for(
         l <- list.("languages"),
         do: {Enum.join([l["id"] | List.wrap(l["extensions"])], " "), "active"}
       )},
      {"Grammars", for(g <- list.("grammars"), do: grammar_feature(plugin.name, g))},
      {"Color Themes",
       for(
         t <- list.("themes"),
         id = t["id"] || t["label"],
         do: {theme_text(id, t["label"]), theme_state.(id, color_theme)}
       )},
      {"File Icon Themes",
       for(
         t <- list.("iconThemes"),
         do: {theme_text(t["id"], t["label"]), theme_state.(t["id"], icon_theme)}
       )},
      {"JSON Validation",
       for(
         v <- list.("jsonValidation"),
         do: {"#{Enum.join(List.wrap(v["fileMatch"]), " ")}  #{v["url"]}", "active"}
       )},
      {"Snippets",
       for(
         sn <- list.("snippets"),
         do: {"#{sn["language"] || "all languages"}  #{sn["path"]}", "active"}
       )},
      {"View Containers",
       for(
         {where, cs} <- Enum.sort(contributes["viewsContainers"] || %{}),
         c <- List.wrap(cs),
         do: {"#{c["id"]}  #{c["title"]} (#{where})", "active"}
       )},
      {"Views",
       for(
         {where, vs} <- Enum.sort(contributes["views"] || %{}),
         v <- List.wrap(vs),
         do: {"#{v["id"]}  #{v["name"]} (#{where})", "active"}
       )}
    ]
  end

  # Like the Plugins view: a server part not started is just installed.
  defp status_text(:inactive), do: "installed"
  defp status_text(status), do: to_string(status)

  defp theme_text(id, label) when label in [nil, id], do: id
  defp theme_text(id, label), do: "#{id}  #{label}"

  # A grammar is in effect when it's the one used for its language (the
  # last contributed), and its scope's file is its own.
  defp grammar_feature(name, %{"mode" => mode} = g) do
    {"#{g["language"]}  CodeMirror mode #{mode}",
     grammar_state(name, g["language"], fn h -> h[:mode] == mode end)}
  end

  defp grammar_feature(name, %{"scopeName" => scope} = g) do
    text = "#{scope}#{if g["language"], do: " (#{g["language"]})", else: ""}  #{g["path"]}"

    file_owner =
      Bee.Contributions.entries(:languages)
      |> Enum.flat_map(fn {source, %{grammars: gs}} ->
        for %{scope: ^scope} <- gs, do: source(source)
      end)
      |> List.last()

    state =
      cond do
        file_owner != name and file_owner != nil -> "overridden by #{file_owner}"
        g["language"] -> grammar_state(name, g["language"], fn h -> h[:scope] == scope end)
        true -> "active"
      end

    {text, state}
  end

  defp grammar_state(name, language, ours?) do
    winner =
      Bee.Contributions.entries(:languages)
      |> Enum.flat_map(fn {source, %{grammars: gs}} ->
        for %{language: ^language} <- gs, do: source(source)
      end)
      |> List.last()

    cond do
      winner == name and ours?.(Bee.Languages.highlight(language)) -> "active"
      winner -> "overridden by #{winner}"
      true -> "active"
    end
  end

  # Its server and browser parts, in this window's folder.
  defp parts(plugin, inactive) do
    server =
      if plugin.server? do
        state =
          inactive ||
            case plugin.status do
              :inactive -> "not started (starts on: #{Enum.join(plugin.activation_events, ", ")})"
              status -> to_string(status)
            end

        ["  Server part  #{color_state(state)}"]
      else
        []
      end

    browser =
      if plugin.browser, do: ["  Browser part  #{color_state(inactive || "active")}"], else: []

    server ++ browser
  end

  # Contribution points of a VS Code extension's package.json that Bee
  # doesn't read.
  @supported ~w(commands keybindings menus submenus configuration configurationDefaults) ++
               ~w(languages grammars themes iconThemes snippets jsonValidation)
  defp unsupported(plugin) do
    with dir when is_binary(dir) <- plugin.dir,
         true <- Bee.Plugins.Vsix.marker(dir) != %{},
         {:ok, text} <- File.read(Path.join(plugin.dir, "package.json")),
         {:ok, %{"contributes" => %{} = contributes}} <- Bee.JSON.JSONC.decode(text) do
      contributes |> Map.keys() |> Enum.reject(&(&1 in @supported)) |> Enum.sort()
    else
      _ -> []
    end
  end

  defp matches?(texts, filter),
    do: Enum.any?(texts, &(is_binary(&1) and String.contains?(String.downcase(&1), filter)))

  defp color_state("active"), do: "\e[32mactive\e[0m"
  defp color_state("in use"), do: "\e[32min use\e[0m"
  defp color_state("overridden" <> _ = s), do: "\e[33m#{s}\e[0m"
  defp color_state("inactive" <> _ = s), do: "\e[2m#{s}\e[0m"
  defp color_state(s), do: s

  # The console's folder; outside the console (tests) Bee's.
  defp current_root do
    case Process.get(:bee_console) do
      %{root: root} -> root
      _ -> Bee.Workspace.root()
    end
  end

  defp source({:plugin, name}), do: name
  defp source({:builtin, name}), do: "Bee (#{name})"

  defp describe(%{mode: mode}, _files) when is_binary(mode), do: "CodeMirror mode #{mode}"

  # `files`: scope -> the file loaded for it, for the grammar used (its
  # file may be another plugin's); false for the others: their own.
  defp describe(%{scope: scope} = g, files) do
    {from, loaded} = if files, do: files[scope], else: {nil, g}

    file =
      case Bee.Plugins.get(loaded.plugin) do
        %{dir: dir} -> Path.relative_to(loaded.path, dir)
        nil -> loaded.path
      end

    elsewhere = if loaded.path != g.path, do: " \e[33m(the file of #{from})\e[0m", else: ""
    "TextMate #{scope}  \e[2m#{file}\e[0m#{elsewhere}"
  end

  @doc "Bee's memory in MB, CPU time and process count."
  def memory do
    mb = &div(&1, 1_048_576)
    memory = :erlang.memory()
    {cpu_ms, _} = :erlang.statistics(:runtime)

    %{
      total_mb: mb.(memory[:total]),
      processes_mb: mb.(memory[:processes]),
      code_mb: mb.(memory[:code]),
      binary_mb: mb.(memory[:binary]),
      ets_mb: mb.(memory[:ets]),
      cpu_ms: cpu_ms,
      processes: length(Process.list())
    }
  end

  defp console do
    Process.get(:bee_console) || raise "only in the Bee Console"
  end
end

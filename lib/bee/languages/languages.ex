defmodule Bee.Languages do
  @moduledoc """
  The languages Bee knows: a `Bee.Contributions.Point` for the `languages`
  and `grammars` sections of manifests (Bee's own are in
  `priv/contributions/languages.json`).

  A language is identified by its id (`"elixir"`), the key shared by
  highlighting, `when` clauses (`editorLangId`) and – later – LSP.
  Contributions with the same id merge, so a plugin can add file names to an
  existing language.

  A grammar highlights a language, the last one contributed wins:

    * `{"language", "mode"}` – a CodeMirror mode registered in the browser
      (bundled with Bee, or a browser plugin's)
    * `{"language", "scopeName", "path"}` – a TextMate grammar file, like
      VS Code's (plugins only; the browser runs it with `vscode-textmate`).
      Without a `language` it is only included by other grammars, or
      injected into them (`injectTo`).

  `detect/2` picks a file's language like VS Code, first match wins:

    1. the `files.associations` setting (glob → language id)
    2. `filenames`
    3. `filenamePatterns`
    4. `extensions` (the longest matching one)
    5. `firstLine` (a regex, against the file's first line)
    6. `"plaintext"`

  Later sources win over earlier ones for the same file name or extension.

  A language contributed by a plugin may have a `configuration`, a
  `language-configuration.json` like VS Code's (comments, brackets,
  auto-closing pairs, indentation rules, onEnter rules, folding):
  `configuration/1` gives it to the editor, normalized; the last one
  contributed for a language wins.
  """
  @behaviour Bee.Contributions.Point

  alias Bee.Contributions
  alias Bee.Workspace.Glob

  @type language :: %{
          id: String.t(),
          aliases: [String.t()],
          extensions: [String.t()],
          filenames: [String.t()],
          filename_patterns: [String.t()],
          first_line: String.t() | nil
        }

  @plaintext "plaintext"

  @doc "All languages, contributions with the same id merged."
  @spec all() :: [language]
  def all do
    contributed()
    |> Enum.reduce({[], %{}}, fn lang, {order, merged} ->
      merged =
        Map.update(merged, lang.id, lang, fn acc ->
          %{
            acc
            | aliases: if(acc.aliases == [], do: lang.aliases, else: acc.aliases),
              extensions: acc.extensions ++ lang.extensions,
              filenames: acc.filenames ++ lang.filenames,
              filename_patterns: acc.filename_patterns ++ lang.filename_patterns,
              first_line: lang.first_line || acc.first_line
          }
        end)

      {if(lang.id in order, do: order, else: order ++ [lang.id]), merged}
    end)
    |> then(fn {order, merged} -> Enum.map(order, &merged[&1]) end)
  end

  @spec get(String.t()) :: language | nil
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "Display name: the first alias, or the id."
  def name(id) do
    case get(id) do
      %{aliases: [name | _]} -> name
      _ -> id
    end
  end

  @doc """
  How the browser highlights language `id`: `%{mode: name}` (a CodeMirror
  mode), `%{scope: scope_name}` (a TextMate grammar, see `grammars/0`) or
  `%{}` (not at all).
  """
  def highlight(id) do
    case Enum.filter(grammar_entries(), &(&1.language == id)) |> List.last() do
      %{mode: mode} when is_binary(mode) -> %{mode: mode}
      %{scope: scope} -> %{scope: scope}
      nil -> %{}
    end
  end

  @doc """
  Language `id`'s configuration (see the module doc), or nil: a map in the
  file's own keys – `comments` (`lineComment`, `blockComment`),
  `brackets`, `autoClosingPairs` and `surroundingPairs` (`[{open, close}]`),
  `autoCloseBefore`, `indentationRules`, `onEnterRules`, `folding` – with
  regexes as `%{"pattern" => source, "flags" => flags}` (JavaScript
  regexes, compiled by the editor).
  """
  def configuration(id) do
    contributed()
    |> Enum.filter(&(&1.id == id and &1.configuration))
    |> List.last()
    |> case do
      nil -> nil
      lang -> lang.configuration
    end
  end

  @doc "The CodeMirror mode highlighting `id`, or nil (none, or a TextMate grammar)."
  def mode(id), do: highlight(id)[:mode]

  @doc """
  The TextMate grammars, for the browser: `[%{scope, url, injectTo,
  embeddedLanguages, language}]`, one per scope (the last contributed).
  """
  def grammars do
    for %{scope: scope} = g when is_binary(scope) <- grammar_entries(),
        into: %{},
        do:
          {scope,
           %{
             scope: scope,
             url: g.url,
             injectTo: g.inject_to,
             embeddedLanguages: g.embedded_languages,
             language: g.language
           }}
  end

  @doc "Whether `path` is a TextMate grammar file of plugin `name` (served to the browser)."
  def grammar_file?(name, path),
    do: Enum.any?(grammar_entries(), &(&1[:plugin] == name and &1[:path] == path))

  defp grammar_entries,
    do: Enum.flat_map(Contributions.entries(:languages), &elem(&1, 1).grammars)

  @doc """
  The language of `path`. Options:

    * `:first_line` – the file's first line (for `firstLine` rules)
    * `:associations` – glob → id map, default: the `files.associations` setting
    * `:root` – patterns containing `/` match the path relative to it
      (default: the open workspace the file is in)
  """
  def detect(path, opts \\ []) do
    root =
      Keyword.get_lazy(opts, :root, fn -> Bee.Workspace.for_path(path) || Bee.Workspace.root() end)

    associations = Keyword.get_lazy(opts, :associations, fn -> associations(root) end)
    first_line = opts[:first_line]

    basename = Path.basename(path)
    lower = String.downcase(basename)
    rel = if String.starts_with?(path, root <> "/"), do: Path.relative_to(path, root), else: path
    languages = contributed()

    by_association(associations, basename, rel) ||
      last(languages, &(lower in Enum.map(&1.filenames, fn f -> String.downcase(f) end))) ||
      last(languages, &Enum.any?(&1.filename_patterns, fn p -> glob?(p, basename, rel) end)) ||
      by_extension(languages, lower) ||
      (first_line && last(languages, &first_line?(&1.first_line, first_line))) ||
      @plaintext
  end

  @doc "The first line of `text`, as `detect/2` wants it."
  def first_line(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 200)
  end

  defp associations(root) do
    case Bee.Settings.get("files.associations", root) do
      %{} = map -> map
      _ -> %{}
    end
  end

  defp by_association(associations, basename, rel) do
    Enum.find_value(associations, fn {pattern, id} -> glob?(pattern, basename, rel) && id end)
  end

  # Patterns with a slash match the (workspace-relative) path, others the name.
  defp glob?(pattern, basename, rel) do
    Glob.match?(pattern, if(String.contains?(pattern, "/"), do: rel, else: basename))
  end

  defp by_extension(languages, lower) do
    languages
    |> Enum.with_index()
    |> Enum.flat_map(fn {lang, index} ->
      for ext <- lang.extensions,
          String.ends_with?(lower, String.downcase(ext)),
          do: {byte_size(ext), index, lang.id}
    end)
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> nil
      {_size, _index, id} -> id
    end
  end

  defp first_line?(nil, _line), do: false
  defp first_line?(source, line), do: Regex.match?(Regex.compile!(source), line)

  defp last(languages, fun) do
    case languages |> Enum.filter(fun) |> List.last() do
      nil -> nil
      lang -> lang.id
    end
  end

  # Every contributed language record, in contribution order (not merged).
  defp contributed do
    Enum.flat_map(Contributions.entries(:languages), &elem(&1, 1).languages)
  end

  ## Contribution point

  @impl Bee.Contributions.Point
  def key, do: :languages

  @impl Bee.Contributions.Point
  def normalize!(manifest, source, opts) do
    contributes = manifest["contributes"]

    languages =
      for l <- Map.get(contributes, "languages", []) do
        if first_line = l["firstLine"] do
          case Regex.compile(first_line) do
            {:ok, _} ->
              :ok

            {:error, {reason, _}} ->
              raise ArgumentError, "language #{l["id"]}: firstLine: #{reason}"
          end
        end

        %{
          id: l["id"],
          aliases: Map.get(l, "aliases", []),
          extensions: Map.get(l, "extensions", []),
          filenames: Map.get(l, "filenames", []),
          filename_patterns: Map.get(l, "filenamePatterns", []),
          first_line: l["firstLine"],
          configuration: l["configuration"] && configuration!(l, source, opts[:dir])
        }
      end

    grammars = for g <- Map.get(contributes, "grammars", []), do: grammar!(g, source, opts[:dir])

    if languages == [] and grammars == [],
      do: nil,
      else: %{languages: languages, grammars: grammars}
  end

  defp grammar!(%{"mode" => mode} = g, _source, _dir), do: %{language: g["language"], mode: mode}

  defp grammar!(%{"scopeName" => scope, "path" => rel} = g, source, dir) do
    {plugin, dir} =
      case {source, dir} do
        {{:plugin, name}, dir} when is_binary(dir) ->
          {name, Path.expand(dir)}

        _ ->
          raise ArgumentError, "grammar #{scope}: TextMate grammars can only come from a plugin"
      end

    path = Path.expand(rel, dir)

    cond do
      not String.starts_with?(path, dir <> "/") ->
        raise ArgumentError, "grammar #{scope}: path must be inside the plugin"

      not File.regular?(path) ->
        raise ArgumentError, "grammar #{scope}: no file #{rel}"

      true ->
        rel = Path.relative_to(path, dir)

        %{
          language: g["language"],
          scope: scope,
          path: path,
          plugin: plugin,
          url:
            "/plugins/#{URI.encode(plugin)}/#{rel |> String.split("/") |> Enum.map_join("/", &URI.encode/1)}",
          inject_to: Map.get(g, "injectTo", []),
          embedded_languages: Map.get(g, "embeddedLanguages", %{})
        }
    end
  end

  ## Language configuration

  defp configuration!(%{"id" => id, "configuration" => rel}, source, dir) do
    dir =
      case {source, dir} do
        {{:plugin, _}, dir} when is_binary(dir) -> Path.expand(dir)
        _ -> raise ArgumentError, "language #{id}: a configuration can only come from a plugin"
      end

    path = Path.expand(rel, dir)

    unless String.starts_with?(path, dir <> "/"),
      do: raise(ArgumentError, "language #{id}: configuration must be inside the plugin")

    with {:ok, text} <- File.read(path),
         {:ok, %{} = json} <- Bee.JSON.JSONC.decode(text) do
      normalize_configuration(json)
    else
      {:error, reason} when is_atom(reason) ->
        raise ArgumentError, "language #{id}: configuration #{rel}: #{:file.format_error(reason)}"

      _ ->
        raise ArgumentError, "language #{id}: configuration #{rel} is not a JSON object"
    end
  end

  # What the editor uses, in the file's keys; malformed parts are left out.
  defp normalize_configuration(json) do
    comments = json["comments"] || %{}

    %{
      "comments" =>
        %{
          "lineComment" => string(comments["lineComment"]),
          "blockComment" => pair(comments["blockComment"])
        }
        |> compact(),
      "brackets" =>
        json["brackets"] |> List.wrap() |> Enum.map(&pair/1) |> Enum.reject(&is_nil/1),
      "autoClosingPairs" => pairs(json["autoClosingPairs"]),
      "surroundingPairs" => pairs(json["surroundingPairs"]),
      "autoCloseBefore" => string(json["autoCloseBefore"]),
      "indentationRules" =>
        case json["indentationRules"] do
          %{} = rules ->
            for key <-
                  ~w(increaseIndentPattern decreaseIndentPattern indentNextLinePattern unIndentedLinePattern),
                regex = regex(rules[key]),
                into: %{},
                do: {key, regex}

          _ ->
            %{}
        end,
      "onEnterRules" =>
        for %{"beforeText" => before, "action" => %{} = action} = rule <-
              List.wrap(json["onEnterRules"]),
            before = regex(before),
            action["indent"] in ~w(none indent outdent indentOutdent) do
          %{
            "beforeText" => before,
            "afterText" => regex(rule["afterText"]),
            "previousLineText" => regex(rule["previousLineText"]),
            "action" =>
              %{
                "indent" => action["indent"],
                "appendText" => string(action["appendText"]),
                "removeText" => if(is_integer(action["removeText"]), do: action["removeText"])
              }
              |> compact()
          }
          |> compact()
        end,
      "folding" =>
        case json["folding"] do
          %{} = folding ->
            %{
              "offSide" => if(folding["offSide"] == true, do: true),
              "markers" => markers(folding["markers"])
            }
            |> compact()

          _ ->
            %{}
        end
    }
    |> compact()
  end

  defp markers(%{"start" => start, "end" => stop}) do
    with %{} = start <- regex(start),
         %{} = stop <- regex(stop),
         do: %{"start" => start, "end" => stop}
  end

  defp markers(_other), do: nil

  defp pairs(list) do
    for item <- List.wrap(list),
        p =
          (case item do
             %{"open" => open, "close" => close} -> pair([open, close])
             list -> pair(list)
           end),
        do: %{"open" => hd(p), "close" => List.last(p)} |> Map.merge(not_in(item))
  end

  defp not_in(%{"notIn" => list}) when is_list(list),
    do: %{"notIn" => Enum.filter(list, &is_binary/1)}

  defp not_in(_item), do: %{}

  defp pair([open, close])
       when is_binary(open) and is_binary(close) and open != "" and close != "",
       do: [open, close]

  defp pair(_other), do: nil

  defp string(s) when is_binary(s) and s != "", do: s
  defp string(_s), do: nil

  # VS Code's regexes: "source", or {"pattern": "source", "flags": "i"}.
  defp regex(source) when is_binary(source) and source != "",
    do: %{"pattern" => source, "flags" => ""}

  defp regex(%{"pattern" => source} = r) when is_binary(source) and source != "",
    do: %{"pattern" => source, "flags" => if(is_binary(r["flags"]), do: r["flags"], else: "")}

  defp regex(_other), do: nil

  defp compact(map), do: Map.reject(map, fn {_k, v} -> v in [nil, [], %{}] end)
end

defmodule Bee.Snippets do
  @moduledoc """
  Snippets, like VS Code's: a `Bee.Contributions.Point` for the `snippets`
  section of plugins' manifests (and extensions installed from a VSIX):

      "snippets": [{"language": "elixir", "path": "./snippets/elixir.json"}]

  A snippets file (JSON with comments, VS Code's format) maps names to
  snippets:

      {"Define a function": {"prefix": ["def"], "body": ["def ${1:name} do", "\\t$0", "end"],
                             "description": "A function"}}

  `body` (lines) uses TextMate's snippet syntax (`$1`, `${1:default}`,
  `${1|one,two|}`, `$0`, variables like `$TM_FILENAME`), turned into an
  editor snippet in the browser (`assets/js/editor/snippets.js`). A file
  without a `language` holds snippets for every language, or those a
  snippet's `scope` lists (`"scope": "javascript,typescript"`).
  """
  @behaviour Bee.Contributions.Point

  alias Bee.Contributions

  @type snippet :: %{
          name: String.t(),
          prefixes: [String.t()],
          body: String.t(),
          description: String.t() | nil,
          languages: [String.t()] | :all
        }

  @doc "The snippets for language `id`, in contribution order."
  @spec for_language(String.t()) :: [snippet]
  def for_language(id) do
    for {_source, files} <- Contributions.entries(:snippets),
        file <- files,
        snippet <- file.snippets,
        snippet.languages == :all or id in snippet.languages,
        do: snippet
  end

  @doc "For the editor: `[%{name, prefix, body, description}]` of language `id`."
  def editor_snippets(id) do
    for s <- for_language(id),
        do: %{name: s.name, prefix: s.prefixes, body: s.body, description: s.description}
  end

  ## Contribution point

  @impl Contributions.Point
  def key, do: :snippets

  @impl Contributions.Point
  def normalize!(manifest, source, opts) do
    case get_in(manifest, ["contributes", "snippets"]) do
      list when list in [nil, []] ->
        nil

      list ->
        dir =
          case {source, opts[:dir]} do
            {{:plugin, _}, dir} when is_binary(dir) -> Path.expand(dir)
            _ -> raise ArgumentError, "snippets can only come from a plugin"
          end

        for entry <- list, do: file!(entry, dir)
    end
  end

  defp file!(%{"path" => rel} = entry, dir) do
    path = Path.expand(rel, dir)

    unless String.starts_with?(path, dir <> "/"),
      do: raise(ArgumentError, "snippets #{rel}: must be inside the plugin")

    json =
      with {:ok, text} <- File.read(path),
           {:ok, %{} = json} <- Bee.JSON.JSONC.decode(text) do
        json
      else
        {:error, reason} when is_atom(reason) ->
          raise ArgumentError, "snippets #{rel}: #{:file.format_error(reason)}"

        _ ->
          raise ArgumentError, "snippets #{rel}: not a JSON object"
      end

    language = entry["language"]

    %{
      language: language,
      path: path,
      rel: rel,
      snippets:
        for(
          {name, %{"body" => body} = s} <- Enum.sort(json),
          body = body(body),
          do: %{
            name: name,
            prefixes: strings(s["prefix"]),
            body: body,
            description: if(is_binary(s["description"]), do: s["description"]),
            languages: languages(language, s["scope"])
          }
        )
    }
  end

  defp body(lines) when is_list(lines) do
    if Enum.all?(lines, &is_binary/1), do: Enum.join(lines, "\n")
  end

  defp body(text) when is_binary(text), do: text
  defp body(_other), do: nil

  defp strings(s) when is_binary(s) and s != "", do: [s]
  defp strings(list) when is_list(list), do: Enum.filter(list, &(is_binary(&1) and &1 != ""))
  defp strings(_other), do: []

  # The file's language, else the snippet's scope ("a,b"), else all.
  defp languages(language, _scope) when is_binary(language), do: [language]

  defp languages(nil, scope) when is_binary(scope) do
    case scope |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> :all
      ids -> ids
    end
  end

  defp languages(nil, _scope), do: :all
end

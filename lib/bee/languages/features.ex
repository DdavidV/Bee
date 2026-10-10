defmodule Bee.Languages.Features do
  @moduledoc """
  The language features extensions give the editor (VS Code's
  `languages.register*Provider`): completion, hover, where a symbol is
  defined. The providers live in the workspace's extension host
  (`Bee.Extensions.Host`, `priv/extension_host/features.js`); this is the
  way to them.

  A request is answered later, to the process that asked:

      Bee.Languages.Features.request(root, "hover", path, %{position: %{line: 3, character: 7}}, {self(), ref})
      # => {:language_reply, ref, {:ok, result} | {:error, message}}

  The file is an open one (`Bee.Editor.Buffer`), and its providers are
  asked about the text the buffer has. Positions are `%{line, character}`,
  zero-based, characters in UTF-16 units – as the browser's editor and the
  extensions both count, so they pass through unconverted. With no
  extension host the answer is `{:ok, nil}`. `cancel/2` gives up on a
  request: its answer is `{:ok, nil}`.

  Features and their results (JSON, string keys):

    * `"completion"` (`position`, `context`) – `%{"session", "incomplete", "items"}`
    * `"completionResolve"`, `"completionAccept"` (`session`, `index`) – an
      item's details; runs the command of the one that was inserted
    * `"hover"` (`position`) – `%{"contents" => [markdown], "range"}`
    * `"definition"`, `"typeDefinition"`, `"declaration"`,
      `"implementation"` (`position`) – `[%{"path", "from", "to"}]`
    * `"formatting"` (`options`, `formatter`), `"rangeFormatting"` (and
      `range`) – `%{"edits" => [%{"from", "to", "text"}], "extension"}` of
      one formatter: the one named (an extension's id), else the best fit
    * `"signatureHelp"` (`position`, `context`) – `%{"signatures",
      "activeSignature", "activeParameter"}`
    * `"references"` (`position`) – places, like `"definition"`;
      `"documentHighlight"` (`position`) – `[%{"from", "to", "kind"}]`
    * `"documentSymbol"` – the file's outline, flat: `[%{"name", "detail",
      "kind", "container", "depth", "from", "to"}]`; `"workspaceSymbol"`
      (`query`; not about a file: `path` is `nil`) – `[%{"name", "kind",
      "container", "path", "from", "to"}]`
    * `"codeAction"` (`range`, `context`) – `%{"session", "actions" =>
      [%{"index", "title", "kind", "preferred", "disabled"}]}`;
      `"codeActionApply"` (`session`, `index`) – does one: `%{"applied"}`
      or `%{"error"}`
    * `"prepareRename"` (`position`) – `%{"placeholder", "from", "to"}`
      or `%{"error"}`; `"rename"` (`position`, `newName`) – the edits are
      applied (open files in their buffers, others on disk):
      `%{"applied", "files", "edits"}` or `%{"error"}`

  Which features exist for which files is known here (`for_file/2`), as
  the host says what its extensions registered (`put/2`); a change
  broadcasts `:language_features_changed` on the workspace's topic
  (`subscribe/1`), so that an editor only asks when there is someone to
  answer.
  """

  alias Bee.Extensions.Host

  @table __MODULE__
  @features ~w(completion completionResolve completionAccept hover
               definition typeDefinition declaration implementation
               formatting rangeFormatting signatureHelp
               references documentHighlight documentSymbol workspaceSymbol
               prepareRename rename codeAction codeActionApply)

  @doc "The features that can be asked for."
  def features, do: @features

  @doc "The table of the providers extensions registered: `{root, [provider]}`."
  def create_table do
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public, read_concurrency: true])

    :ok
  end

  @doc "Changes of what there is in workspace `root`: `:language_features_changed`."
  def subscribe(root), do: Phoenix.PubSub.subscribe(Bee.PubSub, topic(root))

  defp topic(root), do: "language_features:" <> root

  @doc """
  The providers of workspace `root`'s extensions, as its host names them:
  `%{"feature", "extension", "selector" => [%{"language", "scheme",
  "pattern"}], "triggerCharacters"}`.
  """
  def put(root, providers) when is_list(providers) do
    if providers(root) != providers do
      if providers == [],
        do: :ets.delete(@table, root),
        else: :ets.insert(@table, {root, providers})

      Phoenix.PubSub.broadcast(Bee.PubSub, topic(root), :language_features_changed)
    end

    :ok
  end

  def providers(root) do
    case :ets.lookup(@table, root) do
      [{_, providers}] -> providers
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  The features there are for file `path` of workspace `root`, with the
  characters that ask for them when typed:
  `%{"completion" => %{triggerCharacters: ["."]}, "hover" => %{triggerCharacters: []}}`.
  """
  def for_file(root, path) do
    language = Bee.Languages.detect(path)
    relative = Path.relative_to(path, root)

    for %{"feature" => feature} = provider <- providers(root),
        # (Not a file's: see any?/2.)
        feature != "workspaceSymbol",
        Enum.any?(List.wrap(provider["selector"]), &selects?(&1, language, path, relative)),
        reduce: %{} do
      acc ->
        characters = Enum.filter(List.wrap(provider["triggerCharacters"]), &is_binary/1)

        Map.update(
          acc,
          feature,
          %{triggerCharacters: characters},
          &%{&1 | triggerCharacters: Enum.uniq(&1.triggerCharacters ++ characters)}
        )
    end
  end

  # The host decides for good when it is asked (a pattern may be relative
  # to a folder we aren't told): here a pattern we can't tell selects.
  @doc "Whether an extension of workspace `root` provides `feature` at all (for any file)."
  def any?(root, feature), do: Enum.any?(providers(root), &(&1["feature"] == feature))

  defp selects?(%{} = selector, language, path, relative) do
    language? = selector["language"] in [nil, "*", language]
    scheme? = selector["scheme"] in [nil, "*", "file"]

    pattern? =
      case selector["pattern"] do
        nil -> true
        pattern when is_binary(pattern) -> glob?(pattern, relative) or glob?(pattern, path)
        _ -> true
      end

    any? = Enum.any?(~w(language scheme pattern), &selector[&1])
    any? and language? and scheme? and pattern?
  end

  defp selects?(_other, _language, _path, _relative), do: false

  defp glob?(pattern, path) do
    Bee.Workspace.Glob.match?(pattern, path)
  rescue
    _ -> true
  end

  @doc """
  Asks workspace `root`'s extensions for `feature` in the open file `path`;
  `{pid, ref}` gets `{:language_reply, ref, {:ok, result} | {:error, message}}`.
  """
  def request(root, feature, path, params, {pid, ref} = reply_to)
      when feature in @features and (is_binary(path) or is_nil(path)) and is_map(params) and
             is_pid(pid) do
    case Host.whereis(root) do
      nil -> send(pid, {:language_reply, ref, {:ok, nil}})
      host -> GenServer.cast(host, {:provide, feature, path, params, reply_to})
    end

    :ok
  end

  @doc "Gives up on the request answered by `ref`."
  def cancel(root, ref) do
    with host when is_pid(host) <- Host.whereis(root),
         do: GenServer.cast(host, {:cancel_provide, ref})

    :ok
  end
end

defmodule Bee.CustomEditors do
  @moduledoc """
  Editors for files that aren't shown as text, like VS Code's custom
  editors: a `Bee.Contributions.Point` for the `customEditors` section of
  a manifest, which says what files an editor is for:

      "customEditors": [
        {"viewType": "imagePreview.previewEditor", "displayName": "Image Preview",
         "priority": "builtin", "selector": [{"filenamePattern": "*.{png,jpg}"}]}
      ]

  `filenamePattern` is a glob matched against a file's name, or – with a
  `/` – against the end of its path, whatever its case. `priority` is
  VS Code's: `default` (the editor a matching file opens in), `builtin`
  (the same, unless another one is the `default`) or `option` (not used
  unless asked for).

  Bee has editors of its own (`viewer/1`): VS Code's previews of images,
  audio and video, by their `viewType`s there. Bee's own manifest
  (`priv/contributions/media-preview.json`) names their files; a plugin
  adds files to them with an entry of the same `viewType`.

  A plugin's own editor is an entry with a `viewType` of its own and the
  LiveView that draws a file (`live`, a `Bee.Plugin.LiveView` of its, as
  for its views):

      {"viewType": "hexView.editor", "displayName": "Hex Viewer", "live": "HexView.EditorLive",
       "priority": "option", "selector": [{"filenamePattern": "*"}]}

  The LiveView is shown in the file's tab, with the file's path as
  `@bee.params["path"]` (`live_editor/1`). Other entries with that
  `viewType` – the plugin's, or another one's – add files to it.

  A VS Code extension's editor is an entry of its package.json, as it is
  there: its code draws the file in a webview once it registered a
  provider for the `viewType` (`window.registerCustomEditorProvider`, see
  `extension_editor/1` and `Bee.Webviews`).

  An entry for a `viewType` nobody draws opens nothing: its files are
  shown as they would be without it.

  The user decides otherwise with the `workbench.editorAssociations`
  setting (`for_file/2`), which Open With… writes.
  """
  @behaviour Bee.Contributions.Point

  alias Bee.Contributions
  alias Bee.Workspace.Glob

  # The editors Bee has, by VS Code's ids for them (its media-preview
  # extension's): what `BeeWeb.Workbench.MediaPreview` shows a file as.
  @viewers %{
    "imagePreview.previewEditor" => :image,
    "vscode.audioPreview" => :audio,
    "vscode.videoPreview" => :video
  }

  @type editor :: %{
          view_type: String.t(),
          display_name: String.t(),
          priority: :default | :builtin | :option,
          patterns: [String.t()],
          live: String.t() | nil,
          extension?: boolean(),
          source: Bee.Contributions.Point.source()
        }

  @doc "How Bee shows a file in the editor `view_type`: `:image`, `:audio`, `:video` – or nil."
  def viewer(view_type), do: @viewers[view_type]

  @doc """
  The plugin's LiveView that draws files in the editor `view_type`:
  `%{plugin, live, view_type}` (`live` the module's name) – or nil.
  """
  def live_editor(view_type) do
    Enum.find_value(all(), fn
      %{view_type: ^view_type, live: live, source: {:plugin, plugin}} when is_binary(live) ->
        %{plugin: plugin, live: live, view_type: view_type}

      _ ->
        nil
    end)
  end

  @doc "The editors plugins draw: `[%{plugin, live, view_type}]`."
  def live_editors do
    for %{live: live, view_type: view_type} <- all(), is_binary(live), uniq: true do
      live_editor(view_type)
    end
  end

  @doc """
  The extension whose code draws files in the editor `view_type`, in a
  webview: `%{plugin, view_type}` – or nil.
  """
  def extension_editor(view_type) do
    Enum.find_value(all(), fn
      %{view_type: ^view_type, extension?: true, source: {:plugin, plugin}} ->
        if viewer(view_type) == nil and live_editor(view_type) == nil,
          do: %{plugin: plugin, view_type: view_type}

      _ ->
        nil
    end)
  end

  @doc "Whether there is an editor `view_type` to show a file in: Bee's, a plugin's, an extension's."
  def available?(view_type),
    do:
      viewer(view_type) != nil or live_editor(view_type) != nil or
        extension_editor(view_type) != nil

  @doc "Every editor contributed, in contribution order."
  @spec all() :: [editor]
  def all do
    for {_source, editors} <- Contributions.entries(:custom_editors),
        editor <- editors,
        do: editor
  end

  # The text editor's id among them, as in VS Code.
  @text "default"

  @doc "The id of the text editor: what `workbench.editorAssociations` and Open With… call it."
  def text, do: @text

  @doc """
  The editor (its `viewType`) the file at `path` opens in instead of the
  text editor, or nil.

  `associations` – the `workbench.editorAssociations` setting, glob → id –
  decide first: the text editor (`"default"`), or an editor Bee has. Else
  it is the one for the file's name that Bee can show – a `default` one
  rather than a `builtin` one, the last contributed of them.
  """
  def for_file(path, associations \\ %{}) do
    case associated(path, associations) do
      @text -> nil
      view_type when is_binary(view_type) -> view_type
      nil -> contributed(path)
    end
  end

  defp associated(path, %{} = associations) do
    Enum.find_value(associations, fn {pattern, id} ->
      (is_binary(id) and (id == @text or available?(id)) and
         glob?(String.downcase(pattern), path)) && id
    end)
  end

  defp associated(_path, _other), do: nil

  defp contributed(path) do
    candidates = for editor <- matching(path), editor.priority != :option, do: editor

    case Enum.reverse(candidates) do
      [] -> nil
      found -> (Enum.find(found, &(&1.priority == :default)) || hd(found)).view_type
    end
  end

  # The editors for the file's name that there are (Bee's, plugins').
  defp matching(path) do
    for editor <- all(),
        available?(editor.view_type),
        Enum.any?(editor.patterns, &glob?(&1, path)),
        do: editor
  end

  @doc """
  The editors the file at `path` can be opened with (Open With…):
  `[%{id, label}]`, the text editor first (`id` `"default"`), then the
  ones for its name.
  """
  def choices(path) do
    others =
      path
      |> matching()
      |> Enum.uniq_by(& &1.view_type)
      |> Enum.map(&%{id: &1.view_type, label: display_name(&1.view_type)})

    [%{id: @text, label: "Text Editor"} | others]
  end

  @doc "The pattern for files like the one at `path`: `*.svg`, or its name without an extension."
  def pattern(path) do
    case Path.extname(path) do
      "" -> Path.basename(path)
      ext -> "*" <> ext
    end
  end

  @doc "The name of the editor `view_type` (\"Image Preview\"), or nil."
  def display_name(view_type) do
    Enum.find_value(all(), &(&1.view_type == view_type && &1.display_name)) ||
      if(Enum.any?(all(), &(&1.view_type == view_type)), do: view_type)
  end

  defp glob?(pattern, path) do
    if String.contains?(pattern, "/"),
      do: Glob.match?("**/" <> String.trim_leading(pattern, "/"), String.downcase(path)),
      else: Glob.match?(pattern, String.downcase(Path.basename(path)))
  end

  ## Contribution point

  @impl Contributions.Point
  def key, do: :custom_editors

  @impl Contributions.Point
  def normalize!(manifest, source, _opts) do
    case get_in(manifest, ["contributes", "customEditors"]) do
      list when list in [nil, []] ->
        nil

      list ->
        for %{"viewType" => view_type} = entry <- list do
          live = entry["live"]

          cond do
            live == nil ->
              :ok

            viewer(view_type) != nil ->
              raise ArgumentError, "customEditors: #{view_type} is Bee's own editor"

            # Its module is the plugin's, loaded with its server part.
            not (match?({:plugin, _}, source) and manifest["server"] != nil) ->
              raise ArgumentError, "a LiveView (\"live\") needs a plugin with a \"server\" part"

            true ->
              :ok
          end

          %{
            view_type: view_type,
            display_name: entry["displayName"],
            priority: priority(entry["priority"]),
            patterns:
              for(
                %{"filenamePattern" => pattern} <- entry["selector"],
                do: String.downcase(pattern)
              ),
            live: live,
            # Its source has a VS Code extension's code, which may draw it.
            extension?: live == nil and is_map(manifest["extension"]),
            source: source
          }
        end
    end
  end

  # (`others`: the editors of every other source.)
  @impl Contributions.Point
  def conflicts(editors, others) do
    drawn = MapSet.new(for %{live: live} = e <- others, live != nil, do: e.view_type)

    for %{live: live, view_type: view_type} <- editors,
        live != nil and view_type in drawn,
        uniq: true,
        do: "custom editor #{inspect(view_type)} is already defined"
  end

  defp priority("builtin"), do: :builtin
  defp priority("option"), do: :option
  defp priority(_default), do: :default
end

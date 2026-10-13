defmodule BeeWeb.Workbench.EditorArea do
  @moduledoc """
  The editor area: the editor groups – one, or the area split in rows and
  columns – each with its tabs and what its active one shows: a file in
  the group's pane (CodeMirror's, the `CodeEditor` hook), or another kind
  of editor (a file that isn't text: an image, a binary file; a plugin's
  details, the settings, a plugin's LiveView, a webview panel).
  """

  use BeeWeb, :html

  alias Bee.Workbench

  # `when` keys of a tab's right-click menu (editor/title/context).
  def tab_menu_context(tab, group \\ nil)

  def tab_menu_context(%{kind: kind, path: path} = tab, group)
      when kind in [:file, :media, :binary] do
    %{
      # (A right-click acts on the tab's group: it is focused first.)
      "editorGroup" => group,
      "resourceScheme" => "file",
      "resourcePath" => path,
      "resourceFilename" => Path.basename(path),
      "resourceExtname" => Path.extname(path),
      # (VS Code's name for it: Keep Open is offered for previews.)
      "activeEditorIsNotPreview" => not Workbench.preview?(tab),
      "activeCustomEditorId" => Map.get(tab, :view_type),
      "activeEditorIsBinary" => kind == :binary
    }
  end

  def tab_menu_context(_tab, group) do
    %{
      "editorGroup" => group,
      "resourceScheme" => "extension",
      "activeEditorIsNotPreview" => true
    }
  end

  attr :node, :any, required: true, doc: "a node of the workbench's layout"
  attr :groups, :map, required: true, doc: "the groups by id: `%{id => %{id, tabs, active}}`"
  attr :focused, :integer, required: true, doc: "the focused group's id"
  attr :actions, :list, required: true, doc: "the editor/title buttons (the focused group's)"
  attr :root, :string, required: true
  attr :icon_theme, :any, required: true
  attr :file_decorations, :map, required: true
  attr :extension_details, :map, required: true
  attr :marketplace_installed, :map, required: true
  attr :installing, :any, required: true, doc: "the Open VSX extensions being installed"
  attr :settings, :map, required: true
  attr :plugins, :list, required: true
  attr :socket, :any, required: true, doc: "the window's socket, for plugins' LiveViews"
  attr :live, :map, required: true
  attr :webviews, :map, required: true
  attr :diffs, :map, default: %{}, doc: "the diffs of extensions in tabs: id => what differs"
  attr :color_theme_id, :string, required: true
  attr :webview_origin, :any, required: true
  attr :keybinding_labels, :map, required: true

  # A group, or groups side by side (a row) or one above the other (a column).
  def editor_node(%{node: {:leaf, id}} = assigns) do
    assigns = assign(assigns, :group, assigns.groups[id])

    ~H"""
    <.editor_group
      group={@group}
      focused={@group.id == @focused}
      actions={@actions}
      root={@root}
      icon_theme={@icon_theme}
      file_decorations={@file_decorations}
      extension_details={@extension_details}
      marketplace_installed={@marketplace_installed}
      installing={@installing}
      settings={@settings}
      plugins={@plugins}
      socket={@socket}
      live={@live}
      webviews={@webviews}
      diffs={@diffs}
      color_theme_id={@color_theme_id}
      webview_origin={@webview_origin}
      keybinding_labels={@keybinding_labels}
    />
    """
  end

  def editor_node(%{node: {axis, nodes}} = assigns) do
    assigns = assign(assigns, axis: axis, nodes: nodes)

    ~H"""
    <div
      data-split={@axis}
      class={["editor-split flex flex-1 min-w-0 min-h-0", @axis == :col && "flex-col"]}
    >
      <.editor_node
        :for={node <- @nodes}
        node={node}
        groups={@groups}
        focused={@focused}
        actions={@actions}
        root={@root}
        icon_theme={@icon_theme}
        file_decorations={@file_decorations}
        extension_details={@extension_details}
        marketplace_installed={@marketplace_installed}
        installing={@installing}
        settings={@settings}
        plugins={@plugins}
        socket={@socket}
        live={@live}
        webviews={@webviews}
        diffs={@diffs}
        color_theme_id={@color_theme_id}
        webview_origin={@webview_origin}
        keybinding_labels={@keybinding_labels}
      />
    </div>
    """
  end

  # One group: its tabs, and what its active one shows – a file in the
  # group's pane (CodeMirror's, the CodeEditor hook), or another kind of editor.
  defp editor_group(assigns) do
    assigns =
      assign(assigns,
        tabs: Enum.map(assigns.group.tabs, &tab_row(&1, assigns)),
        file:
          Enum.find_value(assigns.group.tabs, fn tab ->
            (tab.kind == :file and tab.path == assigns.group.active) && tab.path
          end)
      )

    ~H"""
    <section
      id={"group-#{@group.id}"}
      data-group={@group.id}
      data-focused={to_string(@focused)}
      class="editor-group flex-1 min-w-0 min-h-0 flex flex-col relative"
    >
      <div class="flex bg-tabs shrink-0">
        <%!-- Tabs: dragged to reorder, or to another group; middle-clicked to
             close (the Tabs hook); right-clicked for the editor/title/context menu. --%>
        <div
          id={"tabs-#{@group.id}"}
          data-tabs
          data-group={@group.id}
          phx-hook="Tabs"
          class="flex flex-1 min-w-0 overflow-x-auto text-sm"
        >
          <div
            :for={tab <- @tabs}
            id={tab.id}
            data-tab
            data-path={tab.path}
            data-active={to_string(tab.active)}
            data-dirty={tab.dirty && "true"}
            data-preview={tab.preview && "true"}
            data-keep={tab.path}
            data-menu="editor/title/context"
            data-menu-args={tab.menu_args}
            data-menu-context={tab.menu_context}
            class={[
              "group flex items-center gap-1 pl-3 pr-1 py-1.5 border-r border-tab-border cursor-pointer whitespace-nowrap",
              if(tab.active,
                do: "bg-tab-active text-tab-active-fg",
                else:
                  "bg-tab-inactive text-tab-inactive-fg hover:text-tab-active-fg hover:bg-base-content/5"
              ),
              tab.dimmed && "opacity-70"
            ]}
            phx-click="activate_tab"
            phx-value-path={tab.path}
            phx-value-group={tab.group}
            title={tab.title}
          >
            <BeeWeb.Workbench.FileIcon.file_icon
              :if={@icon_theme && tab.file}
              theme={@icon_theme}
              path={tab.path}
              language={tab.lang}
            />
            <.icon
              :if={tab.kind == :extension}
              name="hero-puzzle-piece"
              class="size-4 shrink-0 opacity-70"
            />
            <.icon
              :if={tab.kind == :settings}
              name="hero-cog-6-tooth"
              class="size-4 shrink-0 opacity-70"
            />
            <.icon
              :if={tab.kind in [:live, :webview]}
              name="hero-window"
              class="size-4 shrink-0 opacity-70"
            />
            <.icon
              :if={tab.kind == :diff}
              name="hero-arrows-right-left"
              class="size-4 shrink-0 opacity-70"
            />
            <span class={[tab.color, tab.italic && "italic"]}>
              {tab.label}
            </span>
            <button
              class="size-5 grid place-items-center rounded cursor-pointer hover:bg-base-content/10"
              title="Close"
              data-close
              phx-click="run_command"
              phx-value-command="workbench.action.closeEditor"
              phx-value-args={tab.close_args}
            >
              <span :if={tab.dirty} class="size-2 rounded-full bg-current group-hover:hidden" />
              <.icon
                name="hero-x-mark-mini"
                class={["size-4", tab.dirty && "hidden group-hover:block"]}
              />
            </button>
          </div>
        </div>
        <%!-- Editor actions: the "editor/title" menu (undo/redo, plugins'
             buttons), for the focused group's editor. --%>
        <BeeWeb.Workbench.Toolbar.toolbar
          :if={@focused}
          id="editor-actions"
          actions={@actions}
          class="px-1"
        />
      </div>

      <%!-- Right-clicking a file's text: the editor/context menu. --%>
      <div
        id={"editor-area-#{@group.id}"}
        class="flex-1 min-h-0 relative"
        data-editor-area
        data-menu={@file && "editor/context"}
        data-menu-args={Jason.encode!(List.wrap(@file))}
        data-menu-context={Jason.encode!(%{"editorGroup" => @group.id})}
      >
        <div
          id={"editor-pane-#{@group.id}"}
          phx-update="ignore"
          data-editor-pane={@group.id}
          class="absolute inset-0"
        >
        </div>
        <%!-- A plugin's details, over the (emptied) editor --%>
        <div
          :for={tab <- @group.tabs}
          :if={tab.kind == :extension and tab.path == @group.active}
          class="absolute inset-0"
        >
          <BeeWeb.Workbench.ExtensionEditor.extension_editor
            name={tab.name}
            details={@extension_details[tab.name]}
            installed={@marketplace_installed}
            installing={@installing}
          />
        </div>
        <%!-- The settings page --%>
        <div
          :for={tab <- @group.tabs}
          :if={tab.kind == :settings and tab.path == @group.active}
          class="absolute inset-0"
        >
          <.live_component
            module={BeeWeb.Workbench.SettingsEditor}
            id="settings-editor"
            scope={tab.scope}
            search={tab[:search]}
            root={@root}
            settings={@settings}
            plugins={@plugins}
          />
        </div>
        <%!-- Editors plugins draw themselves (LiveViews): each stays mounted
             while its tab is open, shown when it is the active one. --%>
        <div
          :for={tab <- @group.tabs}
          :if={tab.kind == :live}
          id={"live-editor-#{:erlang.phash2(tab.path)}"}
          data-live-editor={tab.editor}
          class={[
            "absolute inset-0 overflow-auto bg-editor text-editor-fg",
            tab.path != @group.active && "hidden"
          ]}
        >
          <BeeWeb.Workbench.PluginLive.plugin_live
            socket={@socket}
            state={@live[{:editor, tab.editor}]}
            kind="editor"
            id={tab.editor}
            key={tab.key}
            root={@root}
            params={tab.params}
          />
        </div>
        <%!-- Webview panels of extensions: each frame stays while its tab is open. --%>
        <BeeWeb.Workbench.Webview.webview
          :for={tab <- @group.tabs}
          :if={tab.kind == :webview and @webviews[tab.webview]}
          panel={@webviews[tab.webview]}
          theme={@color_theme_id}
          active={tab.path == @group.active}
          origin={@webview_origin}
        />
        <%!-- Files that aren't shown as text: an image, audio or video (each
             stays while its tab is open: its zoom, where it plays), or a
             note that the file is binary. --%>
        <BeeWeb.Workbench.MediaPreview.media_preview
          :for={tab <- @group.tabs}
          :if={tab.kind == :media}
          tab={tab}
          group={@group.id}
          active={tab.path == @group.active}
          focused={@focused}
        />
        <BeeWeb.Workbench.BinaryEditor.binary_editor
          :for={tab <- @group.tabs}
          :if={tab.kind == :binary and tab.path == @group.active}
          tab={tab}
          group={@group.id}
          limit={@settings["workbench.editorLargeFileConfirmation"]}
        />
        <%!-- Documents an extension compares (vscode.diff). --%>
        <BeeWeb.Workbench.DiffView.diff_view
          :for={tab <- @group.tabs}
          :if={tab.kind == :diff and @diffs[tab.diff]}
          diff={@diffs[tab.diff]}
          active={tab.path == @group.active}
        />
        <div
          :if={@group.tabs == []}
          class="absolute inset-0 grid place-items-center bg-editor text-editor-fg text-sm"
        >
          <div class="text-center space-y-1 opacity-40">
            <BeeWeb.Logo.logo class="size-12 mx-auto mb-2" />
            <div>Open a file from the explorer</div>
            <div :for={
              {label, command} <- [
                {"Show All Commands", "workbench.action.showCommands"},
                {"Go to File", "workbench.action.quickOpen"},
                {"Toggle Terminal", "workbench.action.togglePanel"},
                {"Open Settings", "workbench.action.openSettingsJson"}
              ]
            }>
              {label}
              <kbd
                :if={key = @keybinding_labels[command]}
                class="kbd kbd-xs ml-1"
              >
                {key}
              </kbd>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # What a tab of the group shows, all of it: a tab is drawn from this
  # alone, so LiveView sends a tab again only when it changed itself –
  # typing into a file is one tab's dot, not every tab's attributes.
  defp tab_row(tab, %{group: group} = assigns) do
    active = tab.path == group.active
    preview = Workbench.preview?(tab)

    %{
      id: "tab-#{group.id}-#{:erlang.phash2(tab.path)}",
      group: group.id,
      path: tab.path,
      kind: tab.kind,
      file: Workbench.file?(tab),
      lang: tab.lang,
      active: active,
      dimmed: active and not assigns.focused,
      dirty: tab.dirty,
      preview: preview,
      italic: tab.kind == :extension or preview,
      label: tab_label(tab, assigns.extension_details),
      title:
        if(Workbench.file?(tab),
          do: Bee.Workspace.FS.relative(assigns.root, tab.path),
          else: tab_label(tab, assigns.extension_details)
        ),
      color: Workbench.file?(tab) && tab_color(assigns.file_decorations, assigns.root, tab.path),
      menu_args: Jason.encode!([tab.path]),
      menu_context: Jason.encode!(tab_menu_context(tab, group.id)),
      close_args: Jason.encode!([tab.path, group.id])
    }
  end

  # A tab's name: the file's, or "Extension: <plugin>".
  def tab_label(%{kind: kind, path: path}, _details) when kind in [:file, :media, :binary],
    do: Path.basename(path)

  def tab_label(%{kind: :settings}, _details), do: "Settings"
  def tab_label(%{kind: :live, title: title}, _details), do: title
  def tab_label(%{kind: :webview, title: title}, _details), do: title
  def tab_label(%{kind: :diff, title: title}, _details), do: title

  def tab_label(%{kind: :extension, name: name}, details),
    do: "Extension: " <> ((details[name] && details[name].display_name) || name)

  # Tabs are coloured like their file in the Explorer (git status…).
  defp tab_color(decorations, root, path) do
    case decorations[Bee.Workspace.FS.relative(root, path)] do
      nil -> nil
      decoration -> BeeWeb.Workbench.Decoration.color_class(decoration)
    end
  end
end

defmodule BeeWeb.Workbench.EditorArea do
  @moduledoc """
  The editor area: the editor groups – one, or the area split in rows and
  columns – each with its tabs and what its active one shows: a file in
  the group's pane (CodeMirror's, the `CodeEditor` hook), or another kind
  of editor (a plugin's details, the settings, a plugin's LiveView, a
  webview panel).
  """

  use BeeWeb, :html

  alias Bee.Workbench
  alias BeeWeb.EditorLive.{Menus, Window}

  # `when` keys of a tab's right-click menu (editor/title/context).
  def tab_menu_context(tab, group \\ nil)

  def tab_menu_context(%{kind: :file, path: path} = tab, group) do
    %{
      # (A right-click acts on the tab's group: it is focused first.)
      "editorGroup" => group,
      "resourceScheme" => "file",
      "resourcePath" => path,
      "resourceFilename" => Path.basename(path),
      "resourceExtname" => Path.extname(path),
      # (VS Code's name for it: Keep Open is offered for previews.)
      "activeEditorIsNotPreview" => not Workbench.preview?(tab)
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
  attr :a, :map, required: true, doc: "the window's assigns"

  # A group, or groups side by side (a row) or one above the other (a column).
  def editor_node(%{node: {:leaf, id}} = assigns) do
    assigns = assign(assigns, :group, Workbench.group(Window.workbench_from(assigns.a), id))

    ~H"""
    <.editor_group group={@group} a={@a} />
    """
  end

  def editor_node(%{node: {axis, nodes}} = assigns) do
    assigns = assign(assigns, axis: axis, nodes: nodes)

    ~H"""
    <div
      data-split={@axis}
      class={["editor-split flex flex-1 min-w-0 min-h-0", @axis == :col && "flex-col"]}
    >
      <.editor_node :for={node <- @nodes} node={node} a={@a} />
    </div>
    """
  end

  attr :group, :map, required: true, doc: "`%{id, tabs, active}`"
  attr :a, :map, required: true

  # One group: its tabs, and what its active one shows – a file in the
  # group's pane (CodeMirror's, the CodeEditor hook), or another kind of editor.
  defp editor_group(assigns) do
    assigns =
      assign(assigns,
        focused: assigns.group.id == assigns.a.group,
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
            :for={tab <- @group.tabs}
            id={"tab-#{@group.id}-#{:erlang.phash2(tab.path)}"}
            data-tab
            data-path={tab.path}
            data-active={to_string(tab.path == @group.active)}
            data-dirty={tab.dirty && "true"}
            data-preview={Workbench.preview?(tab) && "true"}
            data-keep={tab.path}
            data-menu="editor/title/context"
            data-menu-args={Jason.encode!([tab.path])}
            data-menu-context={Jason.encode!(tab_menu_context(tab, @group.id))}
            class={[
              "group flex items-center gap-1 pl-3 pr-1 py-1.5 border-r border-tab-border cursor-pointer whitespace-nowrap",
              if(tab.path == @group.active,
                do: "bg-tab-active text-tab-active-fg",
                else:
                  "bg-tab-inactive text-tab-inactive-fg hover:text-tab-active-fg hover:bg-base-content/5"
              ),
              (tab.path == @group.active and not @focused) && "opacity-70"
            ]}
            phx-click="activate_tab"
            phx-value-path={tab.path}
            phx-value-group={@group.id}
            title={
              if tab.kind == :file,
                do: Bee.Workspace.FS.relative(@a.root, tab.path),
                else: tab_label(tab, @a.extension_details)
            }
          >
            <BeeWeb.Workbench.FileIcon.file_icon
              :if={@a.icon_theme && tab.kind == :file}
              theme={@a.icon_theme}
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
            <span class={[
              tab.kind == :file && tab_color(@a.file_decorations, @a.root, tab.path),
              (tab.kind == :extension or Workbench.preview?(tab)) && "italic"
            ]}>
              {tab_label(tab, @a.extension_details)}
            </span>
            <button
              class="size-5 grid place-items-center rounded cursor-pointer hover:bg-base-content/10"
              title="Close"
              data-close
              phx-click="run_command"
              phx-value-command="workbench.action.closeEditor"
              phx-value-args={Jason.encode!([tab.path, @group.id])}
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
          actions={Menus.toolbar(@a, "editor/title")}
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
            details={@a.extension_details[tab.name]}
            installed={@a.marketplace_installed}
            installing={@a.marketplace.installing}
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
            root={@a.root}
            settings={@a.settings}
            plugins={@a.plugins}
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
            socket={@a.socket}
            state={@a.live[{:editor, tab.editor}]}
            kind="editor"
            id={tab.editor}
            key={tab.key}
            root={@a.root}
            params={tab.params}
          />
        </div>
        <%!-- Webview panels of extensions: each frame stays while its tab is open. --%>
        <BeeWeb.Workbench.Webview.webview
          :for={tab <- @group.tabs}
          :if={tab.kind == :webview and @a.webviews[tab.webview]}
          panel={@a.webviews[tab.webview]}
          theme={@a.color_theme.id}
          active={tab.path == @group.active}
          origin={@a.webview_origin}
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
                :if={key = Bee.Commands.Keybindings.label(command, @a.keybindings)}
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

  # A tab's name: the file's, or "Extension: <plugin>".
  def tab_label(%{kind: :file, path: path}, _details), do: Path.basename(path)

  def tab_label(%{kind: :settings}, _details), do: "Settings"
  def tab_label(%{kind: :live, title: title}, _details), do: title
  def tab_label(%{kind: :webview, title: title}, _details), do: title

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

defmodule BeeWeb.Workbench.Sidebar do
  @moduledoc """
  The activity bar and the sidebar, built from `Bee.Views` contributions.

  The activity bar has one button per views container (`show_view`), with
  the summed badges of its plugin views. Its icons can be dragged into
  another order (the `ActivityBar` hook, `reorder_activity`), and a
  right-click on one (`viewContainer/title/context`) hides it or – one that
  is movable, like References – moves it to the panel; "Show or Hide
  Views…" there brings a hidden one back (`Bee.Workbench`, "Views
  containers"). The sidebar shows the container's
  title, then its views: Bee's own (Explorer, Plugins) rendered by their
  components (Explorer, Search, References, Plugins, Open VSX – with its
  search box above the Plugins container's views), plugins' views by
  `BeeWeb.Workbench.ContributedView`. With a
  single view its `view/title` buttons sit in the container's header,
  otherwise each view gets a header of its own.

  The explorer's file tree stays mounted while another container is shown,
  so its expanded folders survive.
  """
  use BeeWeb, :html

  alias BeeWeb.Workbench.{
    ContributedView,
    MarketplaceView,
    PluginLive,
    PluginsView,
    ReferencesView,
    SearchView,
    Toolbar
  }

  @explorer "workbench.explorer.fileView"
  # Bee's Plugins views: the plugins of these scopes.
  @plugins %{
    "workbench.extensions.installed" => [:user, :workspace],
    "workbench.extensions.builtin" => [:builtin]
  }
  @search "workbench.view.search"
  @marketplace "workbench.extensions.marketplace"
  @references "workbench.panel.references"

  attr :containers, :list, required: true, doc: "with :badge"
  attr :sidebar_view, :string, required: true
  attr :sidebar_open, :boolean, required: true
  attr :keybinding_labels, :map, required: true

  def activity_bar(assigns) do
    ~H"""
    <aside
      id="activity-bar"
      phx-hook="ActivityBar"
      data-menu="viewContainer/title/context"
      class="bg-activitybar flex flex-col items-center gap-1 py-2"
    >
      <button
        :for={container <- @containers}
        id={"view-#{container.id}"}
        data-container={container.id}
        class={[
          "relative btn btn-ghost btn-square btn-sm",
          if(@sidebar_open && @sidebar_view == container.id,
            do: "btn-active text-activitybar-fg",
            else: "text-activitybar-inactive hover:text-activitybar-fg"
          )
        ]}
        title={title(container, @keybinding_labels)}
        aria-label={container.title}
        phx-click="show_view"
        phx-value-container={container.id}
        {container_menu(container, :activitybar)}
      >
        <BeeWeb.Icons.named_icon name={container.icon} class="size-5" />
        <span
          :if={container.badge}
          class="absolute -bottom-0.5 -right-0.5 min-w-4 h-4 px-1 rounded-full bg-badge text-badge-fg text-[10px] leading-4"
        >
          {container.badge}
        </span>
      </button>
      <%!-- Manage (VS Code's gear): the "globalActivity" menu, opened by a
           click (the ContextMenus hook: data-menu-click). --%>
      <div class="flex-1" />
      <button
        id="manage"
        type="button"
        class="btn btn-ghost btn-square btn-sm text-activitybar-inactive hover:text-activitybar-fg"
        title="Manage"
        aria-label="Manage"
        aria-haspopup="menu"
        data-menu="globalActivity"
        data-menu-click
      >
        <BeeWeb.Icons.named_icon name="cog-6-tooth" class="size-5" />
      </button>
    </aside>
    """
  end

  @doc """
  The attributes that give a container's icon (or its tab in the panel) its
  right-click menu, `viewContainer/title/context`: hide it, move it to the
  other place.
  """
  def container_menu(container, location) do
    %{
      "data-menu" => "viewContainer/title/context",
      "data-menu-args" => Jason.encode!([container.id]),
      "data-menu-context" =>
        Jason.encode!(%{
          "viewContainer" => container.id,
          "viewContainerLocation" => Atom.to_string(location),
          "viewContainerMovable" => Map.get(container, :movable, true)
        })
    }
  end

  # Bee's own containers have a show command with a keybinding.
  defp title(container, labels) do
    case labels["workbench.view.#{container.id}"] do
      nil -> container.title
      key -> "#{container.title} (#{key})"
    end
  end

  attr :container, :map, default: nil
  attr :views, :list, required: true, doc: "visible views: %{view, title_actions, item_actions}"
  attr :sidebar_open, :boolean, required: true
  attr :root, :string, required: true
  attr :active, :string, default: nil
  attr :plugins, :list, required: true
  attr :view_contents, :map, required: true
  attr :view_inputs, :map, required: true
  attr :collapsed, :any, required: true
  attr :collapsed_views, :any, required: true, doc: "MapSet of folded view ids"
  attr :view_sizes, :map, required: true, doc: "view id → height of its body in px"
  attr :search, :map, required: true
  attr :references, :map, default: nil, doc: "Find All References' places"
  attr :file_decorations, :map, required: true
  attr :icon_theme, :any, required: true
  attr :clipboard, :any, default: nil, doc: "the Explorer's cut or copied files"
  attr :socket, :any, required: true, doc: "the window's socket, for plugins' LiveViews"

  attr :live, :map,
    required: true,
    doc: "plugins' LiveViews (BeeWeb.EditorLive.Extensions.load_live/1)"

  attr :webview_views, :list,
    default: [],
    doc: "the pages of extensions' webview views here: [{panel, shown?}] (Bee.Webviews)"

  attr :webview_origin, :string, default: nil
  attr :color_theme_id, :string, default: nil
  attr :marketplace, :map, required: true, doc: "Bee.Workbench.Marketplace"
  attr :marketplace_installed, :map, required: true, doc: "Bee.Plugins.OpenVsx.installed/0"

  def sidebar(assigns) do
    assigns =
      assign(assigns,
        explorer_shown: Enum.any?(assigns.views, &(&1.view.id == @explorer)),
        single:
          match?([_], assigns.views) and not match?([%{view: %{webview: true}}], assigns.views),
        explorer_id: @explorer,
        plugin_views: Map.keys(@plugins),
        search_id: @search,
        marketplace_id: @marketplace,
        references_id: @references
      )

    assigns = assign(assigns, panes: panes(assigns))

    ~H"""
    <aside
      id="sidebar"
      class={[
        "bg-sidebar text-sidebar-fg overflow-hidden min-h-0 border-r border-sidebar-border flex flex-col",
        !@sidebar_open && "hidden"
      ]}
    >
      <div
        :if={@container}
        class="flex items-center h-8 shrink-0 pl-4 pr-2 text-xs uppercase tracking-wide"
      >
        <span id="sidebar-title" class="flex-1 truncate opacity-70">{@container.title}</span>
        <Toolbar.toolbar :if={@single} actions={hd(@views).title_actions} class="normal-case" />
      </div>

      <MarketplaceView.search_box
        :if={@container && @container.id == "extensions"}
        marketplace={@marketplace}
      />

      <div class={["flex-1 min-h-0 overflow-auto", !@explorer_shown && "hidden"]}>
        <.live_component
          module={BeeWeb.Workbench.FileTree}
          id="explorer"
          root={@root}
          active={@active && Bee.Workspace.FS.relative(@root, @active)}
          decorations={@file_decorations}
          icon_theme={@icon_theme}
          clipboard={@clipboard}
        />
      </div>

      <section
        :for={pane <- @panes}
        id={"view-#{pane.view.id}"}
        data-pane={pane.view.id}
        data-open={to_string(pane.open)}
        data-var={pane.var}
        class="view-pane relative flex flex-col min-h-7"
        style={"flex: var(#{pane.var}, #{pane.grow}) 1 #{if @single, do: "0px", else: "1.75rem"}"}
      >
        <div
          :if={pane.sash}
          id={"sash-view-#{pane.view.id}"}
          phx-hook="PaneSash"
          class="sash absolute inset-x-0 top-0 h-1 -translate-y-1/2 z-10 cursor-row-resize"
        >
        </div>
        <div
          :if={!@single}
          id={"view-header-#{pane.view.id}"}
          role="button"
          aria-expanded={to_string(pane.open)}
          class="flex items-center gap-0.5 h-7 shrink-0 pl-1 pr-2 text-xs font-semibold uppercase tracking-wide border-t border-sidebar-section-border cursor-pointer select-none"
          phx-click="toggle_view"
          phx-value-view={pane.view.id}
        >
          <.icon
            name="hero-chevron-right-mini"
            class={[
              "size-4 shrink-0 opacity-70 transition-transform duration-150",
              pane.open && "rotate-90"
            ]}
          />
          <span class="flex-1 truncate">{pane.view.name}</span>
          <span
            :if={pane[:count]}
            class="min-w-4 h-4 px-1 rounded-full bg-badge text-badge-fg text-[10px] leading-4 text-center font-normal"
          >
            {pane.count}
          </span>
          <Toolbar.toolbar :if={pane.open} actions={pane.title_actions} class="normal-case" />
        </div>
        <div class="flex-1 min-h-0 overflow-auto" inert={!pane.open}>
          <SearchView.search_view
            :if={pane.view.id == @search_id}
            search={@search}
            icon_theme={@icon_theme}
          />
          <ReferencesView.references_view
            :if={pane.view.id == @references_id}
            references={@references}
            root={@root}
            icon_theme={@icon_theme}
            collapsed={@collapsed}
          />
          <PluginsView.plugins_view
            :if={pane.view.id in @plugin_views}
            id={pane.view.id}
            plugins={plugins_in(@plugins, pane.view.id)}
            builtin={pane.view.id == "workbench.extensions.builtin"}
            user_dir={Bee.Plugins.user_dir()}
            item_actions={pane.item_actions}
          />
          <MarketplaceView.marketplace_view
            :if={pane.view.id == @marketplace_id}
            marketplace={@marketplace}
            installed={@marketplace_installed}
            item_actions={pane.item_actions}
          />
          <PluginLive.plugin_live
            :if={pane.view[:live]}
            socket={@socket}
            state={@live[{:view, pane.view.id}]}
            kind="view"
            id={pane.view.id}
            root={@root}
          />
          <ContributedView.contributed_view
            :if={
              !pane.view[:live] and
                pane.view.id not in [
                  @explorer_id,
                  @search_id,
                  @marketplace_id,
                  @references_id | @plugin_views
                ]
            }
            view={pane.view}
            content={@view_contents[pane.view.id]}
            input={Map.get(@view_inputs, pane.view.id, "")}
            collapsed={@collapsed}
            item_actions={pane.item_actions}
            icon_theme={@icon_theme}
          />
        </div>
      </section>

      <%!-- Webview views of extensions (pages of their own, Bee.Webviews): kept
           loaded while another container is shown, like VS Code's with
           retainContextWhenHidden. --%>
      <p
        :for={entry <- @views}
        :if={entry.view[:webview] && !Enum.any?(@webview_views, &(elem(&1, 0).view == entry.view.id))}
        class="px-4 py-2 text-xs opacity-60"
      >
        Starting {entry.view.name}…
      </p>
      <div
        :for={{panel, shown} <- @webview_views}
        id={"webview-view-#{panel.view}"}
        data-webview-view={panel.view}
        class={["relative flex-1 min-h-0", !shown && "hidden"]}
      >
        <BeeWeb.Workbench.Webview.webview
          panel={panel}
          theme={@color_theme_id}
          active
          origin={@webview_origin}
        />
      </div>
    </aside>
    """
  end

  # The views besides the explorer, each a pane: `flex-grow` is the height
  # of its body (the space past the headers is shared by these weights),
  # 0 when folded, so folding and resizing are animated by CSS. A view
  # never resized gets the average of the open ones that were. A sash sits
  # on top of an open pane with an open one somewhere above it; dragging
  # it sets `var` (on <html>) for the open panes (see PaneSash).
  defp panes(assigns) do
    # (Not the explorer, nor extensions' webview views: those are below the panes.)
    views = Enum.reject(assigns.views, &(&1.view.id == @explorer or &1.view[:webview]))
    open = &(assigns.single or not MapSet.member?(assigns.collapsed_views, &1.view.id))
    known = for e <- views, open.(e), size = assigns.view_sizes[e.view.id], do: size
    default = if known == [], do: 1, else: Enum.sum(known) / length(known)

    {panes, _} =
      Enum.map_reduce(views, false, fn entry, open_above? ->
        open? = open.(entry)

        pane =
          Map.merge(entry, %{
            open: open?,
            grow: if(open?, do: Map.get(assigns.view_sizes, entry.view.id, default), else: 0),
            sash: open? and open_above?,
            var: "--pane-" <> String.replace(entry.view.id, ~r/[^A-Za-z0-9_-]/, "_"),
            # Plugins views count their plugins, like VS Code's; Open VSX its results.
            count:
              cond do
                Map.has_key?(@plugins, entry.view.id) ->
                  length(plugins_in(assigns.plugins, entry.view.id))

                entry.view.id == @marketplace and assigns.marketplace.total > 0 ->
                  assigns.marketplace.total

                true ->
                  nil
              end
          })

        {pane, open_above? or open?}
      end)

    panes
  end

  defp plugins_in(plugins, view_id), do: Enum.filter(plugins, &(&1.scope in @plugins[view_id]))
end

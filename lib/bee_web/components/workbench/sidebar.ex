defmodule BeeWeb.Workbench.Sidebar do
  @moduledoc """
  The activity bar and the sidebar, built from `Bee.Views` contributions.

  The activity bar has one button per views container (`show_view`), with
  the summed badges of its plugin views. The sidebar shows the container's
  title, then its views: Bee's own (Explorer, Plugins) rendered by their
  components (Explorer, Search, Plugins), plugins' views by
  `BeeWeb.Workbench.ContributedView`. With a
  single view its `view/title` buttons sit in the container's header,
  otherwise each view gets a header of its own.

  The explorer's file tree stays mounted while another container is shown,
  so its expanded folders survive.
  """
  use BeeWeb, :html

  alias BeeWeb.Workbench.{ContributedView, PluginsView, SearchView, Toolbar}

  @explorer "workbench.explorer.fileView"
  @plugins "workbench.extensions.installed"
  @search "workbench.view.search"

  attr :containers, :list, required: true, doc: "with :badge"
  attr :sidebar_view, :string, required: true
  attr :sidebar_open, :boolean, required: true
  attr :keybindings, :list, required: true

  def activity_bar(assigns) do
    ~H"""
    <aside id="activity-bar" class="bg-base-300 flex flex-col items-center gap-1 py-2">
      <button
        :for={container <- @containers}
        id={"view-#{container.id}"}
        class={[
          "relative btn btn-ghost btn-square btn-sm",
          @sidebar_open && @sidebar_view == container.id && "btn-active"
        ]}
        title={title(container, @keybindings)}
        aria-label={container.title}
        phx-click="show_view"
        phx-value-container={container.id}
      >
        <BeeWeb.Icons.named_icon name={container.icon} class="size-5" />
        <span
          :if={container.badge}
          class="absolute -bottom-0.5 -right-0.5 min-w-4 h-4 px-1 rounded-full bg-primary text-primary-content text-[10px] leading-4"
        >
          {container.badge}
        </span>
      </button>
    </aside>
    """
  end

  # Bee's own containers have a show command with a keybinding.
  defp title(container, keybindings) do
    case Bee.Commands.Keybindings.label("workbench.view.#{container.id}", keybindings) do
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
  attr :search, :map, required: true

  def sidebar(assigns) do
    assigns =
      assign(assigns,
        explorer_shown: Enum.any?(assigns.views, &(&1.view.id == @explorer)),
        single: match?([_], assigns.views),
        explorer_id: @explorer,
        plugins_id: @plugins,
        search_id: @search
      )

    ~H"""
    <aside
      id="sidebar"
      class={[
        "bg-base-200 overflow-auto border-r border-base-300 flex flex-col",
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

      <div class={!@explorer_shown && "hidden"}>
        <.live_component
          module={BeeWeb.Workbench.FileTree}
          id="explorer"
          root={@root}
          active={@active && Bee.Workspace.FS.relative(@root, @active)}
        />
      </div>

      <section
        :for={entry <- @views}
        :if={entry.view.id != @explorer_id}
        id={"view-#{entry.view.id}"}
      >
        <div
          :if={!@single}
          class="flex items-center h-7 pl-3 pr-2 text-xs font-semibold uppercase tracking-wide border-t border-base-300"
        >
          <span class="flex-1 truncate">{entry.view.name}</span>
          <Toolbar.toolbar actions={entry.title_actions} class="normal-case" />
        </div>
        <SearchView.search_view :if={entry.view.id == @search_id} search={@search} />
        <PluginsView.plugins_view
          :if={entry.view.id == @plugins_id}
          plugins={@plugins}
          user_dir={Bee.Plugins.user_dir()}
        />
        <ContributedView.contributed_view
          :if={entry.view.id not in [@explorer_id, @plugins_id, @search_id]}
          view={entry.view}
          content={@view_contents[entry.view.id]}
          input={Map.get(@view_inputs, entry.view.id, "")}
          collapsed={@collapsed}
          item_actions={entry.item_actions}
        />
      </section>
    </aside>
    """
  end
end

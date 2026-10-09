defmodule BeeWeb.Workbench.MarketplaceView do
  @moduledoc """
  The Plugins container's search of Open VSX, like VS Code's Extensions
  view: `search_box/1` sits above the container's views; while it has a
  query the Open VSX view (`workbench.extensions.marketplace`, its
  `when` is `searchMarketplaceExtensions`) replaces Installed and
  Built-in, listing the results (`marketplace_view/1`).

  The state is `%Bee.Workbench{marketplace: ...}` (`Bee.Workbench.Marketplace`).
  A row's Install / Update buttons are `view/item/context` menu items in
  `bee.json` (`viewItem` is `openvsx.<notInstalled|outdated|installed>`);
  clicking a row opens its details (`extension.open` with its id).
  Icons load from Open VSX lazily, only for rows on screen.
  """
  use BeeWeb, :html

  alias Bee.Plugins.OpenVsx
  alias BeeWeb.Workbench.Toolbar

  attr :marketplace, :map, required: true

  def search_box(assigns) do
    ~H"""
    <form
      id="marketplace-form"
      class="px-2 pb-2 shrink-0"
      phx-change="marketplace_search"
      phx-submit="marketplace_search"
    >
      <input
        id="marketplace-query"
        name="query"
        type="search"
        value={@marketplace.query}
        placeholder="Search Extensions in Open VSX"
        aria-label="Search Extensions in Open VSX"
        autocomplete="off"
        spellcheck="false"
        phx-debounce="500"
        phx-hook="MarketplaceInput"
        class="input input-sm w-full"
      />
    </form>
    """
  end

  @doc "Every row context."
  def contexts, do: ~w(openvsx.notInstalled openvsx.outdated openvsx.installed)

  attr :marketplace, :map, required: true
  attr :installed, :map, required: true, doc: "OpenVsx.installed/0"
  attr :item_actions, :map, required: true, doc: "row context → inline actions"

  def marketplace_view(assigns) do
    ~H"""
    <div id="marketplace" class="text-sm" aria-busy={to_string(@marketplace.loading)}>
      <div
        :for={ext <- @marketplace.results}
        id={"openvsx-#{ext.id}"}
        data-id={ext.id}
        class="flex gap-3 px-3 py-2 hover:bg-list-hover cursor-pointer"
        phx-click="run_command"
        phx-value-command="extension.open"
        phx-value-args={Jason.encode!([ext.id])}
      >
        <img
          :if={ext.icon}
          src={ext.icon}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          class="size-10 shrink-0 object-contain"
        />
        <div
          :if={!ext.icon}
          class="size-10 shrink-0 grid place-items-center rounded bg-base-content/5"
        >
          <.icon name="hero-puzzle-piece" class="size-6 opacity-50" />
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <span class="font-medium truncate">{ext.display_name}</span>
            <span :if={ext.version} class="text-xs opacity-50 shrink-0">{ext.version}</span>
            <span class="flex-1" />
            <span class="flex items-center gap-2 text-xs opacity-60 shrink-0">
              <span :if={ext.downloads > 0} title={"#{ext.downloads} downloads"}>
                <.icon name="hero-arrow-down-tray-mini" class="size-3" />{downloads(ext.downloads)}
              </span>
              <span :if={ext.rating} title={"Rated #{Float.round(ext.rating * 1.0, 1)} of 5"}>
                <.icon name="hero-star-mini" class="size-3" />{Float.round(ext.rating * 1.0, 1)}
              </span>
            </span>
          </div>
          <div
            :if={ext.description}
            class="text-xs opacity-70 truncate"
            title={ext.description}
          >
            {ext.description}
          </div>
          <div class="flex items-center gap-1 text-xs">
            <span class="opacity-60 truncate">{ext.namespace}</span>
            <.icon
              :if={ext.verified}
              name="hero-check-badge-mini"
              class="size-3.5 text-primary shrink-0"
            />
            <span :if={ext.deprecated} class="badge badge-xs badge-warning">deprecated</span>
            <span class="flex-1" />
            <span
              :if={ext.id in @marketplace.installing}
              class="flex items-center gap-1 opacity-70"
            >
              <span class="loading loading-spinner loading-xs"></span> Installing
            </span>
            <span
              :if={
                ext.id not in @marketplace.installing and
                  context(ext, @installed) == "openvsx.installed"
              }
              class="badge badge-xs badge-ghost"
            >
              installed
            </span>
            <Toolbar.toolbar
              :if={ext.id not in @marketplace.installing}
              actions={Map.get(@item_actions, context(ext, @installed), [])}
              args={[ext.id]}
              text_class="btn-primary"
            />
          </div>
        </div>
      </div>

      <div
        :if={@marketplace.loading}
        id="marketplace-loading"
        class="flex items-center gap-2 px-3 py-2 text-xs opacity-70"
      >
        <span class="loading loading-spinner loading-xs"></span> Searching Open VSX…
      </div>

      <div :if={@marketplace.error} id="marketplace-error" class="px-3 py-2 text-xs space-y-1">
        <p class="text-error break-words">{@marketplace.error}</p>
        <button type="button" class="link" phx-click="marketplace_retry">Try again</button>
      </div>

      <p
        :if={not @marketplace.loading and is_nil(@marketplace.error) and @marketplace.results == []}
        id="marketplace-empty"
        class="px-3 py-2 text-xs opacity-60"
      >
        No extensions found.
      </p>

      <button
        :if={
          not @marketplace.loading and is_nil(@marketplace.error) and
            length(@marketplace.results) < @marketplace.total
        }
        id="marketplace-more"
        type="button"
        class="btn btn-ghost btn-xs w-full font-normal"
        phx-click="marketplace_more"
      >
        Show more ({length(@marketplace.results)} of {@marketplace.total})
      </button>
    </div>
    """
  end

  @doc "A result's row context: installed from Open VSX, and up to date?"
  def context(ext, installed) do
    case installed[String.downcase(ext.id)] do
      nil ->
        "openvsx.notInstalled"

      %{version: version} ->
        if OpenVsx.newer?(ext.version, version), do: "openvsx.outdated", else: "openvsx.installed"
    end
  end

  # 1234 → "1.2K", like VS Code's install counts.
  defp downloads(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp downloads(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp downloads(n), do: to_string(n)
end

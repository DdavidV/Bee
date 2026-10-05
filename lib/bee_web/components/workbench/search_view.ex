defmodule BeeWeb.Workbench.SearchView do
  @moduledoc """
  The Search view (`workbench.view.search`), VS Code style: the query with
  Match Case / Whole Word / Regex toggles, an optional replace field
  (Replace All), files to include / exclude, then the results grouped by
  file. Clicking a match opens it (`search_open`); hovering one offers to
  replace just it, hovering a file to replace in that file.

  The state is `%Bee.Workbench{search: ...}` (`Bee.Workbench.Search`). At
  most 2000 matches are rendered; the rest are only counted.
  """
  use BeeWeb, :html

  alias Bee.Workbench.Search

  @render_limit 2_000

  attr :search, :map, required: true

  def search_view(assigns) do
    assigns =
      assign(assigns,
        files: rendered_files(assigns.search),
        count: Search.match_count(assigns.search),
        replacing: assigns.search.show_replace
      )

    ~H"""
    <div id="search-view" class="text-sm pb-2">
      <form
        id="search-form"
        class="px-2 space-y-1"
        phx-change="search_update"
        phx-submit="search_refresh"
      >
        <div class="flex gap-1">
          <button
            type="button"
            id="search-toggle-replace"
            class="w-5 shrink-0 grid place-items-center rounded hover:bg-base-content/10 cursor-pointer"
            title="Toggle Replace"
            aria-expanded={to_string(@replacing)}
            phx-click="search_toggle"
            phx-value-key="show_replace"
          >
            <.icon
              name={if @replacing, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
              class="size-4"
            />
          </button>
          <div class="flex-1 min-w-0 space-y-1">
            <div class="relative">
              <input
                id="search-query"
                name="query"
                value={@search.query}
                placeholder="Search"
                autocomplete="off"
                spellcheck="false"
                phx-debounce="250"
                phx-hook="SearchInput"
                class="input input-sm w-full pr-20"
              />
              <span class="absolute right-1 inset-y-0 flex items-center gap-0.5">
                <.toggle
                  command="toggleSearchCaseSensitive"
                  on={@search.case_sensitive}
                  title="Match Case (Alt+C)"
                >
                  Aa
                </.toggle>
                <.toggle
                  command="toggleSearchWholeWord"
                  on={@search.whole_word}
                  title="Match Whole Word (Alt+W)"
                >
                  <span class="underline">ab</span>
                </.toggle>
                <.toggle
                  command="toggleSearchRegex"
                  on={@search.regex}
                  title="Use Regular Expression (Alt+R)"
                >
                  .*
                </.toggle>
              </span>
            </div>
            <div :if={@replacing} class="flex gap-1">
              <input
                id="search-replace"
                name="replace"
                value={@search.replace}
                placeholder="Replace"
                autocomplete="off"
                spellcheck="false"
                phx-debounce="250"
                class="input input-sm w-full flex-1 min-w-0"
              />
              <button
                type="button"
                id="search-replace-all"
                class="btn btn-ghost btn-sm btn-square"
                title="Replace All"
                disabled={@count == 0}
                phx-click="search_replace"
                phx-value-target="all"
                data-confirm={"Replace #{@count} #{plural(@count, "occurrence")} across #{map_size(@search.results)} #{plural(map_size(@search.results), "file")} with '#{@search.replace}'?"}
              >
                <BeeWeb.Icons.named_icon name="arrows-right-left" class="size-4" />
              </button>
            </div>
          </div>
        </div>

        <div class="flex justify-end">
          <button
            type="button"
            id="search-toggle-details"
            class="px-1 rounded text-xs opacity-60 hover:opacity-100 hover:bg-base-content/10 cursor-pointer"
            title="Toggle Search Details"
            phx-click="search_toggle"
            phx-value-key="show_details"
          >
            …
          </button>
        </div>
        <div :if={@search.show_details} class="space-y-1 pl-6">
          <label class="block text-xs opacity-70">files to include</label>
          <input
            id="search-include"
            name="include"
            value={@search.include}
            placeholder="e.g. *.ex, lib/bee"
            phx-debounce="250"
            class="input input-sm w-full"
          />
          <label class="block text-xs opacity-70">files to exclude</label>
          <input
            id="search-exclude"
            name="exclude"
            value={@search.exclude}
            placeholder="e.g. test, *.md"
            phx-debounce="250"
            class="input input-sm w-full"
          />
        </div>
      </form>

      <div id="search-status" class="px-4 pt-2 pb-1 text-xs opacity-70">
        <%= cond do %>
          <% @search.error -> %>
            <span class="text-error">{@search.error}</span>
          <% @search.running and @count == 0 -> %>
            Searching…
          <% @search.query == "" -> %>
          <% @count == 0 and @search.stats != nil -> %>
            No results found. Review your settings for configured exclusions.
          <% true -> %>
            {@count} {plural(@count, "result")} in {map_size(@search.results)} {plural(
              map_size(@search.results),
              "file"
            )}{if @search.running, do: " – searching…"}
            <span :if={@search.stats && @search.stats.limit_hit} class="block text-warning">
              The result set only contains a subset of all matches. Be more specific in your search to narrow down the results.
            </span>
            <span :if={@count > render_limit()} class="block">
              Showing the first {render_limit()} results.
            </span>
        <% end %>
      </div>

      <ul id="search-results" role="tree">
        <li :for={{file, matches} <- @files} role="treeitem">
          <div
            data-search-file={file.path}
            class="group flex items-center gap-1 pl-2 pr-2 py-0.5 cursor-pointer hover:bg-base-content/10"
            title={file.path}
            phx-click="search_toggle_file"
            phx-value-path={file.path}
          >
            <.icon
              name={
                if MapSet.member?(@search.collapsed, file.path),
                  do: "hero-chevron-right-mini",
                  else: "hero-chevron-down-mini"
              }
              class="size-4 shrink-0 opacity-70"
            />
            <BeeWeb.Icons.named_icon name="document" class="size-4 opacity-70" />
            <span class="truncate">{Path.basename(file.path)}</span>
            <span class="truncate text-xs opacity-50">{dir(file.path)}</span>
            <span class="flex-1" />
            <button
              :if={@replacing}
              type="button"
              class="hidden group-hover:block btn btn-ghost btn-xs btn-square"
              title="Replace All in File"
              data-replace-file={file.path}
              phx-click="search_replace"
              phx-value-target="file"
              phx-value-path={file.path}
            >
              <BeeWeb.Icons.named_icon name="arrows-right-left" class="size-3.5" />
            </button>
            <span class="badge badge-xs badge-ghost">{length(file.matches)}</span>
          </div>
          <ul :if={not MapSet.member?(@search.collapsed, file.path)} role="group">
            <li
              :for={match <- matches}
              data-search-match={"#{file.path}:#{match.from}"}
              class="group flex items-center gap-1 pl-9 pr-2 py-0.5 cursor-pointer hover:bg-base-content/10 whitespace-nowrap"
              title={"#{file.path}:#{match.line}"}
              phx-click="search_open"
              phx-value-path={file.path}
              phx-value-from={match.from}
              phx-value-to={match.to}
            >
              <span class="truncate flex-1 min-w-0">
                <span class="opacity-80">{match.before}</span><span class={[
                  "rounded-sm",
                  if(@replacing and @search.replace != "",
                    do: "bg-error/25 line-through",
                    else: "bg-warning/35"
                  )
                ]}>{match.match}</span><span
                  :if={@replacing and @search.replace != ""}
                  class="bg-success/25 rounded-sm"
                >{@search.replace}</span><span class="opacity-80">{match.after}</span>
              </span>
              <button
                :if={@replacing}
                type="button"
                class="hidden group-hover:block btn btn-ghost btn-xs btn-square"
                title="Replace"
                phx-click="search_replace"
                phx-value-target="match"
                phx-value-path={file.path}
                phx-value-from={match.from}
              >
                <BeeWeb.Icons.named_icon name="arrows-right-left" class="size-3.5" />
              </button>
            </li>
          </ul>
        </li>
      </ul>
    </div>
    """
  end

  attr :command, :string, required: true
  attr :on, :boolean, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp toggle(assigns) do
    ~H"""
    <button
      type="button"
      data-command={@command}
      aria-pressed={to_string(@on)}
      title={@title}
      class={[
        "h-5 min-w-5 px-0.5 rounded text-xs font-mono cursor-pointer",
        if(@on,
          do: "bg-primary/30 text-primary-content outline outline-primary",
          else: "opacity-70 hover:bg-base-content/10"
        )
      ]}
      phx-click="run_command"
      phx-value-command={@command}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp render_limit, do: @render_limit

  # Files by path, each with the matches still within the render limit.
  defp rendered_files(search) do
    search.results
    |> Map.values()
    |> Enum.sort_by(& &1.path)
    |> Enum.map_reduce(@render_limit, fn file, left ->
      shown = Enum.take(file.matches, max(left, 0))
      {{file, shown}, left - length(shown)}
    end)
    |> elem(0)
    |> Enum.reject(fn {_file, shown} -> shown == [] end)
  end

  defp dir(path) do
    case Path.dirname(path) do
      "." -> nil
      dir -> dir
    end
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end

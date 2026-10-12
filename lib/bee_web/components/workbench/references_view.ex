defmodule BeeWeb.Workbench.ReferencesView do
  @moduledoc """
  The References view, VS Code style: what Find All References found –
  every place the symbol is, by file, each with its line; a click goes
  there. A file's header folds its places away (`toggle_view_item`, like a
  plugin view's items; open again with the next search). It is in the sidebar (the References icon of the activity bar)
  unless the user moved it to the panel.
  """
  use BeeWeb, :html

  @view "workbench.panel.references"

  @doc "The view's id: its folded files are `{id, path}` in the window's `collapsed`."
  def view_id, do: @view

  attr :references, :map,
    default: nil,
    doc:
      "%{count, files: [%{path, rows}]} (BeeWeb.EditorLive.LanguageFeatures), nil before the first"

  attr :root, :string, required: true
  attr :icon_theme, :any, default: nil
  attr :collapsed, :any, default: nil, doc: "MapSet of folded {view id, file}"

  def references_view(assigns) do
    collapsed = assigns.collapsed || MapSet.new()

    files =
      for file <- (assigns.references && assigns.references.files) || [],
          do: {file, not MapSet.member?(collapsed, {@view, file.path})}

    assigns = assign(assigns, view: @view, files: files)

    ~H"""
    <div id="references" class="text-xs py-1">
      <p :if={!@references} id="references-empty" class="px-3 py-1 opacity-60">
        No references yet: Find All References (in an editor's right-click menu) lists a symbol's.
      </p>
      <p :if={@references} id="references-count" class="px-3 py-1 opacity-70">
        {@references.count} {if @references.count == 1, do: "reference", else: "references"} in {length(
          @references.files
        )} {if length(@references.files) == 1, do: "file", else: "files"}
      </p>
      <section
        :for={{file, open} <- @files}
        data-reference-file={file.path}
      >
        <h3
          role="button"
          aria-expanded={to_string(open)}
          title={Bee.Workspace.FS.relative(@root, file.path)}
          class="flex items-center gap-1 pl-1 pr-3 py-0.5 font-semibold cursor-pointer select-none hover:bg-list-hover"
          phx-click="toggle_view_item"
          phx-value-view={@view}
          phx-value-item={file.path}
        >
          <.icon
            name="hero-chevron-right-mini"
            class={[
              "size-4 shrink-0 opacity-70 transition-transform duration-150",
              open && "rotate-90"
            ]}
          />
          <BeeWeb.Workbench.FileIcon.file_icon
            :if={@icon_theme}
            theme={@icon_theme}
            path={file.path}
            class="shrink-0"
          />
          <span class="truncate">{Bee.Workspace.FS.relative(@root, file.path)}</span>
          <span class="badge badge-xs badge-ghost">{length(file.rows)}</span>
        </h3>
        <button
          :for={row <- if(open, do: file.rows, else: [])}
          type="button"
          data-reference={row.index}
          class="w-full flex gap-2 pl-8 pr-3 py-0.5 text-left font-mono cursor-pointer hover:bg-list-hover"
          phx-click="reference_open"
          phx-value-index={row.index}
        >
          <span class="opacity-50 shrink-0 w-10 text-right">{row.line}</span>
          <span class="truncate whitespace-pre">{row.before}<mark class="bg-warning/30 text-inherit rounded-xs">{row.match}</mark>{row.after}</span>
        </button>
      </section>
    </div>
    """
  end
end

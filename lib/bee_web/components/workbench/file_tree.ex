defmodule BeeWeb.Workbench.FileTree do
  @moduledoc """
  Explorer sidebar. Directories are listed lazily when expanded.
  Clicking a file sends `{:open_file, rel_path}` to the parent LiveView.

  `decorations` (workspace-relative path → decoration, see
  `Bee.UI.Decorations`) colour entries and give files a badge, e.g. git's
  "M" in yellow; folders take the colour of what they contain. Everything
  inside an ignored folder is dimmed too. Icons come from the file icon
  theme (`BeeWeb.Workbench.FileIcon`).

  Right-clicking an entry, or the empty space (the workspace folder), opens
  the `explorer/context` menu: every row carries the menu's id, its
  commands' argument (the absolute path) and `when` keys (see the
  ContextMenus hook). Files cut for pasting are dimmed.

  An input in the tree asks for a name, VS Code style (`edit`, set by the
  LiveView): a new file or folder's at the top of its folder, a new name in
  place of the entry renamed. Enter (or leaving it) does it
  (`Bee.Workspace.Files`) and tells the LiveView
  (`{:explorer_changed, edit, path}`), or shows why it can't; Escape
  cancels.
  """
  use BeeWeb, :live_component

  alias Bee.Workspace.{Files, FS}
  alias BeeWeb.Workbench.FileIcon

  @menu "explorer/context"

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       expanded: MapSet.new([""]),
       children: %{},
       decorations: %{},
       icon_theme: nil,
       clipboard: nil,
       edit: nil
     )}
  end

  @impl true
  # Files changed in these folders (absolute): those shown are listed again.
  def update(%{fs_changed: dirs}, socket) do
    # Other workspaces' files aren't ours (their paths stay absolute).
    shown =
      for abs <- dirs,
          dir = FS.relative(socket.assigns.root, abs),
          Map.has_key?(socket.assigns.children, dir),
          do: dir

    {:ok,
     Enum.reduce(shown, socket, fn dir, socket ->
       update(socket, :children, &Map.put(&1, dir, list(socket, dir)))
     end)}
  end

  # files.exclude changed, or Bee changed files: re-list every loaded directory.
  def update(%{refresh: true}, socket), do: {:ok, refresh(socket)}

  # An input for a name: %{kind: :new_file | :new_folder, dir} or %{kind: :rename, path}.
  def update(%{edit: nil}, socket), do: {:ok, assign(socket, edit: nil)}

  def update(%{edit: %{kind: kind} = request}, socket) do
    root = socket.assigns.root

    edit =
      case kind do
        :rename ->
          path = FS.relative(root, request.path)
          %{kind: kind, path: path, dir: parent(path), request: request, error: nil, value: nil}

        _new ->
          %{
            kind: kind,
            path: nil,
            dir: FS.relative(root, request.dir),
            request: request,
            error: nil,
            value: nil
          }
      end

    # The folder it is in (or creates into) is shown open.
    {:ok, socket |> assign(edit: edit) |> reveal(edit.dir)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # The window's folder is known now: its top level.
    if Map.has_key?(socket.assigns.children, ""),
      do: {:ok, socket},
      else: {:ok, update(socket, :children, &Map.put(&1, "", list(socket, "")))}
  end

  # A folder's entries, each with what its row says of it whatever happens
  # around it: built once per listing, not per render.
  defp list(socket, dir) do
    root = socket.assigns.root

    for entry <- Bee.Workspace.list_dir(root, dir) do
      abs = abs(root, entry.path)

      Map.merge(entry, %{
        keep: entry.type != :dir && abs,
        menu_args: Jason.encode!([abs]),
        menu_context: Jason.encode!(menu_context(root, abs, entry.type))
      })
    end
  end

  defp refresh(socket) do
    update(socket, :children, fn children ->
      Map.new(children, fn {dir, _} -> {dir, list(socket, dir)} end)
    end)
  end

  # Expands `dir` and its parents.
  defp reveal(socket, dir) do
    dirs = Stream.iterate(dir, &parent/1) |> Enum.take_while(&(&1 != "")) |> Enum.reverse()

    Enum.reduce(dirs, socket, fn dir, socket ->
      socket
      |> update(:expanded, &MapSet.put(&1, dir))
      |> update(:children, &Map.put(&1, dir, list(socket, dir)))
    end)
  end

  defp parent(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir
    end
  end

  @impl true
  def handle_event("toggle", %{"path" => dir}, socket) do
    socket =
      if MapSet.member?(socket.assigns.expanded, dir) do
        update(socket, :expanded, &MapSet.delete(&1, dir))
      else
        socket
        |> update(:expanded, &MapSet.put(&1, dir))
        |> update(:children, &Map.put(&1, dir, list(socket, dir)))
      end

    {:noreply, socket}
  end

  def handle_event("open", %{"path" => path}, socket) do
    send(self(), {:open_file, path})
    {:noreply, socket}
  end

  # Done here, so the tree changes at once; the LiveView then opens the new
  # file, or moves the tabs of what was renamed.
  def handle_event("edit_submit", %{"name" => name}, %{assigns: %{edit: %{} = edit}} = socket) do
    root = socket.assigns.root

    result =
      case edit.request do
        %{kind: :new_file, dir: dir} -> Files.create_file(root, dir, name)
        %{kind: :new_folder, dir: dir} -> Files.create_folder(root, dir, name)
        %{kind: :rename, path: path} -> Files.rename(root, path, name)
      end

    case result do
      {:ok, path} ->
        send(self(), {:explorer_changed, edit.request, path})

        {:noreply,
         socket |> assign(edit: nil) |> refresh() |> reveal(parent(FS.relative(root, path)))}

      {:error, message} ->
        {:noreply, assign(socket, edit: %{edit | error: message, value: name})}
    end
  end

  def handle_event("edit_submit", _params, socket), do: {:noreply, socket}

  def handle_event("edit_cancel", _params, socket), do: {:noreply, assign(socket, edit: nil)}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, rows: rows(assigns, cut(assigns.clipboard, assigns.root), ""))

    ~H"""
    <nav
      id={@id}
      class="text-sm select-none py-1 min-h-full"
      data-menu={menu()}
      data-menu-args={Jason.encode!([@root])}
      data-menu-context={Jason.encode!(menu_context(@root, @root, :dir))}
    >
      <div class="px-3 pb-1 text-[11px] font-semibold uppercase tracking-wide opacity-60 truncate">
        {Path.basename(@root)}
      </div>
      <.level rows={@rows} dir="" depth={0} edit={@edit} icon_theme={@icon_theme} myself={@myself} />
    </nav>
    """
  end

  # The rows of folder `dir`, each with everything it shows (its colour,
  # whether it is the active file, its folder's rows when it is open…).
  # A row is drawn from its own data alone, so LiveView sends a row again
  # only when that data changed: opening another file is two rows, not
  # the whole tree.
  defp rows(assigns, cut, dir) do
    for entry <- assigns.children[dir] || [] do
      decoration = decoration(assigns.decorations, entry.path)
      expanded = entry.type == :dir and MapSet.member?(assigns.expanded, entry.path)

      Map.merge(entry, %{
        title: title(entry.path, decoration),
        color: decoration && decoration.color,
        color_class: color_class(decoration),
        badge: decoration && decoration.badge,
        active: assigns.active == entry.path,
        cut: MapSet.member?(cut, entry.path),
        expanded: expanded,
        rows: if(expanded, do: rows(assigns, cut, entry.path), else: [])
      })
    end
  end

  attr :rows, :list, required: true
  attr :dir, :string, required: true, doc: "the folder listed (relative, \"\" for the root)"
  attr :depth, :integer, required: true
  attr :edit, :any, required: true, doc: "the name being asked for, or nil"
  attr :icon_theme, :any, required: true
  attr :myself, :any, required: true

  defp level(assigns) do
    ~H"""
    <ul>
      <li :if={new_here?(@edit, @dir)}>
        <.edit_row edit={@edit} depth={@depth} icon_theme={@icon_theme} myself={@myself} />
      </li>
      <li :for={row <- @rows}>
        <.edit_row
          :if={renaming?(@edit, row)}
          edit={@edit}
          entry={row}
          depth={@depth}
          icon_theme={@icon_theme}
          myself={@myself}
        />
        <button
          :if={!renaming?(@edit, row)}
          type="button"
          phx-click={if row.type == :dir, do: "toggle", else: "open"}
          phx-value-path={row.path}
          phx-target={@myself}
          title={row.title}
          data-decoration={row.color}
          data-keep={row.keep}
          data-menu={menu()}
          data-menu-args={row.menu_args}
          data-menu-context={row.menu_context}
          style={"padding-left: #{0.5 + @depth * 0.75}rem"}
          class={[
            "w-full flex items-center gap-1 pr-2 py-[2px] text-left cursor-pointer hover:bg-list-hover truncate",
            row.active && "bg-list-inactive",
            row.cut && "opacity-50"
          ]}
        >
          <.chevron type={row.type} expanded={row.expanded} icon_theme={@icon_theme} />
          <FileIcon.file_icon
            theme={@icon_theme}
            path={row.path}
            folder={row.type == :dir}
            expanded={row.expanded}
          />
          <span class={["truncate", row.color_class]}>
            {row.name}
          </span>
          <span :if={row.badge} class={["ml-auto pl-2 text-xs font-semibold", row.color_class]}>
            {row.badge}
          </span>
        </button>
        <.level
          :if={row.expanded}
          rows={row.rows}
          dir={row.path}
          depth={@depth + 1}
          edit={@edit}
          icon_theme={@icon_theme}
          myself={@myself}
        />
      </li>
    </ul>
    """
  end

  defp renaming?(%{kind: :rename, path: path}, %{path: path}), do: true
  defp renaming?(_edit, _row), do: false

  attr :type, :atom, required: true
  attr :expanded, :boolean, default: false
  attr :icon_theme, :any, required: true

  defp chevron(assigns) do
    ~H"""
    <.icon
      :if={@type == :dir and not FileIcon.hides_arrows?(@icon_theme)}
      name={if @expanded, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
      class="size-4 shrink-0 opacity-70"
    />
    <span
      :if={(@type == :file and @icon_theme) && not FileIcon.hides_arrows?(@icon_theme)}
      class="w-4 shrink-0"
    />
    """
  end

  attr :edit, :map, required: true
  attr :entry, :map, default: nil, doc: "the entry renamed"
  attr :depth, :integer, required: true
  attr :icon_theme, :any, required: true
  attr :myself, :any, required: true

  # The name input: in place of the entry renamed, or a new one's row.
  defp edit_row(assigns) do
    entry =
      assigns.entry ||
        %{type: if(assigns.edit.kind == :new_folder, do: :dir, else: :file), path: "", name: ""}

    assigns = assign(assigns, entry: entry)

    ~H"""
    <form
      id="explorer-edit"
      phx-submit="edit_submit"
      phx-target={@myself}
      class="flex items-center gap-1 pr-2 py-[1px]"
      style={"padding-left: #{0.5 + @depth * 0.75}rem"}
    >
      <.chevron type={@entry.type} expanded={@entry[:expanded] == true} icon_theme={@icon_theme} />
      <FileIcon.file_icon theme={@icon_theme} path={@entry.path} folder={@entry.type == :dir} />
      <input
        id="explorer-edit-input"
        name="name"
        value={@edit.value || @entry.name}
        phx-hook="ExplorerInput"
        phx-target={@myself}
        data-select={select_length(@edit, @entry)}
        autocomplete="off"
        spellcheck="false"
        aria-label={label(@edit.kind)}
        aria-invalid={to_string(@edit.error != nil)}
        class={[
          "flex-1 min-w-0 h-5 px-1 text-sm bg-input text-input-fg outline outline-1 rounded-none",
          if(@edit.error, do: "outline-error", else: "outline-focus")
        ]}
      />
    </form>
    <div
      :if={@edit.error}
      id="explorer-edit-error"
      role="alert"
      class="mr-2 mb-1 px-2 py-1 text-xs bg-error text-error-content"
      style={"margin-left: #{0.5 + @depth * 0.75 + 1.25}rem"}
    >
      {@edit.error}
    </div>
    """
  end

  defp new_here?(%{kind: kind, dir: dir}, dir) when kind in [:new_file, :new_folder], do: true
  defp new_here?(_edit, _dir), do: false

  # VS Code selects the name without its extension when renaming a file.
  defp select_length(%{kind: :rename}, %{type: :file, name: name}) do
    case Path.extname(name) do
      ext when ext != "" and ext != name -> String.length(name) - String.length(ext)
      _ -> String.length(name)
    end
  end

  defp select_length(_edit, entry), do: String.length(entry.name)

  defp label(:new_file), do: "New file name"
  defp label(:new_folder), do: "New folder name"
  defp label(:rename), do: "New name"

  ## Context menu

  defp menu, do: @menu

  # `when` keys of the explorer/context menu, VS Code's names.
  defp menu_context(root, abs, type) do
    %{
      "explorerResourceIsFolder" => type == :dir,
      "explorerResourceIsRoot" => abs == root,
      "resourcePath" => abs,
      "resourceFilename" => Path.basename(abs),
      "resourceExtname" => if(type == :file, do: Path.extname(abs), else: "")
    }
  end

  defp abs(root, ""), do: root
  defp abs(root, rel), do: Path.join(root, rel)

  defp cut(%{op: :cut, paths: paths}, root), do: MapSet.new(paths, &FS.relative(root, &1))
  defp cut(_clipboard, _root), do: MapSet.new()

  ## Decorations

  # Its own decoration, or "ignored" when inside an ignored folder.
  defp decoration(decorations, path) do
    decorations[path] || ignored_ancestor(decorations, Path.dirname(path))
  end

  defp ignored_ancestor(_decorations, "."), do: nil

  defp ignored_ancestor(decorations, dir) do
    case decorations[dir] do
      %{color: "ignored"} = d -> %{d | badge: nil}
      _ -> ignored_ancestor(decorations, Path.dirname(dir))
    end
  end

  defp color_class(nil), do: nil
  defp color_class(decoration), do: BeeWeb.Workbench.Decoration.color_class(decoration)

  defp title(path, %{tooltip: tooltip}) when is_binary(tooltip), do: "#{path} • #{tooltip}"
  defp title(path, _decoration), do: path
end

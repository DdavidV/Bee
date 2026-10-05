defmodule BeeWeb.Workbench.FileTree do
  @moduledoc """
  Explorer sidebar. Directories are listed lazily when expanded.
  Clicking a file sends `{:open_file, rel_path}` to the parent LiveView.

  `decorations` (workspace-relative path → decoration, see
  `Bee.UI.Decorations`) colour entries and give files a badge, e.g. git's
  "M" in yellow; folders take the colour of what they contain. Everything
  inside an ignored folder is dimmed too.
  """
  use BeeWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       expanded: MapSet.new([""]),
       children: %{"" => Bee.Workspace.list_dir("")},
       decorations: %{}
     )}
  end

  @impl true
  def update(%{fs_changed: abs}, socket) do
    dir = abs |> Path.dirname() |> then(&Bee.Workspace.FS.relative(Bee.Workspace.root(), &1))

    if Map.has_key?(socket.assigns.children, dir) do
      {:ok, update(socket, :children, &Map.put(&1, dir, Bee.Workspace.list_dir(dir)))}
    else
      {:ok, socket}
    end
  end

  # files.exclude changed: re-list every loaded directory.
  def update(%{refresh: true}, socket) do
    {:ok,
     update(socket, :children, fn children ->
       Map.new(children, fn {dir, _} -> {dir, Bee.Workspace.list_dir(dir)} end)
     end)}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("toggle", %{"path" => dir}, socket) do
    socket =
      if MapSet.member?(socket.assigns.expanded, dir) do
        update(socket, :expanded, &MapSet.delete(&1, dir))
      else
        socket
        |> update(:expanded, &MapSet.put(&1, dir))
        |> update(:children, &Map.put(&1, dir, Bee.Workspace.list_dir(dir)))
      end

    {:noreply, socket}
  end

  def handle_event("open", %{"path" => path}, socket) do
    send(self(), {:open_file, path})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <nav id={@id} class="text-sm select-none py-1">
      <div class="px-3 pb-1 text-[11px] font-semibold uppercase tracking-wide opacity-60 truncate">
        {Path.basename(@root)}
      </div>
      <.level
        entries={@children[""]}
        depth={0}
        expanded={@expanded}
        children={@children}
        active={@active}
        decorations={@decorations}
        myself={@myself}
      />
    </nav>
    """
  end

  attr :entries, :list, required: true
  attr :depth, :integer, required: true
  attr :expanded, :any, required: true
  attr :children, :map, required: true
  attr :active, :string
  attr :decorations, :map, required: true
  attr :myself, :any, required: true

  defp level(assigns) do
    ~H"""
    <ul>
      <li :for={entry <- @entries}>
        <button
          type="button"
          phx-click={if entry.type == :dir, do: "toggle", else: "open"}
          phx-value-path={entry.path}
          phx-target={@myself}
          title={title(entry.path, decoration(@decorations, entry.path))}
          data-decoration={(d = decoration(@decorations, entry.path)) && d.color}
          style={"padding-left: #{0.5 + @depth * 0.75}rem"}
          class={[
            "w-full flex items-center gap-1 pr-2 py-[2px] text-left cursor-pointer hover:bg-base-content/10 truncate",
            @active == entry.path && "bg-primary/25"
          ]}
        >
          <.icon
            :if={entry.type == :dir}
            name={
              if MapSet.member?(@expanded, entry.path),
                do: "hero-chevron-down-mini",
                else: "hero-chevron-right-mini"
            }
            class="size-4 shrink-0 opacity-70"
          />
          <.icon
            :if={entry.type == :file}
            name="hero-document-mini"
            class="size-4 shrink-0 opacity-50"
          />
          <span class={["truncate", color_class(decoration(@decorations, entry.path))]}>
            {entry.name}
          </span>
          <span
            :if={badge = (d = decoration(@decorations, entry.path)) && d.badge}
            class={["ml-auto pl-2 text-xs font-semibold", color_class(d)]}
          >
            {badge}
          </span>
        </button>
        <.level
          :if={entry.type == :dir and MapSet.member?(@expanded, entry.path)}
          entries={@children[entry.path] || []}
          depth={@depth + 1}
          expanded={@expanded}
          children={@children}
          active={@active}
          decorations={@decorations}
          myself={@myself}
        />
      </li>
    </ul>
    """
  end

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

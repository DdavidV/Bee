defmodule Bee.Views do
  @moduledoc """
  Views: a `Bee.Contributions.Point` for the `viewsContainers` and `views`
  sections of manifests, VS Code style.

    * a container is either an icon in the activity bar
      (`viewsContainers.activitybar`: `"explorer"`, `"extensions"`, a
      plugin's `"scm"`…; clicking it shows its views in the sidebar) or a
      section of the bottom panel (`viewsContainers.panel`: `"terminal"`,
      `"console"`…; its title is the panel's tab)
    * a view is a part of a container. Bee renders its own views (Explorer,
      Plugins, Search, Terminal, Bee Console) itself; a plugin fills its
      views with data through `Bee.API.set_view/3` (stored in `Bee.UI`),
      wherever they are

    * a view with `live` is drawn by a LiveView of the plugin instead
      (`Bee.Plugin.LiveView`), as is an editor (`editors`: `%{id, title,
      live}`), which opens in an editor tab (`Bee.API.open_editor/3`)

  A source may add views to another source's container (e.g. a plugin to
  `"explorer"`). Container, view and editor ids are unique across sources.
  """
  @behaviour Bee.Contributions.Point

  alias Bee.Contributions

  @type location :: :activitybar | :panel
  @type container :: %{
          id: String.t(),
          title: String.t(),
          icon: String.t(),
          location: location,
          source: term()
        }
  @type view :: %{
          id: String.t(),
          name: String.t(),
          container: String.t(),
          when_ast: list(),
          live: String.t() | nil,
          source: term()
        }
  @type editor :: %{id: String.t(), title: String.t(), live: String.t(), source: term()}

  @doc """
  The containers at `location` (the activity bar's, or the panel's
  sections), Bee's first, then in registration order.
  """
  @spec containers(location) :: [container]
  def containers(location \\ :activitybar),
    do: Enum.filter(all_containers(), &(&1.location == location))

  defp all_containers,
    do: Enum.flat_map(Contributions.entries(:views), &elem(&1, 1).containers)

  def container(id), do: Enum.find(all_containers(), &(&1.id == id))

  @spec views() :: [view]
  def views, do: Enum.flat_map(Contributions.entries(:views), &elem(&1, 1).views)

  def view(id), do: Enum.find(views(), &(&1.id == id))

  @doc "The editors plugins draw themselves (`editors`)."
  @spec editors() :: [editor]
  def editors, do: Enum.flat_map(Contributions.entries(:views), &elem(&1, 1).editors)

  def editor(id), do: Enum.find(editors(), &(&1.id == id))

  @doc "Views of container `id` whose `when` holds in `context`."
  def views_in(id, context \\ %{}) do
    for view <- views(),
        view.container == id,
        Bee.Commands.When.eval(view.when_ast, context),
        do: view
  end

  @doc "The plugin that contributed view `id`, or nil (Bee's own, or unknown)."
  def plugin(id) do
    case view(id) do
      %{source: {:plugin, name}} -> name
      _ -> nil
    end
  end

  ## Contribution point

  @impl Bee.Contributions.Point
  def key, do: :views

  @impl Bee.Contributions.Point
  def normalize!(manifest, source, _opts) do
    contributes = manifest["contributes"]

    containers =
      for location <- [:activitybar, :panel],
          c <- get_in(contributes, ["viewsContainers", Atom.to_string(location)]) || [] do
        %{id: c["id"], title: c["title"], icon: c["icon"], location: location, source: source}
      end

    views =
      for {container, views} <- Map.get(contributes, "views", %{}), v <- views do
        %{
          id: v["id"],
          name: v["name"],
          container: container,
          when_ast: Bee.Commands.When.parse!(v["when"]),
          live: v["live"],
          source: source
        }
      end

    editors =
      for e <- Map.get(contributes, "editors", []),
          do: %{id: e["id"], title: e["title"], live: e["live"], source: source}

    # Their modules are the plugin's, loaded with its server part.
    if (editors != [] or Enum.any?(views, & &1.live)) and
         not (match?({:plugin, _}, source) and manifest["server"] != nil),
       do: raise(ArgumentError, "a LiveView (\"live\") needs a plugin with a \"server\" part")

    if containers == [] and views == [] and editors == [],
      do: nil,
      else: %{containers: containers, views: views, editors: editors}
  end

  @impl Bee.Contributions.Point
  def conflicts(%{containers: containers, views: views, editors: editors}, others) do
    taken_containers = MapSet.new(for o <- others, c <- o.containers, do: c.id)
    taken_views = MapSet.new(for o <- others, v <- o.views, do: v.id)
    taken_editors = MapSet.new(for o <- others, e <- o.editors, do: e.id)

    for(
      c <- containers,
      c.id in taken_containers,
      do: "view container #{inspect(c.id)} is already defined"
    ) ++
      for(v <- views, v.id in taken_views, do: "view #{inspect(v.id)} is already defined") ++
      for e <- editors, e.id in taken_editors, do: "editor #{inspect(e.id)} is already defined"
  end
end

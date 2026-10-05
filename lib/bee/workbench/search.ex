defmodule Bee.Workbench.Search do
  @moduledoc """
  The search view's state – query, options, results – kept in the
  workbench (`%Bee.Workbench{search: ...}`), and the functions that change
  it. Like the rest of `Bee.Workbench` they return the new workbench or
  `{workbench, effects}`:

    * `{:start_search, opts}` – start `Bee.Search` (then `started/2`)
    * `{:cancel_search, handle}`
    * `{:replace, paths, opts, replacement, only}` – `Bee.Search.replace/4`,
      then search again

  Results arrive in batches (`results/3`, `done/3`); those of an older
  search are dropped.
  """

  alias Bee.Workbench

  @fields [:query, :replace, :include, :exclude]
  @toggles [:case_sensitive, :whole_word, :regex, :show_replace, :show_details]
  # Toggles that change what is found.
  @search_toggles [:case_sensitive, :whole_word, :regex]

  def new do
    %{
      query: "",
      replace: "",
      include: "",
      exclude: "",
      case_sensitive: false,
      whole_word: false,
      regex: false,
      show_replace: false,
      show_details: false,
      handle: nil,
      running: false,
      results: %{},
      collapsed: MapSet.new(),
      stats: nil,
      error: nil
    }
  end

  @doc "Options for `Bee.Search` from the state."
  def options(search),
    do: Map.take(search, [:query, :regex, :case_sensitive, :whole_word, :include, :exclude])

  @doc "Sets text fields (`query`, `replace`, `include`, `exclude`); searches again when needed."
  def update(%Workbench{search: search} = wb, params) do
    changes = for key <- @fields, Map.has_key?(params, key), into: %{}, do: {key, params[key]}
    new = Map.merge(search, changes)
    wb = %{wb | search: new}
    if options(new) != options(search), do: restart(wb), else: wb
  end

  def toggle(%Workbench{search: search} = wb, key) when key in @toggles do
    wb = %{wb | search: Map.update!(search, key, &(not &1))}
    if key in @search_toggles, do: restart(wb), else: wb
  end

  @doc "Searches again with the current query (or clears for an empty one)."
  def restart(%Workbench{search: search} = wb) do
    cancel = if search.handle, do: [{:cancel_search, search.handle}], else: []
    search = %{search | handle: nil, running: false, results: %{}, stats: nil, error: nil}

    if String.trim(search.query) == "" do
      {%{wb | search: search}, cancel}
    else
      {%{wb | search: %{search | running: true}}, cancel ++ [{:start_search, options(search)}]}
    end
  end

  def refresh(wb), do: restart(wb)

  @doc "Empties the query and the results."
  def clear(%Workbench{search: search} = wb),
    do: restart(%{wb | search: %{search | query: "", replace: ""}})

  def started(%Workbench{search: search} = wb, handle),
    do: %{wb | search: %{search | handle: handle}}

  def failed(%Workbench{search: search} = wb, message),
    do: %{wb | search: %{search | running: false, error: message}}

  def results(%Workbench{search: %{handle: %{ref: ref}} = search} = wb, ref, files) do
    results = Enum.reduce(files, search.results, &Map.put(&2, &1.path, &1))
    %{wb | search: %{search | results: results}}
  end

  def results(wb, _old_ref, _files), do: wb

  def done(%Workbench{search: %{handle: %{ref: ref}} = search} = wb, ref, stats),
    do: %{wb | search: %{search | running: false, stats: stats}}

  def done(wb, _old_ref, _stats), do: wb

  def toggle_file(%Workbench{search: search} = wb, path) do
    collapsed =
      if MapSet.member?(search.collapsed, path),
        do: MapSet.delete(search.collapsed, path),
        else: MapSet.put(search.collapsed, path)

    %{wb | search: %{search | collapsed: collapsed}}
  end

  @doc "Collapses every file, or expands them all when all are collapsed."
  def collapse_all(%Workbench{search: search} = wb) do
    paths = MapSet.new(Map.keys(search.results))

    collapsed =
      if MapSet.subset?(paths, search.collapsed) and paths != MapSet.new(),
        do: MapSet.new(),
        else: paths

    %{wb | search: %{search | collapsed: collapsed}}
  end

  @doc "Replaces in every file of the results (`paths: :all`), one file, or one match."
  def replace(%Workbench{search: search} = wb, target) do
    {paths, only} =
      case target do
        :all -> {Map.keys(search.results), nil}
        {:file, path} -> {[path], nil}
        {:match, path, from} -> {[path], [from]}
      end

    if paths == [],
      do: wb,
      else: {wb, [{:replace, paths, options(search), search.replace, only}]}
  end

  @doc "Total number of matches in the results."
  def match_count(search),
    do: search.results |> Map.values() |> Enum.map(&length(&1.matches)) |> Enum.sum()
end

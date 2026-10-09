defmodule Bee.Workbench.Marketplace do
  @moduledoc """
  The Plugins view's search of Open VSX (`Bee.Plugins.OpenVsx`), kept in
  the workbench (`%Bee.Workbench{marketplace: ...}`): the query, the
  results found so far, and which extensions are being installed. Like
  VS Code's, a query hides the Installed and Built-in views and shows the
  results (the `searchMarketplaceExtensions` context key).

  Functions return the new workbench or `{workbench, effects}`:

    * `{:marketplace_search, ref, query, offset}` – a page of results, then
      `results/4`; answers of an older search (`ref`) are dropped
    * `{:install_extension, id}` – `Bee.Plugins.OpenVsx.install/1`, then
      `installed/2`
  """

  alias Bee.Workbench

  def new do
    %{query: "", ref: nil, loading: false, results: [], total: 0, error: nil, installing: []}
  end

  @doc "A new query: searches (an empty one clears). The same query again does nothing."
  def update(%Workbench{marketplace: m} = wb, query) when is_binary(query) do
    if String.trim(query) == String.trim(m.query),
      do: %{wb | marketplace: %{m | query: query}},
      else: search(%{wb | marketplace: %{m | query: query}})
  end

  @doc "Searches again (after an error)."
  def refresh(wb), do: search(wb)

  def clear(wb), do: update(wb, "")

  defp search(%Workbench{marketplace: m} = wb) do
    query = String.trim(m.query)
    m = %{m | results: [], total: 0, error: nil}

    if query == "" do
      %{wb | marketplace: %{m | ref: nil, loading: false}}
    else
      ref = make_ref()

      {%{wb | marketplace: %{m | ref: ref, loading: true}},
       [{:marketplace_search, ref, query, 0}]}
    end
  end

  @doc "The next page, when there is one."
  def more(%Workbench{marketplace: m} = wb) do
    if (m.ref && not m.loading) and length(m.results) < m.total do
      {%{wb | marketplace: %{m | loading: true, error: nil}},
       [{:marketplace_search, m.ref, String.trim(m.query), length(m.results)}]}
    else
      wb
    end
  end

  @doc "A page of search `ref` arrived (or failed)."
  def results(%Workbench{marketplace: %{ref: ref} = m} = wb, ref, offset, result) do
    m =
      case result do
        {:ok, %{total: total, extensions: extensions}} ->
          # A later page appends, skipping ones already listed.
          old = if offset == 0, do: [], else: m.results
          ids = MapSet.new(old, & &1.id)
          new = Enum.reject(extensions, &MapSet.member?(ids, &1.id))
          %{m | results: old ++ new, total: if(new == [], do: length(old), else: total)}

        {:error, message} ->
          %{m | error: message}
      end

    %{wb | marketplace: %{m | loading: false}}
  end

  def results(wb, _old_ref, _offset, _result), do: wb

  @doc "Installs (or updates) extension `id`, unless it is being installed."
  def install(%Workbench{marketplace: m} = wb, id) do
    if id in m.installing,
      do: wb,
      else:
        {%{wb | marketplace: %{m | installing: [id | m.installing]}}, [{:install_extension, id}]}
  end

  @doc "Installing `id` is over."
  def installed(%Workbench{marketplace: m} = wb, id),
    do: %{wb | marketplace: %{m | installing: List.delete(m.installing, id)}}
end

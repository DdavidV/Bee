defmodule Bee.Workbench.SearchTest do
  use ExUnit.Case, async: true

  alias Bee.Workbench
  alias Bee.Workbench.Search

  defp wb, do: Workbench.new("/ws")
  defp handle, do: %{ref: make_ref(), pid: self()}

  test "a new query cancels the running search and starts another" do
    {wb, [{:start_search, %{query: "foo"} = opts}]} = Search.update(wb(), %{query: "foo"})
    assert opts.case_sensitive == false
    assert wb.search.running

    handle = handle()
    wb = Search.started(wb, handle)

    assert {_wb, [{:cancel_search, ^handle}, {:start_search, %{query: "foo", regex: true}}]} =
             Search.toggle(wb, :regex)

    # an empty query only clears
    assert {%{search: %{results: %{}, running: false}}, [{:cancel_search, ^handle}]} =
             Search.update(wb, %{query: " "})

    # replace text and showing replace don't search again
    assert %Workbench{} = Search.toggle(wb, :show_replace)
    assert %Workbench{} = Search.update(wb, %{replace: "bar"})
  end

  test "results of an older search are dropped" do
    {wb, _} = Search.update(wb(), %{query: "foo"})
    handle = handle()
    wb = Search.started(wb, handle)
    file = %{path: "a", matches: [%{from: 0}]}

    assert Search.results(wb, make_ref(), [file]).search.results == %{}
    wb = Search.results(wb, handle.ref, [file])
    assert wb.search.results == %{"a" => file}
    assert Search.match_count(wb.search) == 1

    wb = Search.done(wb, handle.ref, %{matches: 1})
    refute wb.search.running
    assert Workbench.context(wb)["hasSearchResult"]
  end

  test "replace targets" do
    {wb, _} = Search.update(wb(), %{query: "foo", replace: "bar"})
    handle = handle()

    wb =
      wb
      |> Search.started(handle)
      |> Search.results(handle.ref, [%{path: "a", matches: []}, %{path: "b", matches: []}])

    assert {_, [{:replace, paths, %{query: "foo"}, "bar", nil}]} = Search.replace(wb, :all)
    assert Enum.sort(paths) == ["a", "b"]
    assert {_, [{:replace, ["a"], _, "bar", [7]}]} = Search.replace(wb, {:match, "a", 7})
  end

  test "collapse all toggles" do
    {wb, _} = Search.update(wb(), %{query: "foo"})
    handle = handle()
    wb = wb |> Search.started(handle) |> Search.results(handle.ref, [%{path: "a", matches: []}])

    wb = Search.collapse_all(wb)
    assert MapSet.member?(wb.search.collapsed, "a")
    assert Search.collapse_all(wb).search.collapsed == MapSet.new()
  end
end

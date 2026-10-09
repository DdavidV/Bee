defmodule Bee.Workbench.MarketplaceTest do
  use ExUnit.Case, async: true

  alias Bee.Workbench
  alias Bee.Workbench.Marketplace

  defp ext(id), do: %{id: id}

  test "a query searches; an empty one or the same one doesn't" do
    wb = Workbench.new("/tmp")
    refute Workbench.context(wb)["searchMarketplaceExtensions"]

    {wb, [{:marketplace_search, ref, "dracula", 0}]} = Marketplace.update(wb, " dracula")
    assert wb.marketplace.loading
    assert Workbench.context(wb)["searchMarketplaceExtensions"]

    assert %Workbench{} = Marketplace.update(wb, "dracula ")

    wb = Marketplace.results(wb, ref, 0, {:ok, %{total: 3, extensions: [ext("a.b"), ext("c.d")]}})
    refute wb.marketplace.loading
    assert Enum.map(wb.marketplace.results, & &1.id) == ["a.b", "c.d"]

    # The next page appends.
    {wb, [{:marketplace_search, ^ref, "dracula", 2}]} = Marketplace.more(wb)
    assert %Workbench{} = Marketplace.more(wb)
    wb = Marketplace.results(wb, ref, 2, {:ok, %{total: 3, extensions: [ext("c.d"), ext("e.f")]}})
    assert Enum.map(wb.marketplace.results, & &1.id) == ["a.b", "c.d", "e.f"]
    assert %Workbench{} = Marketplace.more(wb)

    wb = Marketplace.clear(wb)
    assert wb.marketplace.results == []
    refute Workbench.context(wb)["searchMarketplaceExtensions"]
  end

  test "answers of an older search are dropped; errors are kept" do
    {wb, [{_, old, _, _}]} = Marketplace.update(Workbench.new("/tmp"), "a")
    {wb, [{_, new, _, _}]} = Marketplace.update(wb, "ab")

    wb = Marketplace.results(wb, old, 0, {:ok, %{total: 1, extensions: [ext("old.one")]}})
    assert wb.marketplace.results == [] and wb.marketplace.loading

    wb = Marketplace.results(wb, new, 0, {:error, "Can't reach Open VSX"})
    assert wb.marketplace.error == "Can't reach Open VSX"
    refute wb.marketplace.loading

    {wb, [{:marketplace_search, _, "ab", 0}]} = Marketplace.refresh(wb)
    assert wb.marketplace.error == nil
  end

  test "installing: once at a time per extension" do
    {wb, [{:install_extension, "a.b"}]} = Marketplace.install(Workbench.new("/tmp"), "a.b")
    assert wb.marketplace.installing == ["a.b"]
    assert %Workbench{} = Marketplace.install(wb, "a.b")
    assert Marketplace.installed(wb, "a.b").marketplace.installing == []
  end
end

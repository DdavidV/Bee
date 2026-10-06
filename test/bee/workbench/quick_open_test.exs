defmodule Bee.Workbench.QuickOpenTest do
  use ExUnit.Case, async: true

  alias Bee.Workbench.QuickOpen

  test "the query picks the mode" do
    assert QuickOpen.mode("") == :recent
    assert QuickOpen.mode("  ") == :recent
    assert QuickOpen.mode(">") == {:commands, ""}
    assert QuickOpen.mode("> toggle") == {:commands, "toggle"}
    assert QuickOpen.mode("app") == {:files, "app"}
  end

  test "file search: names before folders, whole words before letters, short paths first" do
    files = [
      "lib/bee/application.ex",
      "lib/app/other.ex",
      "test/app_test.exs",
      "assets/js/app.js",
      "README.md"
    ]

    assert QuickOpen.search(files, "app.js") == ["assets/js/app.js"]

    assert QuickOpen.search(files, "app") == [
             "assets/js/app.js",
             "test/app_test.exs",
             "lib/bee/application.ex",
             "lib/app/other.ex"
           ]

    # scattered letters, spaces ignored, any case
    assert QuickOpen.search(files, "RDM") == ["README.md"]
    assert QuickOpen.search(files, "bee app") == ["lib/bee/application.ex"]
    assert QuickOpen.search(files, "zzz") == []
    assert length(QuickOpen.search(files, "e", 2)) == 2
  end

  test "a longer query narrows the matches of a shorter one" do
    entries = Enum.map(["lib/app.ex", "lib/apple.ex", "lib/bee.ex"], &QuickOpen.entry/1)
    ap = QuickOpen.match(entries, "ap")
    assert length(ap) == 2
    assert QuickOpen.narrow(ap, "app") |> QuickOpen.top() == ["lib/app.ex", "lib/apple.ex"]
    assert QuickOpen.narrow(ap, "appl") |> QuickOpen.top() == ["lib/apple.ex"]
  end
end

defmodule Bee.UI.DecorationsTest do
  use ExUnit.Case, async: true

  alias Bee.UI.Decorations

  defp d(color, badge \\ nil), do: %{badge: badge, color: color, tooltip: nil}

  test "folders take the most important colour of what they contain" do
    decorations = %{
      "/ws/lib/new.ex" => d("untracked", "U"),
      "/ws/lib/web/page.ex" => d("modified", "M"),
      "/ws/docs/a.md" => d("added", "A"),
      "/ws/_build" => d("ignored"),
      "/elsewhere/x" => d("modified", "M"),
      "rel/path.ex" => d("conflict", "!")
    }

    result = Decorations.for_workspace(decorations, "/ws")

    assert result["lib/new.ex"] == d("untracked", "U")
    assert result["lib/web/page.ex"] == d("modified", "M")
    # modified beats untracked; folders get no badge
    assert result["lib"] == d("modified")
    assert result["lib/web"] == d("modified")
    assert result["docs"] == d("added")
    # ignored folders aren't propagated, outside paths dropped
    assert result["_build"] == d("ignored")
    refute Map.has_key?(result, ".")
    refute Enum.any?(Map.keys(result), &String.contains?(&1, "elsewhere"))
    assert result["rel"] == d("conflict")
  end

  test "normalize accepts atom or string keys, drops unknown colours, shortens badges" do
    assert Decorations.normalize!(%{"a" => %{"badge" => "Mod", "color" => "pink"}}) ==
             %{"a" => %{badge: "Mo", color: nil, tooltip: nil}}

    assert Decorations.normalize!(%{a: %{color: :modified, tooltip: "x"}}) ==
             %{"a" => %{badge: nil, color: "modified", tooltip: "x"}}

    assert_raise ArgumentError, fn -> Decorations.normalize!(%{"a" => "M"}) end
  end
end

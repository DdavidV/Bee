defmodule Bee.UITest do
  use ExUnit.Case, async: false

  alias Bee.{Contributions, UI}

  describe "view content" do
    test "is normalized: defaults, atom or string keys, JSON-safe arguments" do
      content =
        UI.normalize_view!(%{
          "message" => "hi",
          items: [
            %{
              id: "a",
              label: "A",
              decoration: %{text: "M", color: "modified"},
              children: [%{"id" => "b", "label" => :b, "expanded" => false}]
            }
          ],
          input: %{command: "x.commit", placeholder: "Message"},
          badge: 2
        })

      assert %{message: "hi", badge: 2, buttons: [], input: %{command: "x.commit", arguments: []}} =
               content

      assert [%{id: "a", arguments: ["a"], expanded: true, decoration: %{color: "modified"}} = a] =
               content.items

      assert [%{id: "b", label: "b", expanded: false, children: []}] = a.children
      assert UI.normalize_view!(%{badge: 0}).badge == nil

      assert UI.normalize_view!(%{items: [%{id: 1, label: "x", decoration: %{color: "pink"}}]}).items
             |> hd()
             |> get_in([:decoration, :color]) == nil
    end

    test "rejects what can't be shown" do
      assert_raise ArgumentError, ~r/label is required/, fn ->
        UI.normalize_view!(%{items: [%{id: "a"}]})
      end

      assert_raise ArgumentError, ~r/must be a map/, fn -> UI.normalize_view!([]) end

      assert_raise ArgumentError, ~r/JSON-encodable/, fn ->
        UI.normalize_view!(%{buttons: [%{label: "x", command: "y", arguments: [self()]}]})
      end
    end
  end

  describe "views and status items" do
    setup do
      on_exit(fn ->
        Contributions.unregister({:plugin, "ui-test"})
        UI.forget("ui-test")
      end)

      :ok =
        Contributions.register({:plugin, "ui-test"}, %{
          "name" => "ui-test",
          "contributes" => %{
            "viewsContainers" => %{
              "activitybar" => [%{"id" => "uitest", "title" => "T", "icon" => "star"}]
            },
            "views" => %{"uitest" => [%{"id" => "uitest.v", "name" => "V"}]}
          }
        })

      UI.subscribe()
      %{ctx: %Bee.Plugins.Context{plugin: "ui-test"}}
    end

    test "a plugin sets its own views only, and forget clears them", %{ctx: ctx} do
      assert Bee.Views.plugin("uitest.v") == "ui-test"
      assert %{id: "uitest", icon: "star"} = Bee.Views.container("uitest")

      :ok = Bee.API.set_view(ctx, "uitest.v", %{message: "hello"})
      assert_receive {:ui_changed, {:view, "uitest.v"}}
      assert %{message: "hello"} = UI.view("uitest.v")

      assert_raise ArgumentError, ~r/no view/, fn ->
        Bee.API.set_view(ctx, "workbench.explorer.fileView", %{})
      end

      :ok = Bee.API.set_status_item(ctx, "s", %{text: "hi", alignment: :right})

      assert [%{id: "s", owner: "ui-test", alignment: :right}] =
               Enum.filter(UI.status_items(), &(&1.owner == "ui-test"))

      UI.forget("ui-test")
      assert UI.view("uitest.v") == nil
      assert Enum.filter(UI.status_items(), &(&1.owner == "ui-test")) == []
    end

    test "container and view ids are unique" do
      assert {:error, message} =
               Contributions.register({:plugin, "ui-test-2"}, %{
                 "name" => "ui-test-2",
                 "contributes" => %{
                   "viewsContainers" => %{
                     "activitybar" => [%{"id" => "explorer", "title" => "E", "icon" => "x"}]
                   },
                   "views" => %{"explorer" => [%{"id" => "uitest.v", "name" => "again"}]}
                 }
               })

      assert message =~ ~s(view container "explorer" is already defined)
      assert message =~ ~s(view "uitest.v" is already defined)
    end
  end
end

defmodule Desktop.BridgeTest do
  # Uses the workspace and Bee's endpoint, which are global.
  use ExUnit.Case, async: false

  alias Desktop.Bridge

  @moduletag :capture_log

  setup do
    File.mkdir_p!(Bee.Workspace.root())
    bridge = start_supervised!({Bridge, io: {:test, self()}, name: nil})
    %{bridge: bridge}
  end

  defp frame(bridge, map), do: send(bridge, {:frame, Jason.encode!(map)})

  defp get(bridge, id, url, win \\ "w1") do
    frame(bridge, %{
      t: "req",
      id: id,
      win: win,
      method: "GET",
      url: url,
      headers: [["accept", "text/html"]]
    })

    assert_receive {:bridge_out, %{t: "res", id: ^id} = res}, 5_000
    %{res | body: Base.decode64!(res.body)}
  end

  # The page's LiveView: what the browser would join with.
  defp page(bridge, win \\ "w1") do
    %{status: 200, body: html} =
      get(bridge, System.unique_integer([:positive]), "bee://localhost/", win)

    doc = LazyHTML.from_document(html)
    main = LazyHTML.query(doc, "[data-phx-main]")
    attr = &(main |> LazyHTML.attribute(&1) |> hd())

    %{
      csrf:
        doc |> LazyHTML.query("meta[name=csrf-token]") |> LazyHTML.attribute("content") |> hd(),
      id: attr.("id"),
      session: attr.("data-phx-session"),
      static: attr.("data-phx-static")
    }
  end

  defp open(bridge, sid, csrf, win \\ "w1") do
    url = "ws://localhost/live/websocket?vsn=2.0.0&_csrf_token=#{csrf}"
    frame(bridge, %{t: "open", sid: sid, win: win, url: url})
  end

  defp push(bridge, sid, message),
    do: frame(bridge, %{t: "msg", sid: sid, data: Jason.encode!(message), bin: false})

  # The next message of socket `sid` (V2 serializer: [join_ref, ref, topic, event, payload]).
  defp reply(sid, ref) do
    assert_receive {:bridge_out, %{t: "msg", sid: ^sid, data: data}}, 5_000

    case Jason.decode!(data) do
      [_, ^ref, _, "phx_reply", payload] -> payload
      _other -> reply(sid, ref)
    end
  end

  defp join(bridge, sid, page) do
    push(bridge, sid, [
      "1",
      "1",
      "lv:#{page.id}",
      "phx_join",
      %{
        url: "bee://localhost/",
        params: %{"_csrf_token" => page.csrf, "_mounts" => 0},
        session: page.session,
        static: page.static
      }
    ])

    reply(sid, "1")
  end

  test "pages come through the endpoint; cookies stay in the bridge", %{bridge: bridge} do
    res = get(bridge, 1, "bee://localhost/")
    assert res.status == 200
    assert res.body =~ "data-phx-main"
    refute Enum.any?(res.headers, fn [k, _] -> k == "set-cookie" end)

    assert %{status: 200} = get(bridge, 2, "bee://localhost/favicon.ico")
    assert %{status: 404} = get(bridge, 3, "bee://localhost/nope")
  end

  test "LiveView joins and handles events over the bridge", %{bridge: bridge} do
    page = page(bridge)
    open(bridge, "s1", page.csrf)
    assert_receive {:bridge_out, %{t: "opened", sid: "s1"}}, 5_000

    assert %{"status" => "ok", "response" => %{"rendered" => rendered}} = join(bridge, "s1", page)
    assert Jason.encode!(rendered) =~ "explorer"

    # A click: the sidebar shows Search.
    push(bridge, "s1", [
      "1",
      "2",
      "lv:#{page.id}",
      "event",
      %{type: "click", event: "show_view", value: %{container: "search"}}
    ])

    assert %{"status" => "ok", "response" => %{"diff" => diff}} = reply("s1", "2")
    assert Jason.encode!(diff) =~ "search"

    frame(bridge, %{t: "close", sid: "s1"})
    refute_receive {:bridge_out, %{t: "closed", sid: "s1"}}, 200
  end

  test "another window without the page's cookie can't join it", %{bridge: bridge} do
    page = page(bridge, "w1")
    open(bridge, "s2", page.csrf, "w2")
    assert_receive {:bridge_out, %{t: "opened", sid: "s2"}}, 5_000

    # The CSRF token belongs to w1's session cookie, which w2 doesn't have.
    assert %{"status" => "error"} = join(bridge, "s2", page)
  end

  test "bad input is ignored", %{bridge: bridge} do
    send(bridge, {:frame, "not json"})
    frame(bridge, %{t: "unknown"})
    frame(bridge, %{t: "msg", sid: "nope", data: "x", bin: false})
    assert %{status: 200} = get(bridge, 9, "bee://localhost/favicon.ico")
  end
end

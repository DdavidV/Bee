defmodule BeeWeb.EditorLive.NotificationsTest do
  use ExUnit.Case, async: true

  alias BeeWeb.EditorLive.Notifications

  # A window's socket with what notify/3 reads; `connected?`: as after the
  # page connected, else as for the page rendered first.
  defp socket(connected?, settings \\ %{}) do
    %Phoenix.LiveView.Socket{
      transport_pid: if(connected?, do: self()),
      assigns: %{
        __changed__: %{},
        settings: settings,
        notifications: [],
        toasts: [],
        notifications_open: false
      }
    }
  end

  describe "notify/3" do
    test "pops the message up and lists it; the same again is counted" do
      socket =
        socket(true)
        |> Notifications.notify(:error, "  broken\n")
        |> Notifications.notify(:info, "saved")
        |> Notifications.notify(:error, "broken")

      assert [
               %{id: again, severity: :error, message: "broken", count: 2},
               %{id: saved, severity: :info, message: "saved", count: 1}
             ] = socket.assigns.notifications

      assert socket.assigns.toasts == [again, saved]
    end

    test "with the list open, nothing pops up" do
      socket = socket(true) |> Phoenix.Component.assign(notifications_open: true)
      socket = Notifications.notify(socket, :info, "saved")

      assert [%{message: "saved"}] = socket.assigns.notifications
      assert socket.assigns.toasts == []
    end

    test "keeps the last workbench.notifications.maxCount" do
      socket =
        Enum.reduce(1..4, socket(true, %{"workbench.notifications.maxCount" => 2}), fn n,
                                                                                       socket ->
          Notifications.notify(socket, :info, "message #{n}")
        end)

      assert ["message 4", "message 3"] = Enum.map(socket.assigns.notifications, & &1.message)
      assert length(socket.assigns.toasts) == 2
    end

    test "a toast is taken down after workbench.notifications.toastTimeout – once connected" do
      settings = %{"workbench.notifications.toastTimeout" => 1}

      # The page rendered before the window connects: its process ends with
      # the request, so no timer is started for it.
      %{assigns: %{toasts: [_shown]}} = Notifications.notify(socket(false, settings), :error, "a")
      %{assigns: %{toasts: [id]}} = Notifications.notify(socket(true, settings), :error, "b")

      assert_receive {:toast_expired, ^id}, 2_000
      refute_receive {:toast_expired, _other}, 200
    end

    test "a timeout of 0 keeps toasts up" do
      settings = %{"workbench.notifications.toastTimeout" => 0}
      %{assigns: %{toasts: [_id]}} = Notifications.notify(socket(true, settings), :error, "stays")

      refute_receive {:toast_expired, _id}, 100
    end
  end
end

defmodule BeeWeb.EditorLive.Notifications do
  @moduledoc """
  Notifications: messages that pop up at the bottom right and stay in the
  list (the status bar's bell), and what extensions are busy with
  (progress, `Bee.UI`).
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView, only: [connected?: 1]
  import BeeWeb.EditorLive.Window

  ## Events

  # The × of a notification, popped up or in the list.
  def handle_event("notification_close", %{"id" => id}, socket) do
    id = int(id)

    {:halt,
     socket
     |> update(:notifications, &Enum.reject(&1, fn n -> n.id == id end))
     |> update(:toasts, &List.delete(&1, id))}
  end

  # Cancel on what an extension is busy with (window.withProgress). Only
  # extensions can offer it: a plugin's progress has none (Bee.API.progress/3).
  def handle_event("progress_cancel", %{"owner" => owner, "id" => id}, socket) do
    Bee.Extensions.Host.cancel_progress(socket.assigns.root, owner, id)
    {:halt, socket}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  def handle_info({:ui_changed, :progress}, socket),
    do: {:halt, assign(socket, progress: Bee.UI.progress(socket.assigns.root))}

  # A notification has popped up long enough: it stays in the list.
  def handle_info({:toast_expired, id}, socket),
    do: {:halt, update(socket, :toasts, &List.delete(&1, id))}

  def handle_info(_message, socket), do: {:cont, socket}

  # Tells the user: `message` pops up at the bottom right (for
  # workbench.notifications.toastTimeout seconds), and stays in the list of
  # the last workbench.notifications.maxCount. One said again moves up,
  # counted.
  def notify(socket, severity, message) do
    message = message |> to_string() |> String.trim()
    settings = socket.assigns.settings
    same? = &(&1.severity == severity and &1.message == message)
    {again, others} = Enum.split_with(socket.assigns.notifications, same?)
    count = Enum.reduce(again, 1, &(&1.count + &2))
    id = System.unique_integer([:positive])
    entry = %{id: id, severity: severity, message: message, count: count}
    kept = Enum.take([entry | others], positive(settings["workbench.notifications.maxCount"], 20))
    ids = MapSet.new(kept, & &1.id)

    toasts =
      if socket.assigns.notifications_open,
        do: [],
        else: [id | Enum.filter(socket.assigns.toasts, &(&1 in ids))]

    # (Not for the page rendered before the window connects: nobody is
    # there to take it down.)
    case connected?(socket) && settings["workbench.notifications.toastTimeout"] do
      off when off in [false, 0] -> :ok
      seconds -> Process.send_after(self(), {:toast_expired, id}, positive(seconds, 8) * 1000)
    end

    assign(socket, notifications: kept, toasts: toasts)
  end

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_other, default), do: default
end

defmodule BeeWeb.Workbench.Notifications do
  @moduledoc """
  A window's notifications, like VS Code's, at the bottom right above the
  status bar: what Bee, plugins and extensions tell the user
  (`Bee.API.show_message/3`, an extension's `window.show…Message`) and
  what they are busy with (`Bee.UI`'s progress, `window.withProgress`).

  A new one pops up as a toast, for `workbench.notifications.toastTimeout`
  seconds; the status bar's bell (`bell/1`) opens the list of the last
  `workbench.notifications.maxCount`, where they are closed one by one or
  all at once. While the list is open nothing pops up: it shows there.
  """
  use BeeWeb, :html

  attr :notifications, :list,
    required: true,
    doc: "%{id, severity: :info | :warning | :error, message, count}, the newest first"

  attr :toasts, :list, required: true, doc: "the ids of those popped up"
  attr :progress, :list, required: true, doc: "Bee.UI.progress/1"
  attr :open, :boolean, required: true, doc: "whether the list shows"

  def notifications(assigns) do
    assigns =
      assign(assigns,
        popped: Enum.filter(assigns.notifications, &(&1.id in assigns.toasts)),
        popped_progress: Enum.filter(assigns.progress, & &1.toast)
      )

    ~H"""
    <div
      id="notifications"
      aria-live="polite"
      class="fixed right-2 bottom-8 z-40 w-[28rem] max-w-[calc(100vw-1rem)] flex flex-col gap-2 text-sm pointer-events-none"
    >
      <section
        :if={@open}
        id="notification-center"
        phx-window-keydown="run_command"
        phx-key="Escape"
        phx-value-command="notifications.hideList"
        class={[card_class(), "flex flex-col max-h-[60vh]"]}
      >
        <header class="flex items-center gap-1 pl-3 pr-1.5 py-1 border-b border-widget-border">
          <span class="flex-1 text-xs font-semibold uppercase tracking-wide opacity-80">
            {if @notifications == [] and @progress == [],
              do: "No New Notifications",
              else: "Notifications"}
          </span>
          <.action
            id="notifications-clear"
            command="notifications.clearAll"
            title="Clear All Notifications"
            disabled={@notifications == []}
          >
            <BeeWeb.Icons.named_icon name="$(clear-all)" class="size-4" />
          </.action>
          <.action id="notifications-hide" command="notifications.hideList" title="Hide Notifications">
            <.icon name="hero-chevron-down-micro" class="size-4" />
          </.action>
        </header>
        <ul class="overflow-y-auto divide-y divide-widget-border">
          <.progress_item :for={item <- @progress} item={item} />
          <.message :for={n <- @notifications} notification={n} />
        </ul>
      </section>

      <ul
        :if={not @open and (@popped != [] or @popped_progress != [])}
        id="notification-toasts"
        class="flex flex-col gap-2"
      >
        <.message :for={n <- Enum.take(@popped, 3)} notification={n} class={card_class()} toast />
        <.progress_item :for={item <- @popped_progress} item={item} class={card_class()} toast />
      </ul>
    </div>
    """
  end

  defp card_class,
    do:
      "pointer-events-auto rounded-md bg-quickinput text-quickinput-fg border border-widget-border shadow-xl"

  attr :notification, :map, required: true
  attr :class, :string, default: nil
  attr :toast, :boolean, default: false

  defp message(assigns) do
    ~H"""
    <li
      id={"#{if @toast, do: "toast", else: "notification"}-#{@notification.id}"}
      role={if @toast, do: "alert"}
      data-severity={@notification.severity}
      class={["group flex items-start gap-2 pl-3 pr-1.5 py-2", @class]}
    >
      <.severity_icon severity={@notification.severity} />
      <%!-- (Its line breaks are kept: none of the template's own.) --%>
      <p
        class="flex-1 min-w-0 whitespace-pre-wrap break-words max-h-40 overflow-y-auto"
        phx-no-format
      >{@notification.message}</p>
      <span
        :if={@notification.count > 1}
        class="shrink-0 px-1.5 rounded-full bg-badge text-badge-fg text-xs"
        title={"Shown #{@notification.count} times"}
      >
        {@notification.count}
      </span>
      <button
        type="button"
        class="shrink-0 p-0.5 rounded cursor-pointer opacity-60 hover:opacity-100 hover:bg-list-hover"
        title="Clear Notification"
        aria-label="Clear Notification"
        phx-click="notification_close"
        phx-value-id={@notification.id}
      >
        <.icon name="hero-x-mark-micro" class="size-4" />
      </button>
    </li>
    """
  end

  attr :severity, :atom, required: true

  defp severity_icon(%{severity: :error} = assigns) do
    ~H"""
    <.icon name="hero-x-circle-mini" class="size-4.5 shrink-0 mt-px text-error" />
    """
  end

  defp severity_icon(%{severity: :warning} = assigns) do
    ~H"""
    <.icon name="hero-exclamation-triangle-mini" class="size-4.5 shrink-0 mt-px text-warning" />
    """
  end

  defp severity_icon(assigns) do
    ~H"""
    <.icon name="hero-information-circle-mini" class="size-4.5 shrink-0 mt-px text-info" />
    """
  end

  attr :item, :map, required: true
  attr :class, :string, default: nil
  attr :toast, :boolean, default: false

  # What a plugin is busy with: its spinner, and how far it is if it says.
  defp progress_item(assigns) do
    ~H"""
    <li
      id={"#{if @toast, do: "toast-progress", else: "progress"}-#{@item.owner}-#{@item.id}"}
      data-progress={@item.owner}
      class={["flex flex-col gap-1.5 pl-3 pr-1.5 py-2", @class]}
    >
      <div class="flex items-start gap-2">
        <.icon name="hero-arrow-path-micro" class="size-4 shrink-0 mt-0.5 motion-safe:animate-spin" />
        <p class="flex-1 min-w-0 break-words">
          {progress_text(@item)}
          <span :if={@item.percent} class="opacity-60">{@item.percent}%</span>
        </p>
        <button
          :if={@item.cancellable}
          type="button"
          class="shrink-0 px-2 rounded cursor-pointer text-xs border border-widget-border hover:bg-list-hover"
          phx-click="progress_cancel"
          phx-value-owner={@item.owner}
          phx-value-id={@item.id}
        >
          Cancel
        </button>
      </div>
      <div class="flex items-center gap-2 pl-6">
        <progress
          :if={@item.percent}
          class="progress progress-primary h-1 flex-1"
          value={@item.percent}
          max="100"
        />
        <span class="text-xs opacity-60 truncate">Source: {@item.owner}</span>
      </div>
    </li>
    """
  end

  @doc "A progress in a line: its title and what it says now."
  def progress_text(%{title: title, message: message}) do
    case {title, message} do
      {"", nil} -> "Working…"
      {title, nil} -> title
      {"", message} -> message
      {title, message} -> "#{title}: #{message}"
    end
  end

  attr :id, :string, required: true
  attr :command, :string, required: true
  attr :title, :string, required: true
  attr :disabled, :boolean, default: false
  slot :inner_block, required: true

  defp action(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={[
        "p-1 rounded",
        if(@disabled,
          do: "opacity-30",
          else: "cursor-pointer opacity-70 hover:opacity-100 hover:bg-list-hover"
        )
      ]}
      title={@title}
      aria-label={@title}
      disabled={@disabled}
      phx-click="run_command"
      phx-value-command={@command}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :notifications, :list, required: true
  attr :progress, :list, required: true
  attr :open, :boolean, required: true

  @doc "The status bar's end: what is going on (a spinner), and the bell that opens the list."
  def bell(assigns) do
    ~H"""
    <button
      :if={@progress != []}
      id="status-progress"
      type="button"
      class="flex items-center gap-1 px-1 rounded min-w-0 cursor-pointer hover:bg-statusbar-fg/15"
      title={Enum.map_join(@progress, "\n", &"#{&1.owner}: #{progress_text(&1)}")}
      phx-click="run_command"
      phx-value-command="notifications.showList"
    >
      <.icon name="hero-arrow-path-micro" class="size-3.5 shrink-0 motion-safe:animate-spin" />
      <span class="truncate max-w-64">{progress_text(List.last(@progress))}</span>
    </button>
    <button
      id="status-notifications"
      type="button"
      class={[
        "relative flex items-center px-1 rounded shrink-0 cursor-pointer hover:bg-statusbar-fg/15",
        @open && "bg-statusbar-fg/15"
      ]}
      title={bell_title(@notifications)}
      aria-label={bell_title(@notifications)}
      data-count={length(@notifications)}
      phx-click="run_command"
      phx-value-command="notifications.toggleList"
    >
      <.icon
        name={if @notifications == [], do: "hero-bell-micro", else: "hero-bell-alert-micro"}
        class="size-3.5"
      />
    </button>
    """
  end

  defp bell_title([]), do: "No Notifications"
  defp bell_title([_]), do: "1 Notification"
  defp bell_title(notifications), do: "#{length(notifications)} Notifications"
end

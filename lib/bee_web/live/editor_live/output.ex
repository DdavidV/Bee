defmodule BeeWeb.EditorLive.Output do
  @moduledoc """
  The panel's Output section (`Bee.Output`): it shows one channel.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  ## Events

  # Its text element is there (the Output hook): the channel's text so far.
  def handle_event("output_ready", _params, socket), do: {:halt, push_output(socket)}

  def handle_event("output_channel", %{"channel" => channel}, socket),
    do: {:halt, socket |> assign(output_channel: channel) |> push_output()}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  ## Messages

  # Extensions wrote to an output channel (Bee.Output): the shown one's
  # text goes to its element as it comes.
  def handle_info({:output, :appended, channel, text}, socket) do
    if channel == socket.assigns.output_channel and socket.assigns.panel_open,
      do: {:halt, push_event(socket, "output:append", %{channel: channel, text: text})},
      else: {:halt, socket}
  end

  def handle_info({:output, :cleared, channel}, socket) do
    if channel == socket.assigns.output_channel,
      do: {:halt, push_output(socket)},
      else: {:halt, socket}
  end

  def handle_info({:output, :channels}, socket) do
    before = socket.assigns.output_channel
    socket = load_output_channels(socket)
    # The first channel there is, is shown.
    {:halt, if(before == nil, do: push_output(socket), else: socket)}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  # The channels there are; the one shown stays, else the first is.
  def load_output_channels(socket) do
    channels = Bee.Output.channels(socket.assigns.root)
    shown = socket.assigns[:output_channel]
    shown = if shown in channels, do: shown, else: List.first(channels)
    assign(socket, output_channels: channels, output_channel: shown)
  end

  # The shown channel's whole text, for the Output hook.
  def push_output(socket) do
    channel = socket.assigns.output_channel
    text = if channel, do: Bee.Output.get(socket.assigns.root, channel), else: ""
    push_event(socket, "output:set", %{channel: channel, text: text})
  end
end

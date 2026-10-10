defmodule Bee.Output do
  @moduledoc """
  What extensions write for the user to read, VS Code's Output: text in
  named channels (an extension's `window.createOutputChannel`, e.g. a
  language client's log), and the "Extension Host" channel – what
  extensions print, and their failures. The Output section of the bottom
  panel shows one channel at a time.

  Kept per workspace and channel, the last #{div(512_000, 1000)} kB of each (whole
  lines). Changes are broadcast on the workspace's topic (`subscribe/1`):
  `{:output, :appended, channel, text}`, `{:output, :cleared, channel}` and
  `{:output, :channels}` (one came or went).
  """
  use GenServer

  @max_bytes 512_000
  @host "Extension Host"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe(root), do: Phoenix.PubSub.subscribe(Bee.PubSub, topic(root))

  defp topic(root), do: "output:" <> root

  @doc "The channel of what extensions print and of their failures."
  def host_channel, do: @host

  @doc "Adds `text` to `channel` of workspace `root` (the channel is made on its first text)."
  def append(root, channel, text) when is_binary(root) and is_binary(channel) do
    text = to_string(text)
    if text != "", do: GenServer.cast(__MODULE__, {:append, root, channel, text})
    :ok
  end

  @doc "Adds `line` and a line break."
  def append_line(root, channel, line), do: append(root, channel, to_string(line) <> "\n")

  def clear(root, channel), do: GenServer.cast(__MODULE__, {:clear, root, channel})

  @doc "The channels of workspace `root`, by name."
  def channels(root), do: GenServer.call(__MODULE__, {:channels, root})

  @doc "The text of `channel` in workspace `root` (\"\" when there is none)."
  def get(root, channel), do: GenServer.call(__MODULE__, {:get, root, channel})

  @doc "Forgets workspace `root`'s channels (it closed)."
  def forget_workspace(root), do: GenServer.cast(__MODULE__, {:forget, root})

  ## Server: %{{root, channel} => text}

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:channels, root}, _from, s),
    do: {:reply, Enum.sort(for({{^root, channel}, _} <- s, do: channel)), s}

  def handle_call({:get, root, channel}, _from, s),
    do: {:reply, Map.get(s, {root, channel}, ""), s}

  @impl true
  def handle_cast({:append, root, channel, text}, s) do
    key = {root, channel}
    new? = not Map.has_key?(s, key)
    s = Map.put(s, key, trim(Map.get(s, key, "") <> text))
    if new?, do: broadcast(root, {:output, :channels})
    broadcast(root, {:output, :appended, channel, text})
    {:noreply, s}
  end

  def handle_cast({:clear, root, channel}, s) do
    if Map.has_key?(s, {root, channel}) do
      broadcast(root, {:output, :cleared, channel})
      {:noreply, Map.put(s, {root, channel}, "")}
    else
      {:noreply, s}
    end
  end

  def handle_cast({:forget, root}, s),
    do: {:noreply, Map.reject(s, fn {{r, _channel}, _text} -> r == root end)}

  # The end of it, from the start of a line.
  defp trim(text) when byte_size(text) <= @max_bytes, do: text

  defp trim(text) do
    tail = binary_part(text, byte_size(text) - @max_bytes, @max_bytes)

    case :binary.match(tail, "\n") do
      {index, 1} -> binary_part(tail, index + 1, byte_size(tail) - index - 1)
      :nomatch -> tail
    end
    |> valid_tail()
  end

  # Cut inside a character: without its rest.
  defp valid_tail(text) do
    if String.valid?(text) do
      text
    else
      <<_, rest::binary>> = text
      valid_tail(rest)
    end
  end

  defp broadcast(root, message), do: Phoenix.PubSub.broadcast(Bee.PubSub, topic(root), message)
end

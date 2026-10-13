defmodule HexView.EditorLive do
  @moduledoc """
  The editor: a file's bytes, a page at a time – each row its offset, 16
  bytes in hex, and the same bytes as text.

  Bee mounts it in the file's tab, once per tab, with the file's path in
  `@bee.params["path"]`. It reads the file itself: only the page shown, so
  a file of any size opens at once.
  """
  use Bee.Plugin.LiveView

  @row 16
  @page 32 * @row

  @impl true
  def mount(_params, _session, socket) do
    path = socket.assigns.bee.params["path"]
    {:ok, socket |> assign(path: path, offset: 0) |> load()}
  end

  @impl true
  def handle_event("page", %{"to" => to}, socket) do
    %{offset: offset, size: size} = socket.assigns

    offset =
      case to do
        "first" -> 0
        "previous" -> offset - @page
        "next" -> offset + @page
        "last" -> size - 1
      end

    {:noreply, socket |> assign(offset: offset) |> load()}
  end

  # An offset typed in: decimal, or hex as 0x1F.
  def handle_event("go", %{"offset" => text}, socket) do
    parsed =
      case String.trim(text) do
        "0x" <> hex -> Integer.parse(hex, 16)
        decimal -> Integer.parse(decimal)
      end

    case parsed do
      {offset, ""} -> {:noreply, socket |> assign(offset: offset) |> load()}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reload", _params, socket), do: {:noreply, load(socket)}

  # Reads the page `offset` is on.
  defp load(socket) do
    %{path: path, offset: offset} = socket.assigns

    with {:ok, %{size: size}} <- File.stat(path),
         offset = offset |> min(size - 1) |> max(0) |> then(&(&1 - rem(&1, @page))),
         {:ok, bytes} <- read(path, offset) do
      assign(socket, size: size, offset: offset, rows: rows(bytes, offset), error: nil)
    else
      {:error, reason} ->
        assign(socket, size: 0, offset: 0, rows: [], error: :file.format_error(reason))
    end
  end

  defp read(path, offset) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      result = :file.pread(file, offset, @page)
      File.close(file)

      case result do
        {:ok, bytes} -> {:ok, bytes}
        :eof -> {:ok, ""}
        error -> error
      end
    end
  end

  @doc "The rows of `bytes`, which start at `offset`: `%{offset, hex, text}`, all strings."
  def rows(bytes, offset) do
    for {row, i} <- bytes |> chunks() |> Enum.with_index() do
      %{
        offset: (offset + i * @row) |> Integer.to_string(16) |> String.pad_leading(8, "0"),
        hex: for(<<byte <- row>>, do: byte |> Integer.to_string(16) |> String.pad_leading(2, "0")),
        text: for(<<byte <- row>>, into: "", do: if(byte in 0x20..0x7E, do: <<byte>>, else: "."))
      }
    end
  end

  defp chunks(<<row::binary-size(@row), rest::binary>>), do: [row | chunks(rest)]
  defp chunks(""), do: []
  defp chunks(rest), do: [rest]

  @impl true
  def render(assigns) do
    assigns = assign(assigns, last: min(assigns.offset + unquote(@page), assigns.size))

    ~H"""
    <div class="hex-view" data-hex-view={@path}>
      <header class="hex-view-bar">
        <span class="hex-view-name">{Path.basename(@path)}</span>
        <span :if={!@error} data-hex-range>
          bytes {@offset}–{max(@last - 1, 0)} of {@size}
        </span>
        <span class="hex-view-grow"></span>
        <button type="button" phx-click="page" phx-value-to="first" disabled={@offset == 0}>
          First
        </button>
        <button type="button" phx-click="page" phx-value-to="previous" disabled={@offset == 0}>
          Previous
        </button>
        <button type="button" phx-click="page" phx-value-to="next" disabled={@last >= @size}>
          Next
        </button>
        <button type="button" phx-click="page" phx-value-to="last" disabled={@last >= @size}>
          Last
        </button>
        <form phx-submit="go">
          <input name="offset" placeholder="Go to offset (0x…)" autocomplete="off" />
        </form>
        <button type="button" phx-click="reload">Reload</button>
      </header>
      <p :if={@error} class="hex-view-note">Can't read the file: {@error}</p>
      <p :if={!@error and @rows == []} class="hex-view-note">The file is empty.</p>
      <table :if={@rows != []}>
        <tr :for={row <- @rows}>
          <th>{row.offset}</th>
          <td class="hex-view-bytes">{Enum.join(row.hex, " ")}</td>
          <td class="hex-view-text">{row.text}</td>
        </tr>
      </table>
    </div>
    """
  end
end

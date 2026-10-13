defmodule BeeWeb.MediaController do
  @moduledoc """
  Serves a file an editor shows as it is – an image, audio, video
  (`BeeWeb.Workbench.MediaPreview`) – to the page:

      GET /media/:token/:name

  `token` names the file: signed by the window that opened it (`url/1`),
  so the page can ask for the files Bee showed it and no others – a path
  is never taken from the request. (`name`, the file's, is only there for
  the address to end like the file.)

  The file isn't Bee's own: every answer is sandboxed and its type not
  guessed, so one opened on its own (an SVG, a page called `.png`) runs no
  script as Bee. Parts of it are served when asked for (`Range`): players
  seek in a file that way.
  """
  use BeeWeb, :controller

  @salt "media"

  @doc "The address of the file at `path` (absolute), for Bee's page."
  def url(path) do
    token = Phoenix.Token.sign(BeeWeb.Endpoint, @salt, path)
    "/media/#{token}/#{URI.encode(Path.basename(path), &URI.char_unreserved?/1)}"
  end

  def show(conn, %{"token" => token}) do
    # (No age: the address is good for as long as its tab is open.)
    with {:ok, path} when is_binary(path) <-
           Phoenix.Token.verify(BeeWeb.Endpoint, @salt, token, max_age: :infinity),
         {:ok, %{type: :regular, size: size}} <- File.stat(path) do
      conn
      |> put_resp_content_type(MIME.from_path(path), nil)
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "content-security-policy",
        "sandbox; default-src 'none'; style-src 'unsafe-inline'"
      )
      |> send_range(path, size, get_req_header(conn, "range"))
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  defp send_range(conn, path, size, [range]) do
    case range(range, size) do
      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :whole ->
        send_file(conn, 200, path)

      :error ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  defp send_range(conn, path, _size, _none), do: send_file(conn, 200, path)

  # The bytes a `Range` header asks for, of `size`: `{first, last}`;
  # `:whole` for what isn't one range of bytes.
  defp range("bytes=" <> spec, size) do
    case Regex.run(~r/^(\d*)-(\d*)$/, String.trim(spec), capture: :all_but_first) do
      ["", ""] ->
        :whole

      # The last n bytes.
      ["", n] ->
        clamp(size - min(String.to_integer(n), size), size - 1, size)

      [first, ""] ->
        clamp(String.to_integer(first), size - 1, size)

      [first, last] ->
        clamp(String.to_integer(first), min(String.to_integer(last), size - 1), size)

      nil ->
        :whole
    end
  end

  defp range(_other, _size), do: :whole

  defp clamp(first, last, size) when first <= last and first < size, do: {first, last}
  defp clamp(_first, _last, _size), do: :error
end

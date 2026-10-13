defmodule BeeWeb.MediaControllerTest do
  # Files shown as they are (images, audio, video): served by a signed address.
  use BeeWeb.ConnCase, async: true

  alias BeeWeb.MediaController

  setup do
    dir = Path.join(System.tmp_dir!(), "bee_media_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "a b.png")
    File.write!(path, "0123456789")
    %{dir: dir, path: path}
  end

  test "serves the file its address names, as what its name says", %{conn: conn, path: path} do
    url = MediaController.url(path)
    assert String.ends_with?(url, "/a%20b.png")

    conn = get(conn, url <> "?v=1")
    assert response(conn, 200) == "0123456789"
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    # Opened on its own it runs nothing as Bee.
    assert ["sandbox;" <> _] = get_resp_header(conn, "content-security-policy")
  end

  test "an address Bee didn't make names nothing", %{conn: conn, path: path} do
    assert response(get(conn, "/media/nonsense/a.png"), 404)

    forged = Phoenix.Token.sign(BeeWeb.Endpoint, "other", path)
    assert response(get(conn, "/media/#{forged}/a.png"), 404)
  end

  test "a file that is gone, or a folder: not found", %{conn: conn, dir: dir} do
    assert response(get(conn, MediaController.url(Path.join(dir, "missing.png"))), 404)
    assert response(get(conn, MediaController.url(dir)), 404)
  end

  test "serves the part of the file asked for", %{conn: conn, path: path} do
    part = fn range ->
      conn |> put_req_header("range", range) |> get(MediaController.url(path))
    end

    conn = part.("bytes=2-5")
    assert response(conn, 206) == "2345"
    assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]

    conn = part.("bytes=7-")
    assert response(conn, 206) == "789"
    assert get_resp_header(conn, "content-range") == ["bytes 7-9/10"]

    conn = part.("bytes=-3")
    assert response(conn, 206) == "789"

    # Past the end: as much as there is.
    conn = part.("bytes=8-100")
    assert response(conn, 206) == "89"

    conn = part.("bytes=20-30")
    assert response(conn, 416)
    assert get_resp_header(conn, "content-range") == ["bytes */10"]

    # What isn't one range of bytes: the whole file.
    assert response(part.("bytes=0-1,4-5"), 200) == "0123456789"
    assert response(part.("lines=1-2"), 200) == "0123456789"
  end
end

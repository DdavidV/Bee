defmodule BeeWeb.Plugs.CheckHost do
  @moduledoc """
  Refuses requests whose `Host` isn't a local name (`Bee.Access.allowed_hosts/0`):
  a page on some domain pointed at 127.0.0.1 (DNS rebinding) can't talk to Bee.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Bee.Access.allowed_hosts() do
      :any ->
        conn

      hosts ->
        if conn.host in hosts do
          conn
        else
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(403, "Bee only answers to localhost.\n")
          |> halt()
        end
    end
  end
end

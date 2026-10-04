defmodule BeeWeb.PageController do
  use BeeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

defmodule CodeLeadWeb.PageController do
  use CodeLeadWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

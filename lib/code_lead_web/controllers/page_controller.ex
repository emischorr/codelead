defmodule CodeLeadWeb.PageController do
  use CodeLeadWeb, :controller

  alias CodeLead.Projects

  def home(conn, _params) do
    case Projects.list_projects() do
      [project | _rest] ->
        redirect(conn, to: ~p"/projects/#{project.id}/board")

      [] ->
        conn
        |> assign(:page_title, "Welcome")
        |> render(:home)
    end
  end
end

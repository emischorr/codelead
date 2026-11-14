defmodule FrontSeatWeb.Api.ProjectController do
  @moduledoc """
  `GET /api/v1/projects` — the projects the caller can view.
  """

  use FrontSeatWeb, :controller

  alias FrontSeat.Projects

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(%{assigns: %{current_scope: scope}} = conn, _params) do
    projects = Projects.list_projects(scope)
    json(conn, %{data: Enum.map(projects, &%{id: &1.id, name: &1.name})})
  end
end

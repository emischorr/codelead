defmodule FrontSeatWeb.Api.TaskController do
  @moduledoc """
  `GET` and `POST /api/v1/projects/:project_id/tasks`.

  Thin on purpose: it parses the request and calls the same `Tasks`
  functions the board does, with the token's `Scope` — authorization and
  provenance live in the context. A created task lands exactly where a
  board-created one does (Planning, idle); nothing here starts,
  schedules or transitions anything.
  """

  use FrontSeatWeb, :controller

  alias FrontSeat.Accounts
  alias FrontSeat.Projects
  alias FrontSeat.Tasks

  action_fallback FrontSeatWeb.Api.FallbackController

  @list_states ~w(planning running review done)
  # What an API client may set. Everything else is decided on the board.
  @create_fields ~w(title description work_type)
  @default_work_type "code"

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def index(%{assigns: %{current_scope: scope}} = conn, %{"project_id" => project_id} = params) do
    with {:ok, project_id} <- parse_id(project_id),
         {:ok, project} <- Projects.fetch_project(scope, project_id),
         {:ok, state} <- parse_state(params["state"]),
         {:ok, tasks} <- Tasks.list_tasks(scope, project.id, state: state) do
      usernames = tasks |> Enum.map(& &1.created_by_id) |> Enum.reject(&is_nil/1)
      usernames = Accounts.usernames(usernames)
      json(conn, %{data: Enum.map(tasks, &task_json(&1, usernames))})
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t() | {:error, term()}
  def create(%{assigns: %{current_scope: scope}} = conn, %{"project_id" => project_id} = params) do
    attrs =
      params
      |> Map.take(@create_fields)
      |> Map.put_new("work_type", @default_work_type)

    with {:ok, project_id} <- parse_id(project_id),
         {:ok, project} <- Projects.fetch_project(scope, project_id),
         {:ok, task} <- Tasks.create_task(scope, project.id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: task_json(task, %{scope.user.id => scope.user.username})})
    end
  end

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp parse_state(nil), do: {:ok, nil}
  defp parse_state(""), do: {:ok, nil}
  defp parse_state(state) when state in @list_states, do: {:ok, String.to_existing_atom(state)}

  defp parse_state(_state),
    do:
      {:error, {:invalid_params, %{state: ["must be one of: #{Enum.join(@list_states, ", ")}"]}}}

  defp task_json(task, usernames) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      state: task.state,
      creator: creator_json(task.created_by_id, usernames),
      inserted_at: task.inserted_at,
      updated_at: task.updated_at,
      url: url(~p"/projects/#{task.project_id}/tasks/#{task.id}")
    }
  end

  defp creator_json(nil, _usernames), do: nil

  defp creator_json(user_id, usernames) do
    %{id: user_id, username: Map.get(usernames, user_id)}
  end
end

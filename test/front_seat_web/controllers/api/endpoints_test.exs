defmodule FrontSeatWeb.Api.EndpointsTest do
  @moduledoc """
  The four `/api/v1` endpoints across the roles that matter: a non-member,
  each project role, and an admin.
  """

  use FrontSeatWeb.ConnCase, async: true

  import FrontSeat.AccountsFixtures
  import FrontSeat.ProjectsFixtures
  import FrontSeat.TasksFixtures

  alias FrontSeat.Repo
  alias FrontSeat.Tasks
  alias FrontSeat.Tasks.Task

  setup do
    project = project_fixture()
    other_project = project_fixture()
    %{project: project, other_project: other_project}
  end

  describe "GET /api/v1/me" do
    test "reports an admin's instance role", %{conn: conn} do
      {conn, user} = as(conn, admin_fixture())
      body = conn |> get(~p"/api/v1/me") |> json_response(200)
      assert body["data"] == %{"id" => user.id, "username" => user.username, "role" => "admin"}
    end
  end

  describe "GET /api/v1/projects" do
    test "lists only the caller's projects", %{conn: conn, project: project} do
      {conn, _user} = as_member(conn, project, :reporter)
      body = conn |> get(~p"/api/v1/projects") |> json_response(200)
      assert body["data"] == [%{"id" => project.id, "name" => project.name}]
    end

    test "a non-member sees no projects", %{conn: conn} do
      {conn, _user} = as(conn, user_fixture())
      assert conn |> get(~p"/api/v1/projects") |> json_response(200) == %{"data" => []}
    end

    test "an admin sees every project", %{conn: conn, project: project, other_project: other} do
      {conn, _user} = as(conn, admin_fixture())
      ids = conn |> get(~p"/api/v1/projects") |> json_response(200) |> data_ids()
      assert project.id in ids and other.id in ids
    end
  end

  describe "GET /api/v1/projects/:project_id/tasks" do
    setup %{project: project} do
      planning = task_fixture(project.id, %{title: "Planned"})
      review = task_fixture(project.id, %{title: "In review"})
      Repo.update!(Ecto.Changeset.change(review, state: :review))
      archived = task_fixture(project.id, %{title: "Archived"})
      Repo.update!(Ecto.Changeset.change(archived, archived_at: DateTime.utc_now(:second)))
      cancelled = task_fixture(project.id, %{title: "Cancelled"})
      Repo.update!(Ecto.Changeset.change(cancelled, state: :cancelled))

      %{planning: planning, review: review, archived: archived}
    end

    for role <- [:reporter, :member, :maintainer] do
      test "a #{role} lists active tasks, without archived or cancelled ones", ctx do
        {conn, _user} = as_member(ctx.conn, ctx.project, unquote(role))
        body = conn |> get(~p"/api/v1/projects/#{ctx.project.id}/tasks") |> json_response(200)
        assert Enum.sort(data_ids(body)) == Enum.sort([ctx.planning.id, ctx.review.id])
      end
    end

    test "renders the task shape with an absolute url", ctx do
      {conn, _user} = as_member(ctx.conn, ctx.project, :reporter)

      body =
        conn
        |> get(~p"/api/v1/projects/#{ctx.project.id}/tasks?state=planning")
        |> json_response(200)

      assert [task] = body["data"]
      assert task["id"] == ctx.planning.id
      assert task["state"] == "planning"
      assert task["creator"] == nil
      assert task["url"] == url(~p"/projects/#{ctx.project.id}/tasks/#{ctx.planning.id}")
      assert String.starts_with?(task["url"], "http")

      assert Map.keys(task) |> Enum.sort() ==
               ~w(creator description id inserted_at state title updated_at url)
    end

    test "filters by state", ctx do
      {conn, _user} = as_member(ctx.conn, ctx.project, :member)

      body =
        conn
        |> get(~p"/api/v1/projects/#{ctx.project.id}/tasks?state=review")
        |> json_response(200)

      assert data_ids(body) == [ctx.review.id]
    end

    test "an unknown state is a 422", ctx do
      {conn, _user} = as_member(ctx.conn, ctx.project, :member)

      body =
        conn
        |> get(~p"/api/v1/projects/#{ctx.project.id}/tasks?state=bogus")
        |> json_response(422)

      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["fields"]["state"]
    end

    test "a non-member gets 404, same as for a project that does not exist", ctx do
      {conn, _user} = as_member(ctx.conn, ctx.other_project, :maintainer)

      for path <- [
            ~p"/api/v1/projects/#{ctx.project.id}/tasks",
            ~p"/api/v1/projects/999999/tasks",
            "/api/v1/projects/abc/tasks"
          ] do
        assert %{"error" => %{"code" => "not_found"}} = conn |> get(path) |> json_response(404)
      end
    end

    test "an admin lists any project", ctx do
      {conn, _user} = as(ctx.conn, admin_fixture())
      body = conn |> get(~p"/api/v1/projects/#{ctx.project.id}/tasks") |> json_response(200)
      assert length(body["data"]) == 2
    end
  end

  describe "POST /api/v1/projects/:project_id/tasks" do
    for role <- [:reporter, :member, :maintainer] do
      test "a #{role} creates a task in Planning attributed to them and the token", ctx do
        {conn, user} = as_member(ctx.conn, ctx.project, unquote(role))
        create_and_assert(conn, ctx.project, user)
      end
    end

    test "an admin creates a task in any project", ctx do
      {conn, user} = as(ctx.conn, admin_fixture())
      create_and_assert(conn, ctx.project, user)
    end

    test "the new task reaches open boards", ctx do
      Tasks.subscribe_board(ctx.project.id)
      {conn, _user} = as_member(ctx.conn, ctx.project, :reporter)

      body =
        conn
        |> post(~p"/api/v1/projects/#{ctx.project.id}/tasks", %{title: "Live"})
        |> json_response(201)

      task_id = body["data"]["id"]
      project_id = ctx.project.id
      assert_receive {:board_changed, ^project_id, ^task_id}
    end

    test "invalid input is a 422 with field errors and creates nothing", ctx do
      {conn, _user} = as_member(ctx.conn, ctx.project, :member)

      body =
        conn
        |> post(~p"/api/v1/projects/#{ctx.project.id}/tasks", %{
          description: "no title",
          work_type: "bogus"
        })
        |> json_response(422)

      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["fields"]["title"] == ["can't be blank"]
      assert body["error"]["fields"]["work_type"]
      assert Repo.aggregate(Task, :count) == 0
    end

    test "fields beyond title, description and work_type are ignored", ctx do
      {conn, _user} = as_member(ctx.conn, ctx.project, :member)

      body =
        conn
        |> post(~p"/api/v1/projects/#{ctx.project.id}/tasks", %{
          title: "Sneaky",
          priority: "urgent",
          execution_env: "container",
          scheduled_at: DateTime.to_iso8601(DateTime.utc_now())
        })
        |> json_response(201)

      task = Repo.get!(Task, body["data"]["id"])
      assert task.priority == :normal
      assert task.execution_env == :local
      assert task.scheduled_at == nil
    end

    test "a non-member gets 404 and nothing is created", ctx do
      {conn, _user} = as_member(ctx.conn, ctx.other_project, :maintainer)

      conn
      |> post(~p"/api/v1/projects/#{ctx.project.id}/tasks", %{title: "Nope"})
      |> json_response(404)

      assert Repo.aggregate(Task, :count) == 0
    end
  end

  defp create_and_assert(conn, project, user) do
    body =
      conn
      |> post(~p"/api/v1/projects/#{project.id}/tasks", %{
        title: "From the CLI",
        description: "Details"
      })
      |> json_response(201)

    data = body["data"]
    assert data["title"] == "From the CLI"
    assert data["description"] == "Details"
    assert data["state"] == "planning"
    assert data["creator"] == %{"id" => user.id, "username" => user.username}

    task = Repo.get!(Task, data["id"])
    assert task.project_id == project.id
    assert task.state == :planning
    assert task.run_state == :idle
    assert task.work_type == :code
    assert task.created_by_id == user.id

    assert [step] = Tasks.steps(task.id)
    assert step.kind == :created
    assert step.executor_type == :human
    assert step.user_id == user.id
    assert step.summary == "created via API token 'cli'"
    assert "api_token:" <> _ = step.executor_ref
  end

  defp as(conn, user) do
    {plaintext, _token} = api_token_fixture(user, name: "cli")
    {put_req_header(conn, "authorization", "Bearer " <> plaintext), user}
  end

  defp as_member(conn, project, role) do
    user = user_fixture()
    membership_fixture(project, user, role)
    as(conn, user)
  end

  defp data_ids(%{"data" => data}), do: Enum.map(data, & &1["id"])
end

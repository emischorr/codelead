defmodule CodeLeadWeb.ArchiveLiveTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  setup :register_and_log_in_user

  defp row_order(html) do
    ~r/id="archive-row-(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> String.to_integer(id) end)
  end

  describe "rendering" do
    test "lists archived and non-archived tasks by default", %{conn: conn} do
      project = project_fixture()
      active = task_fixture(project.id, %{title: "Active task"})
      archived = task_fixture(project.id, %{title: "Archived task"})
      put_context!(archived, archived_at: DateTime.utc_now() |> DateTime.truncate(:second))

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive")

      assert has_element?(view, "#archive-row-#{active.id}")
      assert has_element?(view, "#archive-row-#{archived.id}")
      assert render(element(view, "#archive-row-#{archived.id}")) =~ "Archived"
    end

    test "shows an empty state with no matching tasks", %{conn: conn} do
      project = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive")

      assert has_element?(view, "#archive-rows") == false
      assert render(view) =~ "No tasks match these filters"
    end

    test "archived rows carry no action buttons", %{conn: conn} do
      project = project_fixture()
      archived = task_fixture(project.id, %{title: "Archived task"})
      put_context!(archived, archived_at: DateTime.utc_now() |> DateTime.truncate(:second))

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive")

      refute has_element?(view, "#archive-row-#{archived.id} button")
    end

    test "a row navigates to the task detail page", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Click me"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive")

      assert has_element?(
               view,
               ~s{a#archive-row-#{task.id}[href="/projects/#{project.id}/tasks/#{task.id}"]}
             )
    end
  end

  describe "filters" do
    test "work type narrows the list", %{conn: conn} do
      project = project_fixture()
      code = task_fixture(project.id, %{work_type: :code})
      task_fixture(project.id, %{work_type: :content})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive?work_type=code")

      assert has_element?(view, "#archive-row-#{code.id}")
      assert row_order(render(view)) == [code.id]
    end

    test "executor narrows the list", %{conn: conn} do
      project = project_fixture()
      agent = agent_fixture(%{roles: [:execute], work_type: :code})
      assigned = task_fixture(project.id, %{work_type: :code, agent_id: agent.id})
      task_fixture(project.id, %{work_type: :code})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive?agent_id=#{agent.id}")

      assert row_order(render(view)) == [assigned.id]
    end

    test "repository narrows the list", %{conn: conn} do
      project = project_fixture()
      repository = repository_fixture(project.id)
      other_repository = repository_fixture(project.id)

      in_repo =
        task_fixture(project.id, %{work_type: :code, repository_id: other_repository.id})

      task_fixture(project.id, %{work_type: :code, repository_id: repository.id})

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/archive?repository_id=#{other_repository.id}")

      assert row_order(render(view)) == [in_repo.id]
    end

    test "unchecking archived hides archived tasks", %{conn: conn} do
      project = project_fixture()
      active = task_fixture(project.id)
      archived = task_fixture(project.id)
      put_context!(archived, archived_at: DateTime.utc_now() |> DateTime.truncate(:second))

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive?archived=false")

      assert has_element?(view, "#archive-row-#{active.id}")
      refute has_element?(view, "#archive-row-#{archived.id}")
    end

    test "changing a filter dropdown patches the URL and reloads the list", %{conn: conn} do
      project = project_fixture()
      code = task_fixture(project.id, %{work_type: :code})
      content = task_fixture(project.id, %{work_type: :content})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive")
      assert row_order(render(view)) |> Enum.sort() == Enum.sort([code.id, content.id])

      view
      |> form("#archive-filters",
        filters: %{
          "work_type" => "code",
          "agent_id" => "",
          "repository_id" => "",
          "archived" => "true",
          "sort" => "inserted_at"
        }
      )
      |> render_change()

      assert_patch(
        view,
        ~p"/projects/#{project.id}/archive?#{%{work_type: "code", agent_id: "", repository_id: "", archived: "true", sort: "inserted_at", dir: "desc"}}"
      )

      assert row_order(render(view)) == [code.id]
    end

    test "a filter change preserves a non-default sort direction", %{conn: conn} do
      project = project_fixture()
      code = task_fixture(project.id, %{work_type: :code})
      task_fixture(project.id, %{work_type: :content})

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/archive?sort=inserted_at&dir=asc")

      view
      |> form("#archive-filters",
        filters: %{
          "work_type" => "code",
          "agent_id" => "",
          "repository_id" => "",
          "archived" => "true",
          "sort" => "inserted_at"
        }
      )
      |> render_change()

      assert_patch(
        view,
        ~p"/projects/#{project.id}/archive?#{%{work_type: "code", agent_id: "", repository_id: "", archived: "true", sort: "inserted_at", dir: "asc"}}"
      )

      assert has_element?(view, ~s{#archive-sort-dir[title="Ascending"]})
      assert row_order(render(view)) == [code.id]
    end
  end

  describe "sorting" do
    test "by task id", %{conn: conn} do
      project = project_fixture()
      first = task_fixture(project.id)
      second = task_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive?sort=id&dir=asc")
      assert row_order(render(view)) == [first.id, second.id]

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive?sort=id&dir=desc")
      assert row_order(render(view)) == [second.id, first.id]
    end

    test "by priority rank", %{conn: conn} do
      project = project_fixture()
      low = task_fixture(project.id, %{priority: :low})
      urgent = task_fixture(project.id, %{priority: :urgent})
      normal = task_fixture(project.id, %{priority: :normal})
      high = task_fixture(project.id, %{priority: :high})

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/archive?sort=priority&dir=desc")

      assert row_order(render(view)) == [urgent.id, high.id, normal.id, low.id]
    end

    test "by created at", %{conn: conn} do
      project = project_fixture()
      older = task_fixture(project.id)
      put_context!(older, inserted_at: ~U[2026-01-01 00:00:00Z])
      newer = task_fixture(project.id)
      put_context!(newer, inserted_at: ~U[2026-02-01 00:00:00Z])

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/archive?sort=inserted_at&dir=asc")

      assert row_order(render(view)) == [older.id, newer.id]
    end

    test "by done at, undone tasks sink to the bottom", %{conn: conn} do
      project = project_fixture()
      undone = task_fixture(project.id)
      done = task_fixture(project.id)
      put_context!(done, completed_at: ~U[2026-01-01 00:00:00Z])

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/archive?sort=completed_at&dir=desc")

      assert row_order(render(view)) == [done.id, undone.id]
    end

    test "the direction toggle button flips the arrow and the order", %{conn: conn} do
      project = project_fixture()
      first = task_fixture(project.id)
      second = task_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/archive?sort=id&dir=asc")
      assert row_order(render(view)) == [first.id, second.id]

      view |> element("#archive-sort-dir") |> render_click()

      assert_patch(
        view,
        ~p"/projects/#{project.id}/archive?#{%{work_type: "", agent_id: "", repository_id: "", archived: "true", sort: "id", dir: "desc"}}"
      )

      assert row_order(render(view)) == [second.id, first.id]
    end
  end
end

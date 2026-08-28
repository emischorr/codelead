defmodule CodeLeadWeb.TaskLiveTest do
  use CodeLeadWeb.ConnCase, async: true

  # Requeue actions kick the real scheduler, whose TaskRunner exits on
  # the DB sandbox outside this test's ownership — expected noise.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.AgentFeed
  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Findings.Finding
  alias CodeLead.Repo
  alias CodeLead.Tasks
  alias CodeLeadWeb.DiffComponents

  setup :register_and_log_in_user

  defp task_path(project, task, tab \\ nil) do
    base = ~p"/projects/#{project.id}/tasks/#{task.id}"
    if tab, do: "#{base}?tab=#{tab}", else: base
  end

  # What the `.SchedulePicker` hook posts as `local_at`: minute precision,
  # naive (paired with `utc_offset_minutes` for the actual conversion). The
  # time is on the minute so the round trip is lossless.
  defp input_value(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%dT%H:%M")

  defp in_an_hour do
    at = DateTime.add(DateTime.utc_now(:second), 3600)
    %{at | second: 0}
  end

  describe "tab defaulting" do
    test "planning tasks open on the Task tab", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))
      assert has_element?(view, "#description-card")
    end

    test "review tasks open on the Diff tab", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :review})

      {:ok, view, _html} = live(conn, task_path(project, task))
      refute has_element?(view, "#description-card")
      assert render(view) =~ "Nothing to show yet"
    end

    test "an explicit tab param wins", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :review})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))
      assert has_element?(view, "#description-card")
    end

    test "tab links patch between tabs", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("nav a", "Terminal") |> render_click()
      assert_patch(view, task_path(project, task, "terminal"))
      assert render(view) =~ "worktree is provisioned"
    end
  end

  describe "back to board link" do
    test "defaults to the plain board URL when arriving without a column", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      assert has_element?(
               view,
               ~s(a[aria-label="Back to board"][href="#{~p"/projects/#{project.id}/board"}"])
             )
    end

    test "carries the originating mobile column back to the board", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/tasks/#{task.id}?column=running")

      assert has_element?(
               view,
               ~s(a[aria-label="Back to board"][href="#{~p"/projects/#{project.id}/board?column=running"}"])
             )
    end

    test "keeps the column after switching tabs, which don't carry it", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/tasks/#{task.id}?column=review")

      view |> element("nav a", "Terminal") |> render_click()

      assert has_element?(
               view,
               ~s(a[aria-label="Back to board"][href="#{~p"/projects/#{project.id}/board?column=review"}"])
             )
    end
  end

  describe "start/schedule guard" do
    test "a task without an executor keeps Start/Schedule visible but disabled", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{agent_id: nil})

      {:ok, view, _html} = live(conn, task_path(project, task))

      assert has_element?(view, "#action-start-run[disabled]")
      assert has_element?(view, "#action-schedule-run[disabled]")
      assert render(element(view, "#action-start-run")) =~ "Select an executor agent"
    end

    test "a repo-target task without a repository keeps Start/Schedule disabled", %{conn: conn} do
      project = project_fixture()
      executor = agent_fixture(%{roles: [:execute], work_type: :code})

      task =
        task_fixture(project.id, %{target: :repo, repository_id: nil, agent_id: executor.id})

      {:ok, view, _html} = live(conn, task_path(project, task))

      assert has_element?(view, "#action-start-run[disabled]")
      assert render(element(view, "#action-start-run")) =~ "Link a repository"
    end

    test "a runnable task offers Start/Schedule enabled", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()

      {:ok, view, _html} = live(conn, task_path(project, task))

      refute has_element?(view, "#action-start-run[disabled]")
      refute has_element?(view, "#action-schedule-run[disabled]")
    end
  end

  describe "planning edits" do
    test "saving the edit form updates description and spec", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#toggle-edit") |> render_click()

      view
      |> form("#task-edit-form",
        task: %{description: "New description", spec: "New acceptance criteria"}
      )
      |> render_submit()

      assert render(view) =~ "New description"
      assert render(view) =~ "New acceptance criteria"
    end

    test "saving closes edit mode, cancelling discards the changes", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{description: "Original"})

      {:ok, view, _html} = live(conn, task_path(project, task))

      refute has_element?(view, "#task-edit-form")
      view |> element("#toggle-edit") |> render_click()
      assert has_element?(view, "#task-edit-form")
      refute has_element?(view, "#task-description-view")

      view |> form("#task-edit-form", task: %{description: "Saved"}) |> render_submit()

      refute has_element?(view, "#task-edit-form")
      assert has_element?(view, "#task-description-view")

      view |> element("#toggle-edit") |> render_click()
      view |> form("#task-edit-form", task: %{description: "Abandoned"}) |> render_change()
      view |> element("#cancel-edit") |> render_click()

      refute has_element?(view, "#task-edit-form")
      assert render(view) =~ "Saved"
      assert Tasks.get_task!(task.id).description == "Saved"
    end

    test "the edit form changes the work type", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#toggle-edit") |> render_click()
      view |> form("#task-edit-form", task: %{work_type: "content"}) |> render_submit()

      assert Tasks.get_task!(task.id).work_type == :content
    end

    test "the target form changes target and repository", %{conn: conn} do
      project = project_fixture()
      repository = repository_fixture(project.id)
      task = task_fixture(project.id, %{work_type: :content, target: :folder})

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#target-form") |> render_change(%{"target" => "repo"})

      # A repo target with no repository falls back to the project's first.
      assert %{target: :repo, repository_id: repository_id} = Tasks.get_task!(task.id)
      assert repository_id == repository.id

      other = repository_fixture(project.id)

      view
      |> element("#target-form")
      |> render_change(%{"target" => "repo", "repository_id" => to_string(other.id)})

      assert Tasks.get_task!(task.id).repository_id == other.id
    end

    test "the target box is read-only outside planning", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :review})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert has_element?(view, "#target-card")
      refute has_element?(view, "#target-form")
    end

    test "the target form changes the execution environment", %{conn: conn} do
      project = project_fixture()
      repository = repository_fixture(project.id)

      task =
        task_fixture(project.id, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id
        })

      {:ok, view, _html} = live(conn, task_path(project, task))

      view
      |> element("#target-form")
      |> render_change(%{"target" => "repo", "execution_env" => "container"})

      assert Tasks.get_task!(task.id).execution_env == :container
    end

    test "the execution select is absent for folder targets", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content, target: :folder})

      {:ok, view, _html} = live(conn, task_path(project, task))

      refute has_element?(view, "#target-form select[name=execution_env]")
    end

    test "selecting an executor persists it", %{conn: conn} do
      project = project_fixture()
      executor = agent_fixture(%{roles: [:execute], work_type: :code})
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view
      |> element("#executor-form")
      |> render_change(%{"agent_id" => to_string(executor.id)})

      assert Tasks.get_task!(task.id).agent_id == executor.id
    end

    test "selecting reviewers persists them", %{conn: conn} do
      project = project_fixture()
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view
      |> element("#reviewers-form")
      |> render_change(%{"reviewer_ids" => [to_string(reviewer.id)]})

      assert [%{id: reviewer_id}] = Tasks.reviewers(task.id)
      assert reviewer_id == reviewer.id
    end
  end

  describe "delete" do
    test "the delete link is planning-only", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))
      assert has_element?(view, "#delete-task")

      task = put_context!(task, %{state: :review})
      {:ok, view, _html} = live(conn, task_path(project, task, "task"))
      refute has_element?(view, "#delete-task")
    end

    test "deleting removes the task and returns to the board", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#delete-task") |> render_click()

      assert_redirect(view, ~p"/projects/#{project.id}/board")
      refute Tasks.get_task(task.id)
    end
  end

  describe "planning agent selection" do
    test "both planner levels offer the same run button, labelled by level", %{conn: conn} do
      project = project_fixture()
      coach = agent_fixture(%{roles: [:plan], work_type: :code, driver: :llm_api})

      surveyor =
        agent_fixture(%{
          roles: [:plan],
          work_type: :code,
          driver: :acp,
          harness: :claude_code,
          name: "Surveyor #{System.unique_integer([:positive])}"
        })

      # no repository: the task-level run works, the repo-level one can't
      task = task_fixture(project.id, %{target: :folder})

      {:ok, view, _html} = live(conn, task_path(project, task))

      assert view |> element("#planner-form") |> render() =~ "· Task level"
      assert view |> element("#planner-form") |> render() =~ "· Repo level"

      view |> element("#planner-form") |> render_change(%{"agent_id" => to_string(coach.id)})
      refute has_element?(view, "#run-refinement[disabled]")
      assert view |> element("#run-refinement") |> render() =~ "Run agent refinement"

      view |> element("#planner-form") |> render_change(%{"agent_id" => to_string(surveyor.id)})
      assert has_element?(view, "#run-refinement[disabled]")
      assert view |> element("#run-refinement") |> render() =~ "Link a repository first"
    end

    test "there is no chat interface", %{conn: conn} do
      project = project_fixture()
      _coach = agent_fixture(%{roles: [:plan], work_type: :code, driver: :llm_api})
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task))

      refute has_element?(view, "#chat-form")
      refute has_element?(view, "#chat-messages")
    end

    test "no planner for the work type disables the run", %{conn: conn} do
      project = project_fixture()
      _content_planner = agent_fixture(%{roles: [:plan], work_type: :content})
      task = task_fixture(project.id, %{work_type: :code})

      {:ok, view, _html} = live(conn, task_path(project, task))

      assert has_element?(view, "#planner-form")
      assert render(view) =~ "No planning agents for this work type"
      assert has_element?(view, "#run-refinement[disabled]")
    end

    test "a completed survey renders as a labelled turn", %{conn: conn} do
      project = project_fixture()
      repository = repository_fixture(project.id)

      surveyor =
        agent_fixture(%{
          roles: [:plan],
          work_type: :code,
          driver: :acp,
          harness: :claude_code
        })

      task = task_fixture(project.id, %{target: :repo, repository_id: repository.id})

      {:ok, view, _html} = live(conn, task_path(project, task))

      CodeLead.Repo.insert!(%CodeLead.Planning.PlanningMessage{
        task_id: task.id,
        agent_id: surveyor.id,
        role: :assistant,
        kind: :survey,
        content: "Gap: the spec never says what happens on payment failure."
      })

      send(
        view.pid,
        {:task_event, task.id, {:survey_completed, %{agent: surveyor.name, status: :ok}}}
      )

      html = render(view)
      assert html =~ "payment failure"
      assert html =~ "Repo survey"
      assert html =~ surveyor.name
    end
  end

  describe "findings" do
    defp finding_fixture(task, attrs \\ %{}) do
      Repo.insert!(
        struct!(
          %Finding{
            task_id: task.id,
            phase: :planning,
            severity: :high,
            title: "Retry policy",
            observed: :open
          },
          attrs
        )
      )
    end

    test "resolving a finding propagates to another connected session", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      finding = finding_fixture(task)

      {:ok, view_a, _html} = live(conn, task_path(project, task))
      {:ok, view_b, _html} = live(conn, task_path(project, task))

      view_a |> element("#finding-check-#{finding.id}") |> render_click()

      view_a
      |> form("#finding-note-form-#{finding.id}", %{note: "retry 3x, then hold"})
      |> render_submit()

      html_b = render(view_b)
      assert html_b =~ "retry 3x, then hold"
      assert has_element?(view_b, ~s(#finding-check-#{finding.id}[aria-checked="true"]))
    end

    test "saving a resolution collapses the finding row", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      finding = finding_fixture(task)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#finding-check-#{finding.id}") |> render_click()
      assert has_element?(view, "#finding-detail-#{finding.id}")

      view
      |> form("#finding-note-form-#{finding.id}", %{note: "retry 3x, then hold"})
      |> render_submit()

      refute has_element?(view, "#finding-detail-#{finding.id}")
    end

    test "saving with add to spec checked pre-fills the edit form and collapses the row", %{
      conn: conn
    } do
      project = project_fixture()
      task = task_fixture(project.id, %{spec: "Existing criteria."})
      finding = finding_fixture(task)

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#finding-check-#{finding.id}") |> render_click()

      view
      |> form("#finding-note-form-#{finding.id}", %{
        note: "retry 3x, then hold",
        add_to_spec: "true"
      })
      |> render_submit()

      refute has_element?(view, "#finding-detail-#{finding.id}")
      assert has_element?(view, "#task-edit-form")
      assert render(view) =~ "Existing criteria.\n- Retry policy: retry 3x, then hold"

      # nothing is written until the human saves through the normal path
      assert Tasks.get_task!(task.id).spec == "Existing criteria."
    end

    test "add to spec pre-fills the edit form without changing the task", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{spec: "Existing criteria."})

      finding =
        finding_fixture(task, %{
          resolution: :addressed,
          resolution_note: "retry 3x, then hold",
          resolved_at: DateTime.utc_now(:second)
        })

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#finding-toggle-#{finding.id}") |> render_click()
      view |> element("#finding-add-to-spec-#{finding.id}") |> render_click()

      assert has_element?(view, "#task-edit-form")
      assert render(view) =~ "Existing criteria.\n- Retry policy: retry 3x, then hold"

      # nothing is written until the human saves through the normal path
      assert Tasks.get_task!(task.id).spec == "Existing criteria."
    end

    test "outside Planning the findings render read-only", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :review})
      finding = finding_fixture(task)

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert has_element?(view, "#planning-card")
      assert has_element?(view, "#finding-#{finding.id}")
      refute has_element?(view, "#finding-check-#{finding.id}")

      view |> element("#finding-toggle-#{finding.id}") |> render_click()
      refute has_element?(view, "#finding-address-#{finding.id}")
      refute has_element?(view, "#finding-dismiss-#{finding.id}")
    end

    test "the run counter appears from the second survey on", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      finding_fixture(task)
      Tasks.record_step(task.id, :plan, :agent, "Surveyor", "repo survey: ok")

      {:ok, view, _html} = live(conn, task_path(project, task))
      refute has_element?(view, "#findings-run-count")

      Tasks.record_step(task.id, :plan, :agent, "Surveyor", "repo survey: ok")

      send(
        view.pid,
        {:task_event, task.id, {:survey_completed, %{agent: "Surveyor", status: :ok}}}
      )

      assert view |> element("#findings-run-count") |> render() =~ "run 2"
    end

    test "an unparseable survey shows the hint and the raw report", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      Repo.insert!(%CodeLead.Planning.PlanningMessage{
        task_id: task.id,
        role: :assistant,
        kind: :survey,
        content: "Gap: the spec never says what happens on payment failure."
      })

      {:ok, view, _html} = live(conn, task_path(project, task))

      assert has_element?(view, "#findings-parse-hint")
      assert view |> element("#findings-raw-report") |> render() =~ "payment failure"
    end

    test "addressing requires a note, dismissing does not", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      finding = finding_fixture(task)
      other = finding_fixture(task, %{title: "Cache invalidation"})

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#finding-check-#{finding.id}") |> render_click()

      # Save stays disabled until a note is typed, and a blank submit writes nothing
      assert has_element?(view, "#finding-note-form-#{finding.id} button[type=submit][disabled]")
      view |> form("#finding-note-form-#{finding.id}", %{note: "   "}) |> render_submit()
      assert Repo.get!(Finding, finding.id).resolution == nil

      view |> form("#finding-note-form-#{finding.id}", %{note: "retry 3x"}) |> render_change()
      refute has_element?(view, "#finding-note-form-#{finding.id} button[type=submit][disabled]")

      # a dismissal needs no note, and its input says so
      view |> element("#finding-toggle-#{other.id}") |> render_click()
      view |> element("#finding-dismiss-#{other.id}") |> render_click()

      assert view |> element("#finding-note-#{other.id}") |> render() =~
               "(Optional) Why is this out of scope?"

      view |> form("#finding-note-form-#{other.id}", %{note: ""}) |> render_submit()
      assert Repo.get!(Finding, other.id).resolution == :dismissed
    end

    test "the still-flags marker waits for a run after the resolution", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      step = Tasks.record_step(task.id, :plan, :agent, "Surveyor", "repo survey: ok")
      finding = finding_fixture(task, %{last_seen_step_id: step.id})

      {:ok, view, _html} = live(conn, task_path(project, task))

      view |> element("#finding-check-#{finding.id}") |> render_click()

      view
      |> form("#finding-note-form-#{finding.id}", %{note: "retry 3x, then hold"})
      |> render_submit()

      refute render(view) =~ "agent still flags this"

      # a later run that still lists the finding as open raises the marker
      finding
      |> Ecto.Changeset.change(resolved_at: DateTime.add(DateTime.utc_now(:second), -60, :second))
      |> Repo.update!()

      later = Tasks.record_step(task.id, :plan, :agent, "Surveyor", "repo survey: ok")
      finding |> Ecto.Changeset.change(last_seen_step_id: later.id) |> Repo.update!()

      send(
        view.pid,
        {:task_event, task.id, {:survey_completed, %{agent: "Surveyor", status: :ok}}}
      )

      assert render(view) =~ "agent still flags this"
    end

    test "the timeline shows survey steps as refinement", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      step = Tasks.record_step(task.id, :plan, :agent, "Surveyor", "repo survey: ok")

      {:ok, view, _html} = live(conn, task_path(project, task))

      assert view |> element("#timeline-step-#{step.id}") |> render() =~ "Refinement completed"
      refute render(view) =~ "repo survey: ok"
    end

    test "the decisions block appears on the task card once a noted resolution exists", %{
      conn: conn
    } do
      project = project_fixture()
      task = task_fixture(project.id)

      finding_fixture(task, %{
        resolution: :addressed,
        resolution_note: "retry 3x, then hold",
        resolved_at: DateTime.utc_now(:second)
      })

      {:ok, view, _html} = live(conn, task_path(project, task))

      assert view |> element("#task-decisions") |> render() =~ "retry 3x, then hold"
      assert view |> element("#task-decisions") |> render() =~ "Included in the agent"
    end
  end

  describe "scheduled runs" do
    test "scheduling from the task page queues the run", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()
      at = in_an_hour()

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      view |> element("#action-schedule-run") |> render_click()

      view
      |> form("#schedule-form")
      |> render_submit(%{schedule: %{local_at: input_value(at), utc_offset_minutes: "0"}})

      task = Tasks.get_task!(task.id)
      assert task.state == :running
      assert task.run_state == :queued
      assert task.scheduled_at == at
    end

    test "a queued scheduled task offers Run now, which clears the schedule", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()

      task =
        put_context!(task, %{
          state: :running,
          run_state: :queued,
          scheduled_at: in_an_hour()
        })

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert has_element?(view, "#scheduled-hint")
      assert has_element?(view, "#action-run-now")

      view |> element("#action-run-now") |> render_click()

      assert Tasks.get_task!(task.id).scheduled_at == nil
      refute has_element?(view, "#action-run-now")
    end

    test "a queued task with no schedule offers no Run now", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()
      task = put_context!(task, %{state: :running, run_state: :queued})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      refute has_element?(view, "#action-run-now")
      refute has_element?(view, "#scheduled-hint")
    end
  end

  describe "review actions" do
    test "request changes sends the task back to running with the feedback", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()
      task = task |> executing_task() |> put_context!(%{state: :review, run_state: :idle})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      view |> element("#action-request-changes") |> render_click()

      view
      |> form("#feedback-form", %{feedback: "Tighten the lock scope"})
      |> render_submit()

      task = Tasks.get_task!(task.id)
      assert task.state == :running
      assert task.run_state == :queued
      assert task.next_prompt == "Tighten the lock scope"
    end

    test "send back to planning discards the execution context", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()

      # No worktree_path: a fake path would send real git teardown against
      # a repository that has no local clone.
      task =
        task
        |> executing_task()
        |> put_context!(%{state: :review, run_state: :idle, branch_name: "codelead/task-x"})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      view |> element("#action-send-back") |> render_click()

      task = Tasks.get_task!(task.id)
      assert task.state == :planning
      assert task.branch_name == nil
      assert task.acp_session_id == nil
    end
  end

  describe "finalize mode" do
    defp reviewable_repo_task do
      %{task: task, project: project} = runnable_task_fixture()
      task = task |> executing_task() |> put_context!(%{state: :review, run_state: :idle})
      %{task: task, project: project}
    end

    test "the approve button states what it will actually do", %{conn: conn} do
      %{task: task, project: project} = reviewable_repo_task()

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      # A file:// origin has no forge convention, so a PR is not on offer.
      assert render(element(view, "#action-approve")) =~ "Approve &amp; push branch"
    end

    test "the project default changes the button", %{conn: conn} do
      %{task: task, project: project} = reviewable_repo_task()
      {:ok, _project} = CodeLead.Projects.put_finalize_defaults(project, %{"repo" => "merge"})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert render(element(view, "#action-approve")) =~ "Approve &amp; merge"
    end

    test "a task override beats the project default and clears back to it", %{conn: conn} do
      %{task: task, project: project} = reviewable_repo_task()
      {:ok, _project} = CodeLead.Projects.put_finalize_defaults(project, %{"repo" => "merge"})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      view |> form("#finalize-form", %{finalize_mode: "squash"}) |> render_change()

      assert Tasks.get_task!(task.id).finalize_mode == :squash
      assert render(element(view, "#action-approve")) =~ "Approve &amp; squash merge"

      view |> form("#finalize-form", %{finalize_mode: ""}) |> render_change()

      assert Tasks.get_task!(task.id).finalize_mode == nil
      assert render(element(view, "#action-approve")) =~ "Approve &amp; merge"
    end

    test "a folder task is never offered a merge", %{conn: conn} do
      project = project_fixture()
      agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

      task =
        project.id
        |> task_fixture(%{work_type: :content, target: :folder, agent_id: agent.id})
        |> put_context!(%{state: :review, run_state: :idle})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert render(element(view, "#action-approve")) =~ "Approve &amp; hand over"

      html = render(element(view, "#finalize-form"))
      assert html =~ "commit_to_path"
      refute html =~ ~s(value="merge")
    end

    test "the selector is gone once the task is done", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :done})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      refute has_element?(view, "#finalize-form")
    end
  end

  describe "done actions" do
    test "the forge link opens the pull request in a new tab", %{conn: conn} do
      project = project_fixture()

      task =
        task_fixture(project.id)
        |> put_context!(%{
          state: :done,
          pr_url: "https://github.com/acme/site/pull/7",
          pr_url_kind: :pull_request
        })

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert has_element?(
               view,
               ~s(#action-open-pr[href="https://github.com/acme/site/pull/7"][target="_blank"])
             )

      assert render(element(view, "#action-open-pr")) =~ "PR"
      assert has_element?(view, "#action-archive")
    end

    test "a compare fallback is labelled as such", %{conn: conn} do
      project = project_fixture()

      task =
        task_fixture(project.id)
        |> put_context!(%{
          state: :done,
          pr_url: "https://github.com/acme/site/compare/main...topic",
          pr_url_kind: :compare
        })

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert render(element(view, "#action-open-pr")) =~ "Compare"
    end

    test "no link is shown when the finalizer produced none", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :done})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      refute has_element?(view, "#action-open-pr")
      assert has_element?(view, "#action-archive")
    end

    test "a merged task links its commit", %{conn: conn} do
      project = project_fixture()

      task =
        task_fixture(project.id)
        |> put_context!(%{
          state: :done,
          pr_url: "https://github.com/acme/site/commit/abc123",
          pr_url_kind: :commit
        })

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert render(element(view, "#action-open-pr")) =~ "Commit"
    end

    test "a folder task offers its artifact for download", %{conn: conn} do
      project = project_fixture()
      agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

      task =
        project.id
        |> task_fixture(%{work_type: :content, target: :folder, agent_id: agent.id})
        |> put_context!(%{state: :done})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      href = ~p"/projects/#{project.id}/tasks/#{task.id}/artifact"
      assert has_element?(view, ~s(#action-download-artifact[href="#{href}"]))
      assert has_element?(view, ~s(#task-artifact-link[href="#{href}"]))
    end

    test "a repo task explains that its worktree was pruned", %{conn: conn} do
      %{task: task, project: project} = runnable_task_fixture()

      task =
        task
        |> put_context!(%{state: :done, branch_name: "codelead/task-9", worktree_path: nil})

      {:ok, view, _html} = live(conn, task_path(project, task, "diff"))

      assert render(view) =~ "pruned when this task was finalized"
    end
  end

  describe "attention" do
    test "shows the banner with detail", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :running, run_state: :executing})
      {:ok, task} = Tasks.set_attention(task, :agent_question, "Which retention window?")

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert render(view) =~ "Agent asks"
      assert render(view) =~ "Which retention window?"

      # no ref means nothing to answer against — an advisory run raises
      # exactly this shape
      refute has_element?(view, "#banner-answer-question")
      refute has_element?(view, "#banner-skip-question")
    end

    test "a question with a ref routes the human to the form", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :running, run_state: :executing})
      {:ok, task} = Tasks.set_attention(task, :agent_question, "Which one?", ref: "80")

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert has_element?(view, "#banner-skip-question")

      view |> element("#banner-answer-question") |> render_click()

      assert_patched(view, task_path(project, task, "agent"))
    end

    test "the Agent tab headline flags attention while another tab is active", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :running, run_state: :executing})

      {:ok, view, _html} = live(conn, task_path(project, task, "diff"))

      refute has_element?(view, "#task-tab-agent.text-warn")
      refute has_element?(view, "#task-tab-agent .hero-hand-raised")

      {:ok, _task} = Tasks.set_attention(task, :agent_question, "Which one?", ref: "80")

      assert has_element?(view, "#task-tab-agent.text-warn")
      assert has_element?(view, "#task-tab-agent .hero-hand-raised")
    end

    test "review_ready attention does not flag the Agent tab", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :review})

      {:ok, _task} = Tasks.set_attention(task, :review_ready, nil)

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      refute has_element?(view, "#task-tab-agent.text-warn")
      refute has_element?(view, "#task-tab-agent .hero-hand-raised")
    end
  end

  describe "run meta" do
    test "the cost card shows each run's tokens and duration", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      agent = agent_fixture(%{name: "Judy"})

      {:ok, _run} =
        CodeLead.Costs.record_run(%{
          task_id: task.id,
          agent_id: agent.id,
          provider_id: agent.provider_id,
          status: :ok,
          started_at: DateTime.utc_now(:second),
          duration_ms: 134_000,
          usage: %{total_tokens: 183_512, cached_read_tokens: 120_000, cost_cents: 207}
        })

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert has_element?(view, "#cost-card")
      assert render(view) =~ "$2.07 · 183.5k · 2m 14s"
    end

    test "a subscription run's cost is marked as an estimate", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, provider} =
        CodeLead.Agents.create_provider(%{
          name: "Sub #{System.unique_integer([:positive])}",
          kind: :anthropic_subscription,
          config: %{"oauth_token" => "t"}
        })

      {:ok, _run} =
        CodeLead.Costs.record_run(%{
          task_id: task.id,
          provider_id: provider.id,
          status: :ok,
          started_at: DateTime.utc_now(:second),
          duration_ms: 2_500,
          usage: %{total_tokens: 340, cost_cents: 42}
        })

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert render(view) =~ "~$0.42 est"
    end

    test "mid-run usage adds to the live total without a task reload", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :running, run_state: :executing})

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      send(
        view.pid,
        {:task_event, task.id,
         {:usage, %{cost_cents: 137, context_used: 45_200, context_size: 200_000}}}
      )

      assert render(view) =~ "$1.37"
    end
  end

  describe "timeline" do
    test "a task with no steps still opens on its creation", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert has_element?(view, "#timeline-start")
      assert render(view) =~ "Nothing else has happened yet."
    end

    test "every entry carries the full timestamp for the hover tooltip", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      step = Tasks.record_step(task.id, :transition, :human, "human", "moved to Running")

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      # the server-rendered UTC title is the fallback the hook localizes
      assert has_element?(view, "#timeline-start-time[data-at]")
      assert has_element?(view, "#timeline-step-#{step.id}-time[data-at]")
      assert render(view) =~ CodeLeadWeb.Format.absolute(task.inserted_at)
    end

    test "steps follow the creation node, oldest first", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)
      first = Tasks.record_step(task.id, :transition, :human, "human", "moved to Running")
      second = Tasks.record_step(task.id, :run, :system, "system", "run started")

      {:ok, view, _html} = live(conn, task_path(project, task, "task"))

      assert has_element?(view, "#timeline-step-#{first.id}")
      assert has_element?(view, "#timeline-step-#{second.id}")
      refute render(view) =~ "Nothing else has happened yet."
    end
  end

  describe "agent feed" do
    setup %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id) |> put_context!(%{state: :running, run_state: :executing})
      %{conn: conn, project: project, task: task}
    end

    defp feed_row(task, attrs) do
      AgentFeed.record_event(task.id, Enum.into(attrs, %{kind: :message}))
    end

    defp block_id(row), do: "#agent-block-#{row.id}"

    test "history is loaded from the transcript, not the audit trail", ctx do
      %{conn: conn, project: project, task: task} = ctx
      Tasks.record_step(task.id, :transition, :human, "human", "moved to Running")
      row = feed_row(task, kind: :message, text: "Working on it.")

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      assert has_element?(view, block_id(row))
      refute render(view) =~ "moved to Running"

      # the transition is still the Task tab's business
      {:ok, task_view, _html} = live(conn, task_path(project, task, "task"))
      assert render(task_view) =~ "moved to Running"
    end

    test "the feed survives a tab switch", ctx do
      %{conn: conn, project: project, task: task} = ctx
      row = feed_row(task, kind: :message, text: "Working on it.")

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))
      assert has_element?(view, block_id(row))

      view |> element("nav a", "Task") |> render_click()
      refute has_element?(view, block_id(row))

      view |> element("nav a", "Agent") |> render_click()
      assert has_element?(view, block_id(row))
    end

    test "review events never enter the feed", ctx do
      %{conn: conn, project: project, task: task} = ctx

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      send(view.pid, {:task_event, task.id, {:review_completed, %{agent: "R", verdict: :pass}}})
      send(view.pid, {:task_event, task.id, {:review_cycle_completed, 1}})

      assert has_element?(view, "#agent-events-empty")
    end

    test "consecutive tool calls collapse into one expandable group", ctx do
      %{conn: conn, project: project, task: task} = ctx

      first =
        feed_row(task, kind: :tool_call, text: "Read README", data: %{"status" => "completed"})

      second = feed_row(task, kind: :tool_call, text: "Write lib/foo.ex")
      third = feed_row(task, kind: :tool_call, text: "Read mix.exs")

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      # one block for all three, keyed by the first row
      assert has_element?(view, block_id(first))
      refute has_element?(view, block_id(second))
      refute has_element?(view, block_id(third))
      assert has_element?(view, "#{block_id(first)} button", "3 tool calls")

      # expanded by default while the run is executing, so the members show
      assert render(view) =~ "Write lib/foo.ex"

      view |> element("#{block_id(first)}-toggle") |> render_click()
      refute render(view) =~ "Write lib/foo.ex"
    end

    test "a tool_call_update advances the call in place", ctx do
      %{conn: conn, project: project, task: task} = ctx
      row = feed_row(task, kind: :tool_call, text: "Read README", data: %{"status" => "pending"})

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      updated = AgentFeed.update_event(row, %{data: %{"status" => "completed"}})
      send(view.pid, {:agent_feed, task.id, updated})

      # still exactly one block, still the same dom id
      assert has_element?(view, block_id(row))
      assert has_element?(view, "#{block_id(row)} button", "Read README")
    end

    test "an agent message renders as markdown", ctx do
      %{conn: conn, project: project, task: task} = ctx
      row = feed_row(task, kind: :message, text: "Shipped it:\n\n- one\n- two\n")

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      assert has_element?(view, "#{block_id(row)} .md li", "one")
      assert has_element?(view, "#{block_id(row)} .md li", "two")
    end

    test "a shell tool call reads as description then command, each once", ctx do
      %{conn: conn, project: project, task: task} = ctx

      row =
        feed_row(task,
          kind: :tool_call,
          # the harness titles a shell call with its own command line
          text: "git status --short",
          data: %{
            "tool_kind" => "execute",
            "input" => %{"command" => "git status --short", "description" => "Check the tree"}
          }
        )

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      # the group header carries the description, not the command line
      assert has_element?(view, "#{block_id(row)}-toggle", "Check the tree")
      # and the command itself is rendered exactly once, in the expanded row
      assert view |> render() |> String.split("git status --short") |> length() == 2
    end

    test "tool paths render relative to the worktree, outside ones stay absolute", ctx do
      %{conn: conn, project: project, task: task} = ctx
      worktree = "/w/worktrees/task-#{task.id}"
      task = put_context!(task, %{worktree_path: worktree})

      inside =
        feed_row(task,
          kind: :tool_call,
          text: "Read docs/trap-entries.md",
          data: %{"locations" => [Path.join(worktree, "docs/trap-entries.md")]}
        )

      outside =
        feed_row(task,
          kind: :tool_call,
          text: "Read passwd",
          data: %{"locations" => ["/etc/passwd"]}
        )

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))
      html = render(view)

      assert has_element?(view, block_id(inside))
      refute has_element?(view, block_id(outside))
      refute html =~ worktree
      assert html =~ "docs/trap-entries.md"
      # a path the agent reached outside the project keeps its leading slash
      assert html =~ "/etc/passwd"
    end

    test "an absolute path in a tool's input is shortened too", ctx do
      %{conn: conn, project: project, task: task} = ctx
      worktree = "/w/worktrees/task-#{task.id}"
      task = put_context!(task, %{worktree_path: worktree})

      feed_row(task,
        kind: :tool_call,
        text: "Write",
        data: %{"input" => %{"file_path" => Path.join(worktree, "docs/new.md")}}
      )

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))
      html = render(view)

      refute html =~ worktree
      assert html =~ "docs/new.md"
    end

    test "live chunks render in the live pane until the row is finalized", ctx do
      %{conn: conn, project: project, task: task} = ctx

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      row = feed_row(task, kind: :message, text: "Thinking about ", streaming: true)
      send(view.pid, {:agent_feed, task.id, row})
      send(view.pid, {:task_event, task.id, {:message_chunk, "the fix."}})

      assert has_element?(view, "#agent-live-message")
      assert render(view) =~ "Thinking about the fix."
      refute has_element?(view, block_id(row))

      finalized =
        AgentFeed.update_event(row, %{text: "Thinking about the fix.", streaming: false})

      send(view.pid, {:agent_feed, task.id, finalized})

      refute has_element?(view, "#agent-live-message")
      assert has_element?(view, block_id(row))
      # not rendered twice
      assert render(view) =~ "Thinking about the fix."
    end

    test "a reopened message row grows in its block, not in the live pane", ctx do
      %{conn: conn, project: project, task: task} = ctx

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      row = feed_row(task, kind: :message, text: "Kicked it off, now let me", streaming: false)
      send(view.pid, {:agent_feed, task.id, row})
      tool = feed_row(task, kind: :tool_call, text: "Read mix.exs")
      send(view.pid, {:agent_feed, task.id, tool})

      # the runner reopens the row rather than starting a second message
      reopened =
        AgentFeed.update_event(row, %{
          text: "Kicked it off, now let me read a few files.",
          streaming: true
        })

      send(view.pid, {:agent_feed, task.id, reopened})

      refute has_element?(view, "#agent-live-message")
      assert has_element?(view, block_id(row))
      assert has_element?(view, block_id(tool))
      assert render(view) =~ "read a few files."
    end

    test "an unresolved permission is answerable, a resolved one is not", ctx do
      %{conn: conn, project: project, task: task} = ctx

      row =
        feed_row(task, kind: :permission, text: "write outside the worktree", external_id: "7")

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))
      assert has_element?(view, "#{block_id(row)}-grant")

      resolved = AgentFeed.update_event(row, %{data: %{"resolved" => true}})
      send(view.pid, {:agent_feed, task.id, resolved})

      refute has_element?(view, "#{block_id(row)}-grant")
    end

    defp question_row(task, attrs \\ []) do
      feed_row(
        task,
        Enum.into(attrs, %{
          kind: :question,
          text: "Which approach should I take?",
          external_id: "80",
          data: %{
            "fields" => [
              %{
                "key" => "question_0",
                "label" => "Approach",
                "description" => nil,
                "type" => "select",
                "required" => false,
                "custom_for" => nil,
                "options" => [
                  %{
                    "value" => "Refactor first",
                    "label" => "Refactor first",
                    "description" => "Clean up, then build"
                  },
                  %{"value" => "Ship it", "label" => "Ship it", "description" => nil}
                ]
              },
              %{
                "key" => "question_0_custom",
                "label" => "Other",
                "description" => "Type your own answer",
                "type" => "text",
                "required" => false,
                "custom_for" => "question_0",
                "options" => []
              }
            ]
          }
        })
      )
    end

    test "an unanswered question renders the agent's own options as a form", ctx do
      %{conn: conn, project: project, task: task} = ctx
      row = question_row(task)

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      assert has_element?(view, "#{block_id(row)}-answer-form")
      assert has_element?(view, "#{block_id(row)}-answer")
      assert has_element?(view, "#{block_id(row)}-skip")

      # one control per option the agent offered, plus its free-text box
      assert has_element?(view, "#{block_id(row)} #agent-block-#{row.id}-question_0-0")
      assert has_element?(view, "#{block_id(row)} #agent-block-#{row.id}-question_0-1")
      assert has_element?(view, "#{block_id(row)} #agent-block-#{row.id}-question_0_custom")

      assert render(view) =~ "Clean up, then build"
    end

    test "an answered question shows the answer and drops the form", ctx do
      %{conn: conn, project: project, task: task} = ctx
      row = question_row(task)

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))
      assert has_element?(view, "#{block_id(row)}-answer-form")

      resolved =
        AgentFeed.update_event(row, %{
          data: %{"resolved" => "answered", "answers" => %{"question_0" => "Ship it"}}
        })

      send(view.pid, {:agent_feed, task.id, resolved})

      refute has_element?(view, "#{block_id(row)}-answer-form")
      assert render(view) =~ "Ship it"
      assert render(view) =~ "Answered"
    end

    test "a question is no longer answerable once the run stops", ctx do
      %{conn: conn, project: project, task: task} = ctx
      row = question_row(task)
      put_context!(task, %{state: :review, run_state: :idle})

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      refute has_element?(view, "#{block_id(row)}-answer-form")
    end

    test "submitting with no runner alive reports the failure instead of crashing", ctx do
      %{conn: conn, project: project, task: task} = ctx
      row = question_row(task)

      {:ok, view, _html} = live(conn, task_path(project, task, "agent"))

      html =
        view
        |> form("#{block_id(row)}-answer-form", %{"answer" => %{"question_0" => "Ship it"}})
        |> render_submit()

      assert html =~ "Couldn&#39;t send the answer"
    end
  end

  describe "review tab preview" do
    setup %{conn: conn} do
      %{conn: conn, project: project_fixture()}
    end

    defp preview_task(project, work_type, repo_attrs) do
      repository = repository_fixture(project.id, repo_attrs)

      task_fixture(project.id, %{
        work_type: work_type,
        target: :repo,
        repository_id: repository.id
      })
    end

    test "a task with a declared port gets the strip with an Open-preview link", ctx do
      %{conn: conn, project: project} = ctx
      task = preview_task(project, :design, %{preview_port: 5173})

      {:ok, view, _html} = live(conn, task_path(project, task, "review"))

      assert has_element?(
               view,
               ~s(a#preview-open[href="/preview/launch/#{task.id}"][target="_blank"][rel="noopener"])
             )

      # The iframe world is gone — no embedded frame, no toolbar.
      refute has_element?(view, "#preview-pane")
      refute has_element?(view, "input#preview-path")
      refute has_element?(view, "#review-mode-toggle")
    end

    test "the diff renders alongside the strip, not behind a toggle", ctx do
      %{conn: conn, project: project} = ctx
      task = preview_task(project, :code, %{preview_port: 5173})

      {:ok, view, _html} = live(conn, task_path(project, task, "review"))

      assert has_element?(view, "#preview-open")
      assert has_element?(view, "#diff-pane")
    end

    test "a repo task without a port gets the enablement hint and no strip", ctx do
      %{conn: conn, project: project} = ctx
      task = preview_task(project, :code, %{})

      {:ok, view, _html} = live(conn, task_path(project, task, "review"))

      refute has_element?(view, "#preview-open")
      assert has_element?(view, "#preview-hint")
    end

    test "the legacy ?tab=diff URL lands on the review tab", ctx do
      %{conn: conn, project: project} = ctx
      task = preview_task(project, :code, %{})

      {:ok, view, _html} = live(conn, task_path(project, task, "diff"))

      assert has_element?(view, "#preview-hint")
    end
  end

  describe "terminal tab" do
    setup %{conn: conn} do
      %{conn: conn, project: project_fixture()}
    end

    test "renders the xterm hook container once a worktree exists", ctx do
      %{conn: conn, project: project} = ctx
      repository = repository_fixture(project.id)

      task =
        project.id
        |> task_fixture(%{target: :repo, repository_id: repository.id})
        |> CodeLead.TasksFixtures.put_context!(%{worktree_path: "/tmp/somewhere"})

      {:ok, view, _html} = live(conn, task_path(project, task, "terminal"))

      assert has_element?(view, "#terminal")
    end

    test "keeps the placeholder without a worktree", ctx do
      %{conn: conn, project: project} = ctx
      task = task_fixture(project.id, %{})

      {:ok, view, _html} = live(conn, task_path(project, task, "terminal"))

      refute has_element?(view, "#terminal")
      assert render(view) =~ "worktree is provisioned"
    end

    test "renders for a folder-target task once its task folder exists", ctx do
      %{conn: conn, project: project} = ctx
      task = task_fixture(project.id, %{target: :folder})
      folder = CodeLead.Workspace.task_folder(task.id)
      File.mkdir_p!(folder)
      on_exit(fn -> File.rm_rf(folder) end)

      {:ok, view, _html} = live(conn, task_path(project, task, "terminal"))

      assert has_element?(view, "#terminal")
    end

    test "tells a folder-target task what it is waiting for", ctx do
      %{conn: conn, project: project} = ctx
      task = task_fixture(project.id, %{target: :folder})

      {:ok, view, _html} = live(conn, task_path(project, task, "terminal"))

      refute has_element?(view, "#terminal")
      assert render(view) =~ "task folder is provisioned"
    end
  end

  describe "diff tab" do
    setup %{conn: conn} do
      project = project_fixture()
      git_url = create_origin!()
      repository = repository_fixture(project.id, %{git_url: git_url, default_branch: "main"})

      task =
        task_fixture(project.id, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id
        })

      {:ok, context} = LocalSubprocess.provision(task)
      write!(context.path, "alpha.md", "alpha\n")
      write!(context.path, "beta.md", "beta\n")

      task = Tasks.get_task!(task.id) |> put_context!(%{state: :review})

      %{conn: conn, project: project, task: task, worktree: context.path}
    end

    defp write!(worktree, path, content), do: File.write!(Path.join(worktree, path), content)

    defp card(path), do: "##{DiffComponents.file_dom_id(path)}"

    defp body(path), do: "#{card(path)} table"

    defp open_diff(conn, project, task) do
      {:ok, view, _html} = live(conn, task_path(project, task, "diff"))
      render_async(view, 2_000)
      view
    end

    test "opens with only the first file expanded", ctx do
      %{conn: conn, project: project, task: task} = ctx

      view = open_diff(conn, project, task)

      assert has_element?(view, card("alpha.md"))
      assert has_element?(view, card("beta.md"))
      assert has_element?(view, body("alpha.md"))
      refute has_element?(view, body("beta.md"))
    end

    test "a file header toggles its own body and nothing else", ctx do
      %{conn: conn, project: project, task: task} = ctx

      view = open_diff(conn, project, task)

      view |> element("#{card("beta.md")} button") |> render_click()
      assert has_element?(view, body("beta.md"))
      assert has_element?(view, body("alpha.md"))

      view |> element("#{card("beta.md")} button") |> render_click()
      refute has_element?(view, body("beta.md"))
    end

    test "jumping from the sidebar focuses one file and scrolls to it", ctx do
      %{conn: conn, project: project, task: task} = ctx

      view = open_diff(conn, project, task)

      view
      |> element("button[phx-click='focus_file'][phx-value-path='beta.md']")
      |> render_click()

      assert_push_event(view, "diff:scroll_to", %{id: id})
      assert id == DiffComponents.file_dom_id("beta.md")
      assert has_element?(view, body("beta.md"))
      refute has_element?(view, body("alpha.md"))
    end

    test "re-entering the tab collapses back to the first file", ctx do
      %{conn: conn, project: project, task: task} = ctx

      view = open_diff(conn, project, task)
      view |> element("#{card("beta.md")} button") |> render_click()
      assert has_element?(view, body("beta.md"))

      view |> element("nav a", "Task") |> render_click()
      view |> element("nav a", "Review") |> render_click()
      render_async(view, 2_000)

      assert has_element?(view, body("alpha.md"))
      refute has_element?(view, body("beta.md"))
    end

    test "a writing tool call brings in files the agent just wrote", ctx do
      %{conn: conn, project: project, task: task, worktree: worktree} = ctx

      view = open_diff(conn, project, task)
      refute has_element?(view, card("gamma.md"))

      write!(worktree, "gamma.md", "gamma\n")
      send(view.pid, {:agent_feed, task.id, tool_row(task, "edit")})
      send(view.pid, :refresh_diff)
      render_async(view, 2_000)

      assert has_element?(view, card("gamma.md"))
    end

    test "a read-only tool call does not re-run git", ctx do
      %{conn: conn, project: project, task: task, worktree: worktree} = ctx

      view = open_diff(conn, project, task)

      write!(worktree, "gamma.md", "gamma\n")
      send(view.pid, {:agent_feed, task.id, tool_row(task, "read")})
      send(view.pid, :refresh_diff)
      render_async(view, 2_000)

      refute has_element?(view, card("gamma.md"))
    end

    test "a background refresh preserves what the reader expanded", ctx do
      %{conn: conn, project: project, task: task, worktree: worktree} = ctx

      view = open_diff(conn, project, task)
      view |> element("#{card("beta.md")} button") |> render_click()
      view |> element("#{card("alpha.md")} button") |> render_click()

      write!(worktree, "gamma.md", "gamma\n")
      view |> element("#diff-refresh") |> render_click()
      render_async(view, 2_000)

      assert has_element?(view, card("gamma.md"))
      assert has_element?(view, body("beta.md"))
      refute has_element?(view, body("alpha.md"))
      # newly written files stay collapsed
      refute has_element?(view, body("gamma.md"))
    end

    test "follow mode is offered only during a run and tracks what the agent writes", ctx do
      %{conn: conn, project: project, task: task, worktree: worktree} = ctx

      view = open_diff(conn, project, task)
      refute has_element?(view, "#diff-follow")

      task = put_context!(task, %{state: :running, run_state: :executing})
      view = open_diff(conn, project, task)
      assert has_element?(view, "#diff-follow")

      # the agent reports where it is working, then the refresh lands
      write!(worktree, "gamma.md", "gamma\n")
      send(view.pid, {:agent_feed, task.id, tool_row(task, "edit")})
      view |> element("#diff-follow") |> render_click()
      send(view.pid, :refresh_diff)
      render_async(view, 2_000)

      assert has_element?(view, "#diff-following")
      assert_push_event(view, "diff:scroll_to", %{id: id})
      assert id == DiffComponents.file_dom_id("gamma.md")
      assert has_element?(view, body("gamma.md"))
      refute has_element?(view, body("alpha.md"))
    end

    test "clicking the chip stops following", ctx do
      %{conn: conn, project: project, task: task} = ctx
      task = put_context!(task, %{state: :running, run_state: :executing})

      view = open_diff(conn, project, task)
      view |> element("#diff-follow") |> render_click()
      assert has_element?(view, "#diff-following")

      view |> element("#diff-following") |> render_click()

      refute has_element?(view, "#diff-following")
      assert has_element?(view, "#diff-follow")
    end

    # Re-anchoring on every refresh would drag the viewport back through
    # ten consecutive edits of one file.
    test "following re-scrolls only when the agent moves to another file", ctx do
      %{conn: conn, project: project, task: task, worktree: worktree} = ctx
      task = put_context!(task, %{state: :running, run_state: :executing})

      view = open_diff(conn, project, task)
      write!(worktree, "gamma.md", "gamma\n")
      send(view.pid, {:agent_feed, task.id, tool_row(task, "edit")})
      view |> element("#diff-follow") |> render_click()
      assert_push_event(view, "diff:scroll_to", %{id: _gamma})

      # same file again — no second scroll
      send(view.pid, {:agent_feed, task.id, tool_row(task, "edit")})
      send(view.pid, :refresh_diff)
      render_async(view, 2_000)
      refute_push_event(view, "diff:scroll_to", %{})

      # a different file — follow moves
      write!(worktree, "delta.md", "delta\n")
      send(view.pid, {:agent_feed, task.id, tool_row(task, "edit", "delta.md")})
      send(view.pid, :refresh_diff)
      render_async(view, 2_000)

      assert_push_event(view, "diff:scroll_to", %{id: id})
      assert id == DiffComponents.file_dom_id("delta.md")
      assert has_element?(view, body("delta.md"))
    end

    test "the reader taking over hands control back from the agent", ctx do
      %{conn: conn, project: project, task: task} = ctx
      task = put_context!(task, %{state: :running, run_state: :executing})

      view = open_diff(conn, project, task)
      view |> element("#diff-follow") |> render_click()
      assert has_element?(view, "#diff-following")

      # what the JS hook pushes on a user scroll
      render_hook(view, "diff_unfollow", %{})

      refute has_element?(view, "#diff-following")
      assert has_element?(view, "#diff-follow")
    end

    defp tool_row(task, tool_kind, path \\ "gamma.md") do
      AgentFeed.record_event(task.id, %{
        kind: :tool_call,
        text: "Write #{path}",
        data: %{"tool_kind" => tool_kind, "locations" => [path]}
      })
    end
  end
end

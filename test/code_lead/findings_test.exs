defmodule CodeLead.FindingsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AccountsFixtures
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Findings
  alias CodeLead.Findings.Finding
  alias CodeLead.Findings.Report
  alias CodeLead.Planning
  alias CodeLead.Repo
  alias CodeLead.Runtime.TaskRunner
  alias CodeLead.Tasks

  defp survey_setup(_context) do
    project = project_fixture()
    task = task_fixture(project.id)
    agent = agent_fixture(%{driver: :acp, harness: :claude_code, roles: [:plan]})
    step = Tasks.record_step(task.id, :plan, :agent, agent.name, "repo survey: ok")
    %{project: project, task: task, agent: agent, step: step}
  end

  defp report(findings, prior \\ []) do
    tail = JSON.encode!(%{findings: findings, prior: prior})

    """
    The payment flow lives in `lib/pay.ex`.

    ```json
    #{tail}
    ```
    """
  end

  defp finding_item(attrs \\ %{}) do
    Map.merge(
      %{
        title: "Payment failure path is unspecified",
        severity: "high",
        body: "The spec never says what happens on decline.",
        paths: ["lib/pay.ex", "lib/pay/webhook.ex:42"]
      },
      attrs
    )
  end

  describe "Report.extract/1" do
    test "takes the last fenced json block and returns the narrative without it" do
      content = """
      Some narrative citing `lib/a.ex`.

      ```json
      {"findings": []}
      ```
      """

      assert {:ok, %{"findings" => []}, narrative} = Report.extract(content)
      assert narrative == "Some narrative citing `lib/a.ex`."
    end

    test "prefers the last of several fenced blocks" do
      content = """
      ```json
      {"findings": [{"title": "from the first block"}]}
      ```

      Text between.

      ```json
      {"findings": []}
      ```
      """

      assert {:ok, %{"findings" => []}, narrative} = Report.extract(content)
      assert narrative =~ "from the first block"
      assert narrative =~ "Text between."
    end

    test "accepts a bare trailing JSON object without a fence" do
      content = """
      Narrative first.

      {"findings": [{"title": "Bare tail"}]}
      """

      assert {:ok, %{"findings" => [%{"title" => "Bare tail"}]}, "Narrative first."} =
               Report.extract(content)
    end

    test "yields :error when nothing parses" do
      assert Report.extract("Working on it. Done.") == :error
      assert Report.extract("```json\nnot json\n```") == :error
      assert Report.extract(nil) == :error
    end

    test "recovers a fence glued to the narrative with the payload on the same line" do
      content =
        ~S(Nothing in the docs covers this.```json { "findings": [{"title": "Glued"}], "prior": [] })

      assert {:ok, payload, narrative} = Report.extract(content)
      assert [%{title: "Glued"}] = Report.new_findings(payload)
      assert narrative == "Nothing in the docs covers this."
    end

    test "recovers a block that is never closed" do
      content = """
      Narrative first.

      ```json
      {"findings": [{"title": "Unterminated"}]}
      """

      assert {:ok, payload, "Narrative first."} = Report.extract(content)
      assert [%{title: "Unterminated"}] = Report.new_findings(payload)
    end

    test "tolerates trailing text after the block" do
      content = """
      Narrative first.

      ```json
      {"findings": [{"title": "Then chatter"}]}
      ```

      Let me know if you want more detail.
      """

      assert {:ok, payload, narrative} = Report.extract(content)
      assert [%{title: "Then chatter"}] = Report.new_findings(payload)
      assert narrative =~ "Let me know if you want more detail."
    end

    test "escapes stray double quotes inside string values" do
      content = ~S"""
      Narrative first.

      ```json
      {"findings": [{"title": "Quoted", "body": "The task says "if it is a fork" without saying which."}], "prior": []}
      ```
      """

      assert {:ok, payload, "Narrative first."} = Report.extract(content)
      assert [%{title: "Quoted", body: body}] = Report.new_findings(payload)
      assert body == ~S(The task says "if it is a fork" without saying which.)
    end

    test "never mistakes a nested item object for the whole report" do
      # The outer object is unrecoverable (an unterminated string runs
      # to EOF), so no candidate may stand in for it.
      content = ~S({"findings": [{"title": "Inner", "body": "unterminated)

      assert Report.extract(content) == :error
    end
  end

  describe "apply_report/5" do
    setup :survey_setup

    test "inserts one row per finding", %{task: task, agent: agent, step: step} do
      content = report([finding_item(), finding_item(%{title: "Second", severity: "low"})])

      assert {:ok, delta} = Findings.apply_report(task, :planning, step, agent, content)
      assert delta == %{new: 2, resolved: 0, not_applicable: 0, still_open: 0}

      [high, low] = Findings.list(task.id, :planning)
      assert high.title == "Payment failure path is unspecified"
      assert high.severity == :high
      assert high.phase == :planning
      assert high.observed == :open
      assert high.agent_id == agent.id
      assert high.first_seen_step_id == step.id
      assert high.last_seen_step_id == step.id
      assert high.paths == ["lib/pay.ex", "lib/pay/webhook.ex:42"]
      assert low.severity == :low
    end

    test "drops invalid items and defaults unknown severity", %{
      task: task,
      agent: agent,
      step: step
    } do
      content =
        report([
          %{severity: "high", body: "no title"},
          %{title: "   "},
          finding_item(%{title: "Kept", severity: "catastrophic", paths: "not-a-list"})
        ])

      assert {:ok, %{new: 1}} = Findings.apply_report(task, :planning, step, agent, content)

      [finding] = Findings.list(task.id, :planning)
      assert finding.title == "Kept"
      assert finding.severity == :medium
      assert finding.paths == []
    end

    test "truncates overlong titles", %{task: task, agent: agent, step: step} do
      content = report([finding_item(%{title: String.duplicate("x", 200)})])
      assert {:ok, %{new: 1}} = Findings.apply_report(task, :planning, step, agent, content)

      [finding] = Findings.list(task.id, :planning)
      assert String.length(finding.title) == Finding.title_limit()
    end

    test "writes nothing when no block parses", %{task: task, agent: agent, step: step} do
      assert Findings.apply_report(task, :planning, step, agent, "Working on it. Done.") ==
               :error

      assert Findings.list(task.id, :planning) == []
    end

    test "writes rows for a report recovered from a malformed tail", %{
      task: task,
      agent: agent,
      step: step
    } do
      content =
        ~S(Survey done.```json { "findings": [{"title": "Recovered", "severity": "high", "body": "It says "maybe" here.", "paths": ["lib/pay.ex"]}], "prior": [] })

      assert {:ok, %{new: 1}} = Findings.apply_report(task, :planning, step, agent, content)

      [finding] = Findings.list(task.id, :planning)
      assert finding.title == "Recovered"
      assert finding.severity == :high
      assert finding.body == ~S(It says "maybe" here.)
      assert finding.paths == ["lib/pay.ex"]
    end

    test "prior classifications bump the observation, omissions stay untouched", %{
      task: task,
      agent: agent,
      step: step
    } do
      content =
        report([finding_item(), finding_item(%{title: "B"}), finding_item(%{title: "C"})])

      {:ok, _delta} = Findings.apply_report(task, :planning, step, agent, content)
      [a, b, c] = task.id |> Findings.list(:planning) |> Enum.sort_by(& &1.id)

      rerun_step = Tasks.record_step(task.id, :plan, :agent, agent.name, "repo survey: ok")

      rerun =
        report([], [
          %{id: a.id, status: "resolved"},
          %{id: b.id, status: "not_applicable"},
          %{id: 999_999, status: "resolved"},
          %{id: c.id, status: "hallucinated_status"}
        ])

      assert {:ok, delta} = Findings.apply_report(task, :planning, rerun_step, agent, rerun)
      assert delta == %{new: 0, resolved: 1, not_applicable: 1, still_open: 0}

      assert %{observed: :resolved, last_seen_step_id: last_seen} = Repo.get!(Finding, a.id)
      assert last_seen == rerun_step.id
      assert %{observed: :not_applicable} = Repo.get!(Finding, b.id)
      # omitted (invalid status) → untouched
      assert %{observed: :open, last_seen_step_id: first_seen} = Repo.get!(Finding, c.id)
      assert first_seen == step.id
    end

    test "a re-run never touches a human resolution", %{task: task, agent: agent, step: step} do
      {:ok, _delta} =
        Findings.apply_report(task, :planning, step, agent, report([finding_item()]))

      [finding] = Findings.list(task.id, :planning)

      user = user_fixture()
      {:ok, resolved} = Findings.resolve(finding, user, :addressed, "retry 3x, then hold")

      rerun_step = Tasks.record_step(task.id, :plan, :agent, agent.name, "repo survey: ok")
      rerun = report([], [%{id: finding.id, status: "still_open"}])

      assert {:ok, %{still_open: 1}} =
               Findings.apply_report(task, :planning, rerun_step, agent, rerun)

      reloaded = Repo.get!(Finding, finding.id)
      assert reloaded.observed == :open
      assert reloaded.last_seen_step_id == rerun_step.id
      assert reloaded.resolution == :addressed
      assert reloaded.resolution_note == "retry 3x, then hold"
      assert reloaded.resolved_by_id == user.id
      assert reloaded.resolved_at == resolved.resolved_at
    end
  end

  describe "resolve/4 and reopen/1" do
    setup :survey_setup

    setup %{task: task, agent: agent, step: step} do
      {:ok, _delta} =
        Findings.apply_report(task, :planning, step, agent, report([finding_item()]))

      [finding] = Findings.list(task.id, :planning)
      %{finding: finding}
    end

    test "resolve sets the four human fields and broadcasts", %{task: task, finding: finding} do
      Tasks.subscribe_task(task.id)
      user = user_fixture()

      assert {:ok, resolved} = Findings.resolve(finding, user, :dismissed, "tracked in #42")
      assert resolved.resolution == :dismissed
      assert resolved.resolution_note == "tracked in #42"
      assert resolved.resolved_by_id == user.id
      assert %DateTime{} = resolved.resolved_at

      task_id = task.id
      assert_receive {:task_event, ^task_id, {:findings_changed, %{phase: :planning}}}
    end

    test "a blank note is stored as no note", %{finding: finding} do
      assert {:ok, resolved} = Findings.resolve(finding, nil, :addressed, "   ")
      assert resolved.resolution_note == nil
      assert resolved.resolved_by_id == nil
    end

    test "still_flagged? needs a run that postdates the resolution", %{
      task: task,
      finding: finding
    } do
      step = Repo.get!(CodeLead.Tasks.TaskStep, finding.last_seen_step_id)
      {:ok, resolved} = Findings.resolve(finding, nil, :addressed, "decided")

      # resolved after the producing run — the agent has not spoken since
      refute Finding.still_flagged?(resolved, step)
      refute Finding.still_flagged?(resolved, nil)

      # a later run that still lists the finding as open raises the marker
      backdated = %{resolved | resolved_at: DateTime.add(step.inserted_at, -60, :second)}
      later = Tasks.record_step(task.id, :plan, :agent, "Surveyor", "repo survey: ok")
      assert Finding.still_flagged?(%{backdated | last_seen_step_id: later.id}, later)

      # but not when the human resolved with the agent's report in hand
      refute Finding.still_flagged?(%{resolved | last_seen_step_id: later.id}, later)
    end

    test "agent_resolved? marks only unresolved rows the agent cleared", %{finding: finding} do
      refute Finding.agent_resolved?(finding)
      assert Finding.agent_resolved?(%{finding | observed: :resolved})
      refute Finding.agent_resolved?(%{finding | observed: :resolved, resolution: :addressed})
    end

    test "reopen clears them and broadcasts", %{task: task, finding: finding} do
      {:ok, resolved} = Findings.resolve(finding, user_fixture(), :addressed, "decided")
      Tasks.subscribe_task(task.id)

      assert {:ok, reopened} = Findings.reopen(resolved)
      assert reopened.resolution == nil
      assert reopened.resolution_note == nil
      assert reopened.resolved_by_id == nil
      assert reopened.resolved_at == nil

      task_id = task.id
      assert_receive {:task_event, ^task_id, {:findings_changed, %{phase: :planning}}}
    end
  end

  describe "decisions_block/1" do
    setup :survey_setup

    setup %{task: task, agent: agent, step: step} do
      content =
        report([
          finding_item(%{title: "Retry policy"}),
          finding_item(%{title: "Rate limiting"}),
          finding_item(%{title: "Unnoted tick"})
        ])

      {:ok, _delta} = Findings.apply_report(task, :planning, step, agent, content)
      findings = task.id |> Findings.list(:planning) |> Enum.sort_by(& &1.id)
      %{findings: findings}
    end

    test "empty without noted resolutions", %{task: task, findings: [a | _rest]} do
      assert Findings.decisions_block(task.id) == ""

      # a resolution without a note flows nowhere
      {:ok, _finding} = Findings.resolve(a, nil, :addressed, nil)
      assert Findings.decisions_block(task.id) == ""
    end

    test "noted addressed under Decisions, noted dismissed under Out of scope", %{
      task: task,
      findings: [a, b, c]
    } do
      {:ok, _} = Findings.resolve(a, nil, :addressed, "retry 3x, then hold")
      {:ok, _} = Findings.resolve(b, nil, :dismissed, "tracked in #42")
      {:ok, _} = Findings.resolve(c, nil, :addressed, nil)

      assert Findings.decisions_block(task.id) == """
             ## Decisions
             - Retry policy: retry 3x, then hold

             ## Out of scope
             - Rate limiting: tracked in #42\
             """
    end

    test "a single section renders without the other's header", %{task: task, findings: [a | _]} do
      {:ok, _} = Findings.resolve(a, nil, :addressed, "decided")
      block = Findings.decisions_block(task.id)
      assert block =~ "## Decisions"
      refute block =~ "## Out of scope"
    end
  end

  describe "survey_run_count/1" do
    test "counts only survey steps" do
      project = project_fixture()
      task = task_fixture(project.id)
      assert Findings.survey_run_count(task.id) == 0

      Tasks.record_step(task.id, :plan, :agent, "Surveyor", "repo survey: ok")
      assert Findings.survey_run_count(task.id) == 1

      Tasks.record_step(task.id, :run, :system, "runner", "run started")
      Tasks.record_step(task.id, :plan, :agent, "Surveyor", "repo survey: error")
      assert Findings.survey_run_count(task.id) == 2

      # task-level llm runs count toward the same counter
      Tasks.record_step(task.id, :plan, :agent, "Coach", "task refinement: ok")
      assert Findings.survey_run_count(task.id) == 3
    end
  end

  describe "prompt injection" do
    setup :survey_setup

    test "the survey prompt lists every prior finding with its human resolution", %{
      task: task,
      agent: agent,
      step: step
    } do
      content =
        report([
          finding_item(%{title: "Retry policy"}),
          finding_item(%{title: "Rate limiting"}),
          finding_item(%{title: "Stale docs"})
        ])

      {:ok, _delta} = Findings.apply_report(task, :planning, step, agent, content)
      [a, b, c] = task.id |> Findings.list(:planning) |> Enum.sort_by(& &1.id)
      {:ok, _} = Findings.resolve(a, nil, :addressed, "retry 3x, then hold")
      {:ok, _} = Findings.resolve(b, nil, :dismissed, "tracked in #42")

      prompt = Planning.survey_prompt(task)

      assert prompt =~ "## Prior findings"
      assert prompt =~ ~s|- [#{a.id}] (addressed by human: "retry 3x, then hold") Retry policy|
      assert prompt =~ ~s|- [#{b.id}] (dismissed by human: "tracked in #42") Rate limiting|
      assert prompt =~ "- [#{c.id}] (open) Stale docs"
      assert prompt =~ "## Decisions"
      assert prompt =~ "## Out of scope"
    end

    test "a first-run survey prompt has no prior section", %{task: task} do
      prompt = Planning.survey_prompt(task)
      refute prompt =~ "## Prior findings"
      refute prompt =~ "## Decisions"
    end

    test "the survey prompt rules out generic observations", %{task: task} do
      prompt = Planning.survey_prompt(task)
      assert prompt =~ "Do not report broad or obvious observations"
      assert prompt =~ "scoping this specific task would act on"
    end

    test "the refinement prompt shares the contract but not the repo framing", %{
      task: task,
      agent: agent,
      step: step
    } do
      {:ok, _delta} =
        Findings.apply_report(task, :planning, step, agent, report([finding_item()]))

      [finding] = Findings.list(task.id, :planning)
      {:ok, _} = Findings.resolve(finding, nil, :addressed, "retry 3x, then hold")

      prompt = Planning.refinement_prompt(task)

      assert prompt =~ "You cannot read the repository"
      refute prompt =~ "Read the repository you have been given"
      assert prompt =~ ~s|exactly one fenced ```json block|
      assert prompt =~ "Do not report broad or obvious observations"
      assert prompt =~ "## Prior findings"
      assert prompt =~ ~s|- [#{finding.id}] (addressed by human: "retry 3x, then hold")|
      assert prompt =~ "## Decisions"
    end

    test "the fresh-dispatch executor prompt carries the Decisions block", %{
      task: task,
      agent: agent,
      step: step
    } do
      {:ok, _delta} =
        Findings.apply_report(task, :planning, step, agent, report([finding_item()]))

      [finding] = Findings.list(task.id, :planning)

      task = Tasks.get_task!(task.id)
      assert TaskRunner.build_prompt(task) =~ task.title
      refute TaskRunner.build_prompt(task) =~ "## Decisions"

      {:ok, _} = Findings.resolve(finding, nil, :addressed, "retry 3x, then hold")

      prompt = TaskRunner.build_prompt(task)
      assert prompt =~ "## Decisions"
      assert prompt =~ "- Payment failure path is unspecified: retry 3x, then hold"
    end

    test "a rework prompt is exactly the feedback", %{task: task, agent: agent, step: step} do
      {:ok, _delta} =
        Findings.apply_report(task, :planning, step, agent, report([finding_item()]))

      [finding] = Findings.list(task.id, :planning)
      {:ok, _} = Findings.resolve(finding, nil, :addressed, "decided")

      task = %{Tasks.get_task!(task.id) | next_prompt: "Fix the null check."}
      assert TaskRunner.build_prompt(task) == "Fix the null check."
    end
  end
end

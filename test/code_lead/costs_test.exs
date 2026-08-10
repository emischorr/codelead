defmodule CodeLead.CostsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Costs
  alias CodeLead.Costs.AgentRun
  alias CodeLead.Costs.DailyMetric

  defp record!(task, opts) do
    {:ok, run} =
      Costs.record_run(%{
        task_id: task.id,
        status: :ok,
        started_at: Keyword.get(opts, :started_at, DateTime.utc_now(:second)),
        usage: %{
          prompt_tokens: Keyword.get(opts, :prompt, 100),
          completion_tokens: Keyword.get(opts, :completion, 50),
          total_tokens: Keyword.get(opts, :prompt, 100) + Keyword.get(opts, :completion, 50),
          cost_cents: Keyword.get(opts, :cost_cents, 2)
        }
      })

    run
  end

  describe "with_cost/2" do
    test "prices tokens from the config map" do
      usage = %{
        prompt_tokens: 1_000_000,
        completion_tokens: 500_000,
        total_tokens: 1_500_000,
        cost_cents: nil
      }

      priced = Costs.with_cost(usage, "claude-sonnet-5")
      # 1M input @300 + 0.5M output @1500 = 300 + 750
      assert priced.cost_cents == 1050
    end

    test "unknown model costs 0; reported cost wins" do
      usage = %{prompt_tokens: 100, completion_tokens: 100, total_tokens: 200, cost_cents: nil}
      assert Costs.with_cost(usage, "mystery-model").cost_cents == 0
      assert Costs.with_cost(%{usage | cost_cents: 42}, "claude-sonnet-5").cost_cents == 42
    end
  end

  describe "spend queries" do
    test "project and task spend combine today's runs" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})
      record!(task, prompt: 100, completion: 50, cost_cents: 3)
      record!(task, prompt: 200, completion: 100, cost_cents: 5)

      assert Costs.project_spend(project.id) == %{tokens: 450, cost_cents: 8}
      assert Costs.task_spend(task.id) == %{tokens: 450, cost_cents: 8}
      assert Costs.org_spend().tokens >= 450
    end
  end

  describe "rollup/0" do
    test "rolls completed days into daily_metrics and preserves spend" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})

      two_days_ago = DateTime.add(DateTime.utc_now(:second), -2 * 24 * 3600, :second)
      record!(task, started_at: two_days_ago, prompt: 10, completion: 5, cost_cents: 1)
      record!(task, started_at: two_days_ago, prompt: 20, completion: 10, cost_cents: 2)
      record!(task, prompt: 100, completion: 50, cost_cents: 4)

      assert :ok = Costs.rollup()

      metric = Repo.get_by!(DailyMetric, project_id: project.id)
      assert metric.total_tokens == 45
      assert metric.cost_cents == 3
      assert metric.run_count == 2

      # rolled + today's fresh run
      assert Costs.project_spend(project.id) == %{tokens: 195, cost_cents: 7}

      # rollup is idempotent
      assert :ok = Costs.rollup()
      assert Repo.aggregate(DailyMetric, :count) == 1
      assert Costs.project_spend(project.id) == %{tokens: 195, cost_cents: 7}
    end

    test "prunes runs older than 14 days but keeps their metrics" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})

      old = DateTime.add(DateTime.utc_now(:second), -20 * 24 * 3600, :second)
      record!(task, started_at: old, prompt: 10, completion: 5, cost_cents: 9)

      assert :ok = Costs.rollup()

      assert Repo.aggregate(AgentRun, :count) == 0
      assert Costs.project_spend(project.id) == %{tokens: 15, cost_cents: 9}
    end
  end

  describe "check_budget/1" do
    test "holds when the project cost limit is reached" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})

      assert :ok = Costs.check_budget(project.id)

      {:ok, _} = CodeLead.Projects.update_project(project, %{budget_limit_cents: 10})
      record!(task, cost_cents: 10)

      assert {:hold, :budget} = Costs.check_budget(project.id)
    end

    test "holds when the org token limit is reached" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})

      {:ok, _} = CodeLead.Accounts.update_organization(%{budget_limit_tokens: 100})
      record!(task, prompt: 80, completion: 30)

      assert {:hold, :budget} = Costs.check_budget(project.id)
    end
  end

  describe "RollupWorker" do
    test "performs the rollup through Oban" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content})
      two_days_ago = DateTime.add(DateTime.utc_now(:second), -2 * 24 * 3600, :second)
      record!(task, started_at: two_days_ago)

      assert :ok = perform_job(CodeLead.Costs.RollupWorker, %{})
      assert Repo.aggregate(DailyMetric, :count) == 1
    end
  end

  defp perform_job(worker, args) do
    Oban.Testing.perform_job(worker, args, repo: CodeLead.Repo)
  end
end

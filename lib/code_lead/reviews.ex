defmodule CodeLead.Reviews do
  @moduledoc """
  The advisory review cycle. On a task's entry into Review, one run per
  selected reviewer is fanned out concurrently through the ordinary
  agent drivers — `llm_api` reviewers get the artifact in-prompt, `acp`
  reviewers work read-only in the worktree. Each reviewer writes a
  `reviews` row, an `agent_runs` row, and a `task_step`. Verdicts are
  advisory: nothing gates the human decision. When the cycle completes
  the task gets `attention: :review_ready`.

  The run itself is `CodeLead.AdvisoryRun` — the same read-only
  primitive the planning survey uses. This module owns only the
  artifact, the prompt, the verdict, and the rows.

  Review runs are cost-tracked but not budget-held.
  """

  import Ecto.Query

  alias CodeLead.AdvisoryRun
  alias CodeLead.Agents.Agent
  alias CodeLead.Costs
  alias CodeLead.Executor.Context
  alias CodeLead.Findings
  alias CodeLead.Git
  alias CodeLead.Projects
  alias CodeLead.Repo
  alias CodeLead.Reviews.Review
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task

  # The run's own deadline is the shorter one on purpose: it cancels
  # the driver and still records a review row, where the outer stream
  # timeout only kills the child.
  @review_run_timeout :timer.minutes(15)
  @review_timeout :timer.minutes(16)
  @artifact_char_limit 60_000

  @doc """
  Reviews of a task, newest cycle first.
  """
  @spec list_reviews(pos_integer()) :: [Review.t()]
  def list_reviews(task_id) do
    Repo.all(
      from r in Review,
        where: r.task_id == ^task_id,
        order_by: [desc: r.cycle, asc: r.id],
        preload: :agent
    )
  end

  @spec current_cycle(pos_integer()) :: non_neg_integer()
  def current_cycle(task_id) do
    Repo.one(from r in Review, where: r.task_id == ^task_id, select: max(r.cycle)) || 0
  end

  @doc """
  Latest-cycle verdicts per task in one query, for board-card summaries.
  Pending reviews carry a nil verdict. Tasks without reviews are absent.
  """
  @spec verdicts_by_task([pos_integer()]) :: %{pos_integer() => [atom() | nil]}
  def verdicts_by_task([]), do: %{}

  def verdicts_by_task(task_ids) do
    max_cycles =
      from r in Review,
        where: r.task_id in ^task_ids,
        group_by: r.task_id,
        select: %{task_id: r.task_id, cycle: max(r.cycle)}

    Repo.all(
      from r in Review,
        join: m in subquery(max_cycles),
        on: r.task_id == m.task_id and r.cycle == m.cycle,
        select: {r.task_id, r.verdict}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Fans out the review cycle for a task entering Review. Runs
  asynchronously; with no reviewers selected, Review is human-only and
  attention is raised immediately. Returns the cycle number (0 when
  human-only).
  """
  @spec start_cycle(Task.t()) :: {:ok, non_neg_integer()}
  def start_cycle(%Task{} = task) do
    reviewers = Tasks.reviewers(task.id)

    if reviewers == [] do
      {:ok, _task} = Tasks.set_attention(task, :review_ready, nil, :advisory)
      broadcast(task, {:review_cycle_completed, 0})
      {:ok, 0}
    else
      cycle = current_cycle(task.id) + 1

      Elixir.Task.Supervisor.start_child(CodeLead.TaskSupervisor, fn ->
        run_cycle(task, reviewers, cycle)
      end)

      {:ok, cycle}
    end
  end

  ## Cycle execution (inside CodeLead.TaskSupervisor)

  defp run_cycle(task, reviewers, cycle) do
    artifact = artifact_for_review(task)

    CodeLead.TaskSupervisor
    |> Elixir.Task.Supervisor.async_stream_nolink(
      reviewers,
      &run_reviewer(task, &1, cycle, artifact),
      timeout: @review_timeout,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Stream.zip(reviewers)
    |> Enum.each(fn
      {{:ok, _review}, _reviewer} ->
        :ok

      {{:exit, reason}, reviewer} ->
        record_review(task, reviewer, cycle, nil, "review crashed: #{inspect(reason)}", nil)
    end)

    {:ok, updated} = Tasks.set_attention(Tasks.get_task!(task.id), :review_ready, nil, :advisory)
    broadcast(updated, {:review_cycle_completed, cycle})
  end

  defp run_reviewer(task, %Agent{} = reviewer, cycle, artifact) do
    started_at = DateTime.utc_now(:second)
    monotonic_start = System.monotonic_time(:millisecond)
    prompt = review_prompt(task, artifact)
    context = review_context(task, reviewer)

    result =
      case AdvisoryRun.run(task, reviewer, context, prompt, timeout: @review_run_timeout) do
        {:ok, result} ->
          result

        {:error, reason} ->
          %{status: :error, content: "review failed: #{inspect(reason)}", usage: nil}
      end

    {verdict, findings} =
      case result do
        %{status: :ok} = result ->
          text = result[:content] || ""
          {parse_verdict(text), text}

        %{status: status} = result ->
          {nil, "review #{status}: #{result[:content]}"}
      end

    step =
      Tasks.record_step(
        task.id,
        :review,
        :agent,
        reviewer.name,
        "review cycle #{cycle}: #{verdict || "no verdict"}",
        Integer.to_string(reviewer.id)
      )

    Costs.record_run(%{
      task_id: task.id,
      task_step_id: step.id,
      agent_id: reviewer.id,
      provider_id: reviewer.provider_id,
      usage: Costs.with_cost(result[:usage], reviewer.model_variant),
      status: result.status,
      started_at: started_at,
      finished_at: DateTime.utc_now(:second),
      duration_ms: System.monotonic_time(:millisecond) - monotonic_start
    })

    review = record_review(task, reviewer, cycle, verdict, findings, step.id)
    broadcast(task, {:review_completed, %{agent: reviewer.name, verdict: verdict}})
    review
  end

  defp record_review(task, reviewer, cycle, verdict, findings, step_id) do
    Repo.insert!(%Review{
      task_id: task.id,
      agent_id: reviewer.id,
      task_step_id: step_id,
      cycle: cycle,
      verdict: verdict,
      findings: findings
    })
  end

  ## Artifact & prompt

  # For :repo targets the artifact is the branch diff; for :folder the
  # file listing plus text file contents (truncated).

  # A repo task can reach Review with its context already torn down;
  # `review_context/2` below allows for it, and `Git.diff/2` would raise
  # on the nil path rather than fail the review.
  defp artifact_for_review(%Task{target: :repo, worktree_path: nil}),
    do: "Diff unavailable: no worktree provisioned."

  defp artifact_for_review(%Task{target: :repo} = task) do
    repository = Projects.get_repository!(task.repository_id)

    case Git.diff(task.worktree_path, repository.default_branch) do
      {:ok, ""} -> "The diff against the branch base is empty."
      {:ok, diff} -> "## Diff against the branch base\n\n```diff\n#{truncate(diff)}\n```"
      {:error, reason} -> "Diff unavailable: #{reason}"
    end
  end

  defp artifact_for_review(%Task{} = task) do
    folder = CodeLead.Workspace.task_folder(task.id)

    files =
      case File.ls(folder) do
        {:ok, files} -> Enum.sort(files)
        {:error, _reason} -> []
      end

    contents =
      files
      |> Enum.filter(&(Path.extname(&1) in [".md", ".txt", ".html", ".css", ".json"]))
      |> Enum.map_join("\n\n", fn file ->
        "### #{file}\n\n#{truncate(File.read!(Path.join(folder, file)))}"
      end)

    "## Task folder artifact\n\nFiles: #{Enum.join(files, ", ")}\n\n#{contents}"
  end

  defp review_prompt(task, artifact) do
    """
    You are reviewing the work below. Be specific; cite files and lines
    where possible. This review is advisory — a human makes the final
    decision.

    ## Task
    Title: #{task.title}
    Description: #{task.description || "(none)"}
    Spec / acceptance criteria: #{task.spec || "(none)"}
    #{decisions_section(task)}
    #{artifact}

    End your review with a single line containing only JSON in the form
    {"verdict": "pass" | "concerns" | "block"}
    """
  end

  # Reviewers judge the artifact against the human's planning
  # decisions, not only the spec.
  defp decisions_section(task) do
    case Findings.decisions_block(task.id) do
      "" -> ""
      block -> "\n" <> block <> "\n"
    end
  end

  # ACP reviewers get the execution context read-only; llm_api
  # reviewers need no filesystem at all. The executor follows the task,
  # so a reviewer of a container task execs into the same task container
  # (whose spawn re-ensures it if it was removed in between).
  defp review_context(%Task{} = task, %Agent{driver: :acp}) do
    {type, path} =
      case task.worktree_path do
        nil -> {:folder, CodeLead.Workspace.task_folder(task.id)}
        worktree_path -> {:worktree, worktree_path}
      end

    %Context{
      type: type,
      path: path,
      task_id: task.id,
      branch_name: task.branch_name,
      read_only: true,
      executor: CodeLead.Executor.for_task(task)
    }
  end

  defp review_context(%Task{}, %Agent{driver: :llm_api}), do: nil

  defp parse_verdict(text) do
    text
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{"verdict" => verdict}} when verdict in ["pass", "concerns", "block"] ->
          String.to_existing_atom(verdict)

        _other ->
          nil
      end
    end)
  end

  defp truncate(text) do
    if String.length(text) > @artifact_char_limit do
      String.slice(text, 0, @artifact_char_limit) <> "\n\n[truncated]"
    else
      text
    end
  end

  defp broadcast(task, event) do
    Phoenix.PubSub.broadcast(CodeLead.PubSub, "task:#{task.id}", {:task_event, task.id, event})
  end
end

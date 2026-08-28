defmodule CodeLead.Findings do
  @moduledoc """
  Persisted, itemized findings from advisory runs, and the human
  resolutions on them.

  Two owners, one row: an agent run writes the observation side
  (`apply_report/6` — insert new findings, reclassify prior ones), a
  human writes the resolution side (`resolve/4`, `reopen/1`). An agent
  never clears, sets, or changes a resolution; reconciliation across
  runs is done by the agent classifying prior findings in its report,
  never by fuzzy matching here.

  Resolutions flow downstream per phase. Planning resolutions with a
  note feed agent prompts via `decisions_block/1` — addressed items as
  decisions, dismissed items as out-of-scope; a resolution without a
  note flows nowhere. Review resolutions feed the request-changes
  prefill via `review_feedback_block/1` — addressed items become the
  suggested rework feedback, note optional.
  """

  import Ecto.Query

  require Logger

  alias CodeLead.Findings.Finding
  alias CodeLead.Findings.Report
  alias CodeLead.Repo
  alias CodeLead.Tasks
  alias CodeLead.Tasks.TaskStep

  @severity_order %{high: 0, medium: 1, low: 2}

  @type delta :: %{
          new: non_neg_integer(),
          resolved: non_neg_integer(),
          not_applicable: non_neg_integer(),
          still_open: non_neg_integer()
        }

  @doc """
  All findings for a task and phase, severity-first then oldest-first,
  with the resolver preloaded.
  """
  @spec list(pos_integer(), atom()) :: [Finding.t()]
  def list(task_id, phase) do
    findings =
      Repo.all(
        from f in Finding,
          where: f.task_id == ^task_id and f.phase == ^phase,
          order_by: [asc: f.id],
          preload: [:resolved_by]
      )

    Enum.sort_by(findings, &{@severity_order[&1.severity], &1.id})
  end

  @spec get_finding!(pos_integer()) :: Finding.t()
  def get_finding!(id), do: Repo.get!(Finding, id)

  @doc """
  Parses a run's report and applies it: prior classifications bump the
  observation side, new items become rows. Returns the run's delta, or
  `:error` (writing nothing) when no findings block parses.

  With `prior_scope: :agent`, prior classifications only touch rows
  this agent reported — reviewers run fanned out per cycle and must
  not reclassify each other's findings. The default `:task` scope
  keeps planning's hand-off between survey depths working.
  """
  @spec apply_report(
          Tasks.Task.t(),
          atom(),
          TaskStep.t(),
          CodeLead.Agents.Agent.t(),
          String.t() | nil,
          keyword()
        ) ::
          {:ok, delta()} | :error
  def apply_report(task, phase, step, agent, content, opts \\ []) do
    case Report.extract(content) do
      {:ok, payload, _narrative} ->
        prior_agent_id =
          case Keyword.get(opts, :prior_scope, :task) do
            :agent -> agent.id
            :task -> nil
          end

        prior_counts =
          apply_prior(task.id, phase, step.id, Report.prior(payload), prior_agent_id)

        new = insert_new(task.id, phase, step.id, agent.id, Report.new_findings(payload))
        broadcast(task.id, phase)
        {:ok, Map.put(prior_counts, :new, new)}

      :error ->
        Logger.warning(
          "findings report for task #{task.id} (#{phase}) carried no parseable findings block"
        )

        :error
    end
  end

  @doc """
  Records a human resolution. The resolver may be nil (console use).
  """
  @spec resolve(
          Finding.t(),
          CodeLead.Accounts.User.t() | nil,
          :addressed | :dismissed,
          String.t() | nil
        ) ::
          {:ok, Finding.t()} | {:error, Ecto.Changeset.t()}
  def resolve(%Finding{} = finding, user, resolution, note) do
    attrs = %{
      resolution: resolution,
      resolution_note: presence(note),
      resolved_at: DateTime.utc_now(:second)
    }

    finding
    |> Finding.resolution_changeset(attrs)
    |> Ecto.Changeset.put_change(:resolved_by_id, user && user.id)
    |> Repo.update()
    |> tap_broadcast()
  end

  @doc """
  Clears a human resolution, returning the finding to whatever its
  observation side says.
  """
  @spec reopen(Finding.t()) :: {:ok, Finding.t()} | {:error, Ecto.Changeset.t()}
  def reopen(%Finding{} = finding) do
    finding
    |> Ecto.Changeset.change(
      resolution: nil,
      resolution_note: nil,
      resolved_by_id: nil,
      resolved_at: nil
    )
    |> Repo.update()
    |> tap_broadcast()
  end

  @doc """
  The prompt-injected Decisions block: noted `:addressed` resolutions
  under `## Decisions`, noted `:dismissed` ones under `## Out of
  scope`. `""` when there is nothing to say — callers append nothing.

  Planning-phase only: a review "addressed" means "fix this next run"
  and flows through `review_feedback_block/1`, not into decisions.
  """
  @spec decisions_block(pos_integer()) :: String.t()
  def decisions_block(task_id) do
    findings =
      Repo.all(
        from f in Finding,
          where: f.task_id == ^task_id and f.phase == :planning,
          order_by: [asc: f.id]
      )

    decisions_block_from(findings)
  end

  @doc """
  Pure core of `decisions_block/1` for callers that already hold the
  findings.
  """
  @spec decisions_block_from([Finding.t()]) :: String.t()
  def decisions_block_from(findings) do
    decisions = noted(findings, :addressed)
    out_of_scope = noted(findings, :dismissed)

    [section("## Decisions", decisions), section("## Out of scope", out_of_scope)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Prior findings — every state — for injection into a re-run's prompt,
  so the agent classifies them instead of re-reporting them. Pass
  `agent_id:` to restrict to one agent's own findings (review cycles
  fan reviewers out; each classifies only what it reported).
  """
  @spec prior_for_prompt(pos_integer(), atom(), keyword()) :: [map()]
  def prior_for_prompt(task_id, phase, opts \\ []) do
    query =
      from f in Finding,
        where: f.task_id == ^task_id and f.phase == ^phase,
        order_by: [asc: f.id],
        select: map(f, [:id, :title, :observed, :resolution, :resolution_note])

    query =
      case Keyword.get(opts, :agent_id) do
        nil -> query
        agent_id -> where(query, [f], f.agent_id == ^agent_id)
      end

    Repo.all(query)
  end

  @doc """
  Renders `prior_for_prompt/3` results as the prompt section the agent
  classifies against. `""` when there are none.
  """
  @spec prior_section([map()]) :: String.t()
  def prior_section([]), do: ""

  def prior_section(prior) do
    lines = Enum.map_join(prior, "\n", &prior_line/1)
    "\n## Prior findings (classify each in \"prior\")\n" <> lines <> "\n"
  end

  @doc """
  The request-changes prefill: review-phase findings the human marked
  `:addressed` and no later cycle has observed as resolved, one line
  each, severity-first. `""` when there is nothing to fix.
  """
  @spec review_feedback_block(pos_integer()) :: String.t()
  def review_feedback_block(task_id) do
    findings =
      Repo.all(
        from f in Finding,
          where:
            f.task_id == ^task_id and f.phase == :review and
              f.resolution == :addressed and f.observed == :open,
          order_by: [asc: f.id]
      )

    findings
    |> Enum.sort_by(&{@severity_order[&1.severity], &1.id})
    |> Enum.map_join("\n", fn f ->
      case presence(f.resolution_note) do
        nil -> "- #{f.title}"
        note -> "- #{f.title}: #{note}"
      end
    end)
  end

  @doc """
  How many refinements have run for this task — derived from their
  `:plan` task steps (repo-level surveys and task-level llm runs), not
  stored.
  """
  @spec survey_run_count(pos_integer()) :: non_neg_integer()
  def survey_run_count(task_id) do
    Repo.one(
      from s in TaskStep,
        where:
          s.task_id == ^task_id and s.kind == :plan and
            (like(s.summary, "repo survey:%") or like(s.summary, "task refinement:%")),
        select: count(s.id)
    )
  end

  defp apply_prior(task_id, phase, step_id, entries, agent_id) do
    counts = %{resolved: 0, not_applicable: 0, still_open: 0}

    Enum.reduce(entries, counts, fn %{id: id, observed: observed}, acc ->
      query =
        from(f in Finding, where: f.id == ^id and f.task_id == ^task_id and f.phase == ^phase)

      query = if agent_id, do: where(query, [f], f.agent_id == ^agent_id), else: query

      updated =
        Repo.update_all(
          query,
          set: [
            observed: observed,
            last_seen_step_id: step_id,
            updated_at: DateTime.utc_now(:second)
          ]
        )

      case updated do
        {1, _} -> Map.update!(acc, count_key(observed), &(&1 + 1))
        {0, _} -> acc
      end
    end)
  end

  defp count_key(:open), do: :still_open
  defp count_key(other), do: other

  defp insert_new(task_id, phase, step_id, agent_id, items) do
    Enum.each(items, fn item ->
      Repo.insert!(%Finding{
        task_id: task_id,
        phase: phase,
        agent_id: agent_id,
        first_seen_step_id: step_id,
        last_seen_step_id: step_id,
        severity: item.severity,
        title: item.title,
        body: item.body,
        paths: item.paths,
        observed: :open
      })
    end)

    length(items)
  end

  defp prior_line(%{id: id, title: title} = finding) do
    "- [#{id}] (#{prior_status(finding)}) #{title}"
  end

  defp prior_status(%{resolution: resolution, resolution_note: note})
       when resolution in [:addressed, :dismissed] do
    label = "#{resolution} by human"
    if note, do: ~s(#{label}: "#{note}"), else: label
  end

  defp prior_status(%{observed: :not_applicable}), do: "marked not applicable in an earlier run"
  defp prior_status(%{observed: :resolved}), do: "an earlier run considered this resolved"
  defp prior_status(_finding), do: "open"

  defp noted(findings, resolution) do
    for f <- findings,
        f.resolution == resolution,
        note = presence(f.resolution_note),
        do: "- #{f.title}: #{note}"
  end

  defp section(_header, []), do: nil
  defp section(header, lines), do: header <> "\n" <> Enum.join(lines, "\n")

  defp presence(nil), do: nil

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp tap_broadcast({:ok, %Finding{} = finding} = result) do
    broadcast(finding.task_id, finding.phase)
    result
  end

  defp tap_broadcast(other), do: other

  defp broadcast(task_id, phase) do
    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      Tasks.task_topic(task_id),
      {:task_event, task_id, {:findings_changed, %{phase: phase}}}
    )
  end
end

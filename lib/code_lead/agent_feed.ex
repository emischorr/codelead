defmodule CodeLead.AgentFeed do
  @moduledoc """
  The executor transcript: durable agent output (messages, tool calls,
  questions, permission escalations, results) behind the task page's
  Agent tab.

  Two per-task logs exist and must not be conflated: `task_steps` is the
  workflow audit trail (Task tab timeline), `agent_events` is what the
  agent actually said and did.

  Every write broadcasts `{:agent_feed, task_id, event}` on the task
  topic, the way `CodeLead.Tasks` broadcasts board changes. The runner
  for a task is the single writer, so rows never race.
  """

  import Ecto.Query

  alias CodeLead.AgentFeed.AgentEvent
  alias CodeLead.Repo
  alias CodeLead.Tasks

  @default_limit 500

  # Exclusion-based on purpose: the ACP vocabulary is open, and a harness
  # labelling a write oddly must not make the diff go stale-blind. Only
  # the kinds that provably cannot touch the tree are filtered out — and
  # those are the noisy ones, since agents read and grep constantly.
  @read_only_tool_kinds ~w(read search think fetch switch_mode)

  @doc """
  The current run's transcript: rows from the newest `:run_started`
  onwards (everything, when a run never started). Scoping by id rather
  than by run step keeps a dispatch failure — which is recorded before a
  run step exists — visible.
  """
  @spec list_run(pos_integer(), pos_integer()) :: [AgentEvent.t()]
  def list_run(task_id, limit \\ @default_limit) do
    run_start =
      Repo.one(
        from e in AgentEvent,
          where: e.task_id == ^task_id and e.kind == :run_started,
          order_by: [desc: e.id],
          limit: 1,
          select: e.id
      )

    from(e in AgentEvent, where: e.task_id == ^task_id)
    |> then(&if run_start, do: where(&1, [e], e.id >= ^run_start), else: &1)
    |> newest(limit)
  end

  @doc """
  The task's whole transcript across every run.
  """
  @spec list_all(pos_integer(), pos_integer()) :: [AgentEvent.t()]
  def list_all(task_id, limit \\ @default_limit) do
    from(e in AgentEvent, where: e.task_id == ^task_id) |> newest(limit)
  end

  @doc """
  Appends a transcript row and broadcasts it.
  """
  @spec record_event(pos_integer(), map()) :: AgentEvent.t()
  def record_event(task_id, attrs) do
    attrs = attrs |> Map.put(:task_id, task_id) |> stringify_data()

    %AgentEvent{}
    |> AgentEvent.changeset(attrs)
    |> Repo.insert!()
    |> broadcast()
  end

  @doc """
  Updates a row in place and broadcasts it. Nil attrs are dropped and
  `data` is merged, so a `tool_call_update` carrying only a status keeps
  the title recorded by the original `tool_call`.
  """
  @spec update_event(AgentEvent.t(), map()) :: AgentEvent.t()
  def update_event(%AgentEvent{} = event, attrs) do
    attrs =
      attrs
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> stringify_data()
      |> merge_data(event.data)

    event
    |> AgentEvent.changeset(attrs)
    |> Repo.update!()
    |> broadcast()
  end

  @doc """
  Whether a transcript row could mean the worktree changed — the signal
  behind the Diff tab's live refresh. `tool_kind` is the raw ACP kind.
  """
  @spec file_changing?(atom(), String.t() | nil) :: boolean()
  def file_changing?(:tool_call, tool_kind) when is_binary(tool_kind),
    do: tool_kind not in @read_only_tool_kinds

  def file_changing?(:tool_call, nil), do: true
  def file_changing?(:result, _tool_kind), do: true
  def file_changing?(_kind, _tool_kind), do: false

  defp newest(query, limit) do
    query
    |> order_by([e], desc: e.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp merge_data(%{data: data} = attrs, current) when is_map(data) do
    %{attrs | data: Map.merge(current || %{}, data)}
  end

  defp merge_data(attrs, _current), do: attrs

  # `data` is a jsonb column, so it comes back string-keyed. Normalize on
  # write too, or a broadcast struct and a reloaded row disagree.
  defp stringify_data(%{data: data} = attrs) when is_map(data) do
    %{attrs | data: Map.new(data, fn {key, value} -> {to_string(key), value} end)}
  end

  defp stringify_data(attrs), do: attrs

  defp broadcast(%AgentEvent{task_id: task_id} = event) do
    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      Tasks.task_topic(task_id),
      {:agent_feed, task_id, event}
    )

    event
  end
end

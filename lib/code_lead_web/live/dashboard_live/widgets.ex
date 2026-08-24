defmodule CodeLeadWeb.DashboardLive.Widgets do
  @moduledoc """
  The dashboard's panels: the two bar charts, the live run list, the
  attention queue, the completion list, the activity feed, the
  per-project row, and the live-session row.

  Every component takes precomputed scalars and rows — the LiveView
  resolves projects, spend, and process liveness before rendering.
  """

  use CodeLeadWeb, :html

  @doc """
  Renders a bar chart of a series, one bar per point.

  Color encodes one thing only — whether the point is today. The bar is
  itself the flex item because a percentage height resolves against the
  flex line, which only the container's fixed height makes definite.
  """
  attr :id, :string, required: true
  attr :series, :list, required: true, doc: "[%{date:, value:, label:}]"
  attr :height, :string, default: "h-24"
  attr :class, :any, default: nil

  def bar_chart(assigns) do
    assigns = assign(assigns, :max, Enum.max([1 | Enum.map(assigns.series, & &1.value)]))

    ~H"""
    <div id={@id} class={["flex items-end gap-[3px]", @height, @class]}>
      <div
        :for={point <- @series}
        class={[
          "min-h-[2px] flex-1 rounded-t-[3px]",
          cond do
            today?(point.date) -> "bg-accent"
            point.value > 0 -> "bg-accent-soft"
            true -> "bg-surface2"
          end
        ]}
        style={"height: #{bar_percent(point.value, @max)}%"}
        title={"#{Calendar.strftime(point.date, "%b %-d")} · #{point.label}"}
      />
    </div>
    """
  end

  @doc """
  Renders the shared date axis under a chart: first day, midpoint, today.
  """
  attr :series, :list, required: true

  def chart_axis(assigns) do
    ~H"""
    <div class="flex justify-between font-mono text-[10px] text-text3">
      <span>{axis_label(@series, 0)}</span>
      <span class="hidden sm:inline">{axis_label(@series, div(length(@series), 2))}</span>
      <span>Today</span>
    </div>
    """
  end

  @doc """
  Renders one live or pending run.
  """
  attr :run, :map, required: true
  attr :project_name, :string, required: true
  attr :live?, :boolean, required: true

  def run_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/projects/#{@run.project_id}/tasks/#{@run.id}"}
      class="flex items-center gap-2.5 rounded-[10px] px-1.5 py-1.5 hover:bg-surface2"
    >
      <.pulse_dot :if={@live?} class="bg-run" />
      <span
        :if={!@live?}
        class="inline-block size-1.5 shrink-0 rounded-full bg-warn"
        title="No runner process"
      />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[13px] font-medium text-text">{@run.title}</span>
        <span class="block truncate text-[11px] text-text3">
          {@project_name} · {run_state_label(@run.run_state)} · {Format.relative(@run.since)}
        </span>
      </span>
      <.agent_pill :if={@run.agent_name} name={@run.agent_name} harness={@run.harness} />
    </.link>
    """
  end

  @doc """
  Renders one task waiting on a human.
  """
  attr :task, :map, required: true
  attr :project_name, :string, required: true

  def attention_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/projects/#{@task.project_id}/tasks/#{@task.id}"}
      class="flex items-center gap-3 rounded-[10px] px-1.5 py-1.5 hover:bg-surface2"
    >
      <.badge variant={:warn}>{attention_label(@task.attention.type)}</.badge>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[13px] font-medium text-text">{@task.title}</span>
        <span class="block truncate text-[11px] text-text3">
          {@project_name}<span :if={@task.attention.detail}> · {@task.attention.detail}</span>
        </span>
      </span>
      <.timestamp id={"attention-at-#{@task.id}"} at={@task.at} />
    </.link>
    """
  end

  @doc """
  Renders one approved task with what it cost.
  """
  attr :task, :map, required: true
  attr :project_name, :string, required: true
  attr :spend, :map, default: nil
  attr :cost_mode, :atom, default: :exact

  def completed_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/projects/#{@task.project_id}/tasks/#{@task.id}"}
      class="flex items-center gap-3 rounded-[10px] px-1.5 py-1.5 hover:bg-surface2"
    >
      <span class="flex size-5 shrink-0 items-center justify-center rounded-[6px] bg-ok-soft">
        <.icon name="hero-check" class="size-3 text-ok" />
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[13px] font-medium text-text">{@task.title}</span>
        <span class="block truncate text-[11px] text-text3">{@project_name}</span>
      </span>
      <.cost_stat
        :if={@spend}
        cost_cents={@spend.cost_cents}
        tokens={@spend.tokens}
        duration_ms={@spend.duration_ms}
        cost_mode={@cost_mode}
        class="hidden sm:inline"
      />
      <.timestamp id={"completed-at-#{@task.id}"} at={@task.completed_at} />
    </.link>
    """
  end

  @doc """
  Renders one audit step in the cross-project activity feed.

  Not `timeline_entry/1`: that one is a connector-railed `<li>` for a
  single task's chronology, with nowhere to name the task it belongs to.
  """
  attr :entry, :map, required: true

  def activity_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/projects/#{@entry.project_id}/tasks/#{@entry.task_id}"}
      class="flex items-start gap-2.5 rounded-[10px] px-1.5 py-1.5 hover:bg-surface2"
    >
      <span class={[
        "mt-1 flex size-4 shrink-0 items-center justify-center rounded-[5px]",
        executor_chip(@entry.executor_type)
      ]}>
        <.icon name={executor_icon(@entry.executor_type)} class="size-[11px]" />
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[12.5px] text-text">
          {Format.step_summary(@entry.summary)}
        </span>
        <span class="block truncate text-[11px] text-text3">
          {@entry.task_title} · {Format.relative(@entry.at)}
        </span>
      </span>
    </.link>
    """
  end

  @doc """
  Renders one project's pipeline, attention, and spend.
  """
  attr :project, :map, required: true
  attr :summary, :map, required: true
  attr :spend, :map, required: true

  def project_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/projects/#{@project.id}/board"}
      class="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-[10px] px-1.5 py-2 hover:bg-surface2"
    >
      <span class="w-full truncate text-[13px] font-semibold text-text sm:w-auto sm:min-w-[160px] sm:flex-1">
        {@project.name}
      </span>

      <span class="flex items-center gap-1">
        <.pipeline_chip label="Plan" count={@summary.planning} />
        <.pipeline_chip label="Run" count={@summary.running} />
        <.pipeline_chip label="Rev" count={@summary.review} />
        <.pipeline_chip label="Done" count={@summary.done} />
      </span>

      <.badge :if={@summary.attention > 0} variant={:warn}>
        {@summary.attention} waiting
      </.badge>

      <span class="ml-auto flex min-w-[92px] flex-col items-end gap-1">
        <.cost_stat cost_cents={@spend.cost_cents} tokens={@spend.tokens} />
        <.meter
          :if={@project.budget_limit_cents}
          value={@spend.cost_cents}
          max={@project.budget_limit_cents}
          class="w-[92px]"
        />
      </span>
    </.link>
    """
  end

  @doc """
  Renders one live preview server or terminal shell with the control
  that ends it.

  `kind` only prefixes the ids and the label — which context module the
  click reaches is the caller's business, carried in `event`.
  """
  attr :kind, :string, required: true, doc: ~s("preview" | "terminal")
  attr :task_id, :integer, required: true
  attr :title, :string, default: nil
  attr :event, :string, required: true
  attr :confirm, :string, required: true

  def session_row(assigns) do
    ~H"""
    <div
      id={"session-row-#{@kind}-#{@task_id}"}
      class="flex items-center gap-2 rounded-[8px] px-1.5 py-1 hover:bg-surface2"
    >
      <span class="min-w-0 flex-1 truncate text-[11.5px] text-text3">
        {session_label(@task_id, @title)}
      </span>
      <button
        type="button"
        id={"close-#{@kind}-session-#{@task_id}"}
        phx-click={@event}
        phx-value-task-id={@task_id}
        data-confirm={@confirm}
        class="flex size-[22px] shrink-0 cursor-pointer items-center justify-center rounded-md text-text3 transition-colors hover:bg-warn-soft hover:text-warn"
        aria-label={"Close #{@kind} session for task ##{@task_id}"}
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true

  defp pipeline_chip(assigns) do
    ~H"""
    <span class={[
      "rounded-[6px] px-1.5 py-0.5 font-mono text-[11px]",
      (@count > 0 && "bg-surface2 text-text2") || "bg-surface2 text-text3"
    ]}>
      {@label} {@count}
    </span>
    """
  end

  defp bar_percent(0, _max), do: 0
  defp bar_percent(value, max), do: round(value / max * 100)

  defp today?(date), do: date == Date.utc_today()

  defp axis_label(series, index) do
    case Enum.at(series, index) do
      nil -> ""
      point -> Calendar.strftime(point.date, "%b %-d")
    end
  end

  # A session names its task, degrading to the bare id when the task is
  # gone — a registry outlives the row it points at.
  defp session_label(task_id, nil), do: "##{task_id}"
  defp session_label(task_id, title), do: "##{task_id} #{title}"

  defp run_state_label(:queued), do: "queued"
  defp run_state_label(:dispatched), do: "provisioning"
  defp run_state_label(:executing), do: "executing"
  defp run_state_label(:failed), do: "failed"
  defp run_state_label(other), do: to_string(other)

  defp attention_label(:run_failed), do: "Failed"
  defp attention_label(:review_ready), do: "Review"
  defp attention_label(:agent_question), do: "Question"
  defp attention_label(:permission_request), do: "Permission"
  defp attention_label(_other), do: "Attention"

  defp executor_chip(:human), do: "bg-accent-soft text-accent"
  defp executor_chip(:agent), do: "bg-run-soft text-run"
  defp executor_chip(_system), do: "bg-surface2 text-text3"

  defp executor_icon(:human), do: "hero-user"
  defp executor_icon(:agent), do: "hero-sparkles"
  defp executor_icon(_system), do: "hero-cog-6-tooth"
end

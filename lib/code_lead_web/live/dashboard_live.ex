defmodule CodeLeadWeb.DashboardLive do
  @moduledoc """
  The landing page: what the whole instance is doing right now, ordered
  by what a human has to act on — attention first, then throughput, then
  live activity, then a per-project breakdown.

  Everything on it is live. Metrics the data model cannot back are not
  rendered at all rather than shown as placeholders.

  It is org-wide, so it deliberately does not call
  `NavContext.put_stats/3`: the sidebar's attention pill and budget tile
  are project-scoped readouts, and pointing them at one arbitrary
  project's board would be wrong. See `docs/web-ui.md`.
  """

  use CodeLeadWeb, :live_view

  import CodeLeadWeb.DashboardLive.Widgets

  alias CodeLead.Accounts
  alias CodeLead.Agents
  alias CodeLead.Costs
  alias CodeLead.Preview
  alias CodeLead.Projects
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Tasks
  alias CodeLead.Terminal

  @window_days 14
  @refresh_ms 800
  @periodic_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Tasks.subscribe_org()
      # Before the snapshot below, deliberately: an event racing the
      # registry read then sits in the mailbox and is applied on top of
      # it. Reading first and subscribing after would drop it forever.
      Preview.subscribe_org()
      Terminal.subscribe_org()
      Process.send_after(self(), :periodic, @periodic_ms)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Dashboard",
       organization: Accounts.get_organization!(),
       refresh_timer: nil
     )
     |> load_dashboard()
     |> assign_sessions()}
  end

  ## Events

  @impl true
  def handle_info({:board_changed, _project_id, _task_id}, socket) do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, socket |> assign(refresh_timer: nil) |> load_dashboard()}
  end

  # Costs are recorded without any broadcast, so spend would otherwise
  # freeze at mount. The tick also re-renders relative timestamps and
  # rolls the page over UTC midnight.
  def handle_info(:periodic, socket) do
    Process.send_after(self(), :periodic, @periodic_ms)
    # Also the session reconcile: a session killed without running
    # `terminate/2` announces no close, so its id would linger in the
    # sets until a read of the registries puts them straight.
    {:noreply, socket |> load_dashboard() |> assign_sessions()}
  end

  def handle_info({:preview_session, lifecycle, task_id}, socket) do
    {:noreply, put_preview_session(socket, lifecycle, task_id)}
  end

  def handle_info({:terminal_session, lifecycle, task_id}, socket) do
    {:noreply, put_terminal_session(socket, lifecycle, task_id)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <header class="flex h-[58px] shrink-0 items-center gap-3.5 border-b border-border bg-surface px-4 sm:px-5">
        <Layouts.sidebar_toggle />
        <span class="truncate text-[15px] font-semibold text-text">Dashboard</span>
        <span
          :if={@summary.executing > 0}
          class="hidden items-center gap-1.5 rounded-full bg-run-soft px-2.5 py-1 text-[11px] font-semibold text-run sm:inline-flex"
        >
          <.pulse_dot />{@summary.executing} running
        </span>
        <div class="flex-1" />
        <span class="hidden font-mono text-[11px] text-text3 sm:inline">
          {Format.cents(@spend_today.cost_cents)} today
        </span>
      </header>

      <div class="min-h-0 flex-1 overflow-auto p-4 sm:p-5">
        <div :if={@projects == []} class="mx-auto w-full max-w-md pt-[6vh]">
          <.section_card label="Welcome">
            <p class="text-[13px] text-text2">
              A project is where tasks, repositories, and agents come together.
              Create one and the board opens up.
            </p>
            <div>
              <.button
                id="create-first-project"
                variant="primary"
                navigate={~p"/settings/projects/new"}
              >
                Create a project
              </.button>
            </div>
          </.section_card>
        </div>

        <div :if={@projects != []} class="mx-auto flex w-full max-w-[1240px] flex-col gap-3.5">
          <section class="grid grid-cols-2 gap-3.5">
            <.stat_tile
              id="tile-review"
              icon="hero-eye"
              label="Needs approval"
              value={to_string(@summary.review)}
              detail={attention_detail(@attention_tasks, [:review_ready], "Nothing in Review")}
              tone={(@summary.review > 0 && :warn) || :neutral}
            />
            <.stat_tile
              id="tile-waiting-input"
              icon="hero-chat-bubble-left-right"
              label="Agents waiting for input"
              value={to_string(@waiting_for_input)}
              detail={
                attention_detail(
                  @attention_tasks,
                  [:agent_question, :permission_request],
                  "Nothing waiting"
                )
              }
              tone={(@waiting_for_input > 0 && :warn) || :neutral}
            />
          </section>

          <section class="grid gap-3.5 lg:grid-cols-3">
            <.section_card label={"Tasks completed · last #{@window_days} days"} class="lg:col-span-2">
              <:actions>
                <span class="flex items-baseline gap-1.5">
                  <span class="font-mono text-[20px] font-semibold text-text">
                    {@completed_total}
                  </span>
                  <span class={["text-[11px] font-semibold", trend_class(@completed_trend)]}>
                    {trend_label(@completed_trend)}
                  </span>
                </span>
              </:actions>

              <.bar_chart id="chart-completed" series={@completion_series} />

              <div class="flex flex-col gap-1">
                <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
                  Spend
                </span>
                <.bar_chart id="chart-spend" series={@spend_bars} height="h-10" />
              </div>

              <.chart_axis series={@completion_series} />
            </.section_card>

            <div class="flex flex-col gap-3.5">
              <.stat_tile
                id="tile-lead-time"
                icon="hero-arrow-trending-down"
                label="Avg lead time"
                value={Format.duration(@avg_lead_time_ms)}
                detail={"Created → approved · #{@window_days} days"}
                tone={:accent}
              />
              <.stat_tile
                id="tile-spend-today"
                icon="hero-banknotes"
                label="Spend today"
                value={Format.cents(@spend_today.cost_cents)}
                detail={"#{Format.tokens(@spend_today.tokens)} tokens"}
                tone={:neutral}
              >
                <:meter>
                  <.meter
                    :if={@org_spend}
                    value={@org_spend.cost_cents}
                    max={@organization.budget_limit_cents}
                    class="mt-3"
                  />
                  <span
                    :if={@org_spend && @organization.budget_limit_cents}
                    class="mt-1.5 block font-mono text-[11px] text-text3"
                  >
                    {Format.cents(@org_spend.cost_cents)} of {Format.cents(
                      @organization.budget_limit_cents
                    )} this month
                  </span>
                </:meter>
              </.stat_tile>
              <.stat_tile
                id="tile-window-tokens"
                icon="hero-cpu-chip"
                label={"Tokens · #{@window_days} days"}
                value={Format.tokens(@window_tokens)}
                detail={"#{@window_runs} runs · #{Format.cents(@window_cost_cents)}"}
                tone={:neutral}
              />
            </div>
          </section>

          <section class="grid gap-3.5 lg:grid-cols-3">
            <.section_card label="Active runs">
              <.empty_state :if={@active_runs == []} icon="hero-moon" title="Nothing running">
                Move a task to Running to put an agent to work.
              </.empty_state>
              <div :if={@active_runs != []} class="flex flex-col">
                <.run_row
                  :for={run <- @active_runs}
                  run={run}
                  project_name={project_name(@projects_by_id, run.project_id)}
                  live?={MapSet.member?(@live_task_ids, run.id)}
                />
              </div>
            </.section_card>

            <.section_card label="Waiting on you" class="lg:col-span-2">
              <.empty_state :if={@attention_tasks == []} icon="hero-check-circle" title="All clear">
                Nothing is waiting on a decision right now.
              </.empty_state>
              <div :if={@attention_tasks != []} class="flex flex-col">
                <.attention_row
                  :for={task <- @attention_tasks}
                  task={task}
                  project_name={project_name(@projects_by_id, task.project_id)}
                />
              </div>
            </.section_card>
          </section>

          <section class="grid gap-3.5 lg:grid-cols-3">
            <.section_card label="Recently completed" class="lg:col-span-2">
              <.empty_state :if={@recent_done == []} icon="hero-inbox" title="Nothing approved yet">
                Approve a task in Review and it lands here.
              </.empty_state>
              <div :if={@recent_done != []} class="flex flex-col">
                <.completed_row
                  :for={task <- @recent_done}
                  task={task}
                  project_name={project_name(@projects_by_id, task.project_id)}
                  spend={@done_spend[task.id]}
                  cost_mode={cost_mode(@done_spend[task.id])}
                />
              </div>
            </.section_card>

            <.section_card label="Activity">
              <.empty_state :if={@activity == []} icon="hero-list-bullet" title="No activity yet" />
              <div :if={@activity != []} class="flex flex-col">
                <.activity_row :for={entry <- @activity} entry={entry} />
              </div>
            </.section_card>
          </section>

          <.section_card label="Projects · spend this month">
            <div class="flex flex-col">
              <.project_row
                :for={project <- @projects}
                project={project}
                summary={Map.get(@project_summaries, project.id, @empty_summary)}
                spend={Map.get(@project_spend, project.id, @empty_spend)}
              />
            </div>
          </.section_card>

          <section class="grid grid-cols-2 gap-3.5">
            <.stat_tile
              id="tile-failed"
              icon="hero-x-circle"
              label="Failed runs"
              value={to_string(@summary.failed)}
              detail={(@summary.failed > 0 && "Waiting on retry or abort") || "No failures"}
              tone={(@summary.failed > 0 && :warn) || :ok}
            />
            <.stat_tile
              id="tile-stalled"
              icon="hero-clock"
              label="Stalled runs"
              value={to_string(@stalled_count)}
              detail={(@stalled_count > 0 && "Executing with no runner") || "All clear"}
              tone={(@stalled_count > 0 && :warn) || :ok}
            />
          </section>

          <%!-- What a restart would interrupt: since ADR-0013 a graceful
          shutdown stops every session, so these are the pre-upgrade check.
          Tone is :run rather than :warn — someone working is not a defect. --%>
          <section class="grid grid-cols-2 gap-3.5">
            <.stat_tile
              id="tile-previews"
              icon="hero-window"
              label="Preview servers"
              value={to_string(MapSet.size(@preview_task_ids))}
              detail={session_detail(@preview_task_ids, @session_titles, "None running")}
              tone={(MapSet.size(@preview_task_ids) > 0 && :run) || :neutral}
            />
            <.stat_tile
              id="tile-terminals"
              icon="hero-command-line"
              label="Terminal sessions"
              value={to_string(MapSet.size(@terminal_task_ids))}
              detail={session_detail(@terminal_task_ids, @session_titles, "None open")}
              tone={(MapSet.size(@terminal_task_ids) > 0 && :run) || :neutral}
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Loading

  defp load_dashboard(socket) do
    projects = Projects.list_projects()
    organization = socket.assigns.organization

    active_runs = Tasks.active_runs()
    live_task_ids = MapSet.new(RunSupervisor.active_task_ids())
    recent_done = Tasks.recently_completed(6)
    completions = Tasks.completions_by_day(@window_days)
    completion_series = completion_series(completions)
    spend_series = Costs.daily_series(@window_days)
    attention_counts = Tasks.attention_counts()

    assign(socket,
      window_days: @window_days,
      empty_spend: %{tokens: 0, cost_cents: 0},
      empty_summary: %{planning: 0, running: 0, review: 0, done: 0, attention: 0},
      projects: projects,
      projects_by_id: Map.new(projects, &{&1.id, &1}),
      summary: Tasks.board_summary(),
      attention_tasks: Tasks.org_attention_tasks(6),
      waiting_for_input:
        Map.get(attention_counts, :agent_question, 0) +
          Map.get(attention_counts, :permission_request, 0),
      active_runs: active_runs,
      live_task_ids: live_task_ids,
      stalled_count: stalled_count(active_runs, live_task_ids),
      completion_series: completion_series,
      completed_total: Enum.sum(Enum.map(completion_series, & &1.value)),
      completed_trend: trend(completions),
      avg_lead_time_ms: Tasks.avg_lead_time_ms(@window_days),
      recent_done: recent_done,
      done_spend: Costs.spend_by_task(Enum.map(recent_done, & &1.id)),
      activity: Tasks.recent_activity(9),
      spend_bars: spend_bars(spend_series),
      window_tokens: Enum.sum(Enum.map(spend_series, & &1.tokens)),
      window_cost_cents: Enum.sum(Enum.map(spend_series, & &1.cost_cents)),
      window_runs: Enum.sum(Enum.map(spend_series, & &1.run_count)),
      spend_today: Costs.org_spend_today(),
      org_spend: org_spend(organization),
      project_summaries: Tasks.project_summaries(),
      project_spend: Costs.spend_by_project_month()
    )
  end

  # One armed timer at a time, so a burst of transitions during a run
  # coalesces into a single reload instead of one per event.
  defp schedule_refresh(%{assigns: %{refresh_timer: nil}} = socket),
    do: assign(socket, refresh_timer: Process.send_after(self(), :refresh, @refresh_ms))

  defp schedule_refresh(socket), do: socket

  # The registries are the process truth; the org-wide broadcasts keep
  # the sets exact between reads. Deliberately outside `load_dashboard/1`
  # — a preview starting must not cost ~17 grouped queries.
  defp assign_sessions(socket) do
    socket
    |> assign(
      preview_task_ids: MapSet.new(Preview.active_task_ids()),
      terminal_task_ids: MapSet.new(Terminal.active_task_ids())
    )
    |> assign_session_titles()
  end

  defp assign_session_titles(socket) do
    ids =
      socket.assigns.preview_task_ids
      |> MapSet.union(socket.assigns.terminal_task_ids)
      |> MapSet.to_list()

    assign(socket, session_titles: Tasks.titles(ids))
  end

  # A close is a delete, never a recount: the session broadcasts from
  # `terminate/2` while it is still registered, so re-reading the
  # registry here would count it one too many — and nothing would follow
  # to correct it before the next tick.
  defp put_preview_session(socket, lifecycle, task_id) do
    socket
    |> assign(
      preview_task_ids: apply_lifecycle(socket.assigns.preview_task_ids, lifecycle, task_id)
    )
    |> assign_session_titles()
  end

  defp put_terminal_session(socket, lifecycle, task_id) do
    socket
    |> assign(
      terminal_task_ids: apply_lifecycle(socket.assigns.terminal_task_ids, lifecycle, task_id)
    )
    |> assign_session_titles()
  end

  defp apply_lifecycle(task_ids, :opened, task_id), do: MapSet.put(task_ids, task_id)
  defp apply_lifecycle(task_ids, :closed, task_id), do: MapSet.delete(task_ids, task_id)

  # The month-to-date total is only ever the budget meter's numerator,
  # so with no limit configured it is two queries nobody reads.
  defp org_spend(%{budget_limit_cents: nil, budget_limit_tokens: nil}), do: nil
  defp org_spend(_organization), do: Costs.org_spend_month()

  # `run_state` is the database's belief; the registry is the process
  # truth. A task executing without a runner has lost it.
  defp stalled_count(active_runs, live_task_ids) do
    Enum.count(active_runs, fn run ->
      run.run_state == :executing and not MapSet.member?(live_task_ids, run.id)
    end)
  end

  ## Presentation helpers

  defp completion_series(completions) do
    for offset <- (@window_days - 1)..0//-1 do
      date = Date.add(Date.utc_today(), -offset)
      count = Map.get(completions, date, 0)
      %{date: date, value: count, label: "#{count} completed"}
    end
  end

  defp spend_bars(spend_series) do
    Enum.map(spend_series, fn day ->
      %{date: day.date, value: day.cost_cents, label: Format.cents(day.cost_cents)}
    end)
  end

  # Week over week, as a percentage. Nil when the previous week had
  # nothing to compare against — "+100%" off a base of zero says nothing.
  defp trend(completions) do
    today = Date.utc_today()
    recent = window_sum(completions, today, 0, 7)
    previous = window_sum(completions, today, 7, 7)

    if previous == 0, do: nil, else: round((recent - previous) / previous * 100)
  end

  defp window_sum(completions, today, offset, days) do
    Enum.reduce((offset + days - 1)..offset//-1, 0, fn back, acc ->
      acc + Map.get(completions, Date.add(today, -back), 0)
    end)
  end

  defp trend_label(nil), do: "last #{@window_days} days"
  defp trend_label(percent) when percent > 0, do: "+#{percent}% vs prior week"
  defp trend_label(percent), do: "#{percent}% vs prior week"

  defp trend_class(nil), do: "text-text3"
  defp trend_class(percent) when percent > 0, do: "text-ok"
  defp trend_class(percent) when percent < 0, do: "text-warn"
  defp trend_class(_zero), do: "text-text3"

  defp attention_detail(attention_tasks, types, empty_message) do
    case Enum.find(attention_tasks, &(&1.attention.type in types)) do
      nil -> empty_message
      task -> "Oldest #{Format.relative(task.at)}"
    end
  end

  # Two names then a tally: the detail line is one truncated row, and an
  # operator needs to recognise whose session it is, not read a manifest.
  # Sorted because a MapSet has no order and the line would otherwise
  # reshuffle itself between renders.
  defp session_detail(task_ids, titles, empty_message) do
    case Enum.sort(task_ids) do
      [] -> empty_message
      ids -> ids |> Enum.map(&task_label(&1, Map.get(titles, &1))) |> summarize(2)
    end
  end

  defp task_label(task_id, nil), do: "##{task_id}"
  defp task_label(task_id, title), do: "##{task_id} #{title}"

  defp summarize(labels, limit) when length(labels) <= limit, do: Enum.join(labels, " · ")

  defp summarize(labels, limit) do
    {shown, rest} = Enum.split(labels, limit)
    Enum.join(shown ++ ["+#{length(rest)} more"], " · ")
  end

  defp project_name(projects_by_id, project_id) do
    case Map.get(projects_by_id, project_id) do
      nil -> "Unknown project"
      project -> project.name
    end
  end

  defp cost_mode(nil), do: :exact
  defp cost_mode(%{provider_kinds: kinds}), do: Agents.billing_mode(kinds)
end

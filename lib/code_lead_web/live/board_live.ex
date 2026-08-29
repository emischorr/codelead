defmodule CodeLeadWeb.BoardLive do
  @moduledoc """
  The project Kanban board: Planning / Running / Review / Done. Desktop
  shows all four columns; mobile shows one at a time behind a segmented
  switcher, which a horizontal swipe on the pane can also step through —
  the pane translates with the finger (bounded, with resistance) and
  springs back or slides the rest of the way off on release.
  Subscribes to the project's board topic and reloads on any task change.
  """
  use CodeLeadWeb, :live_view

  alias CodeLead.Accounts.Policy
  alias CodeLead.Agents
  alias CodeLead.Costs
  alias CodeLead.Projects
  alias CodeLead.Reviews
  alias CodeLead.Runtime
  alias CodeLead.Runtime.LiveRuns
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLeadWeb.FlashMessages
  alias CodeLeadWeb.Format
  alias CodeLeadWeb.FormOptions
  alias CodeLeadWeb.NavContext
  alias CodeLeadWeb.ScheduleForm

  @columns [planning: "Planning", running: "Running", review: "Review", done: "Done"]
  @priorities [Low: "low", Normal: "normal", High: "high", Urgent: "urgent"]

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    project = Projects.get_project!(project_id)
    scope = socket.assigns.current_scope

    if connected?(socket), do: Tasks.subscribe_board(project.id)

    socket =
      socket
      |> assign(
        page_title: "Board",
        project: project,
        can_operate?: Policy.can?(scope, :operate_task, project.id),
        can_create?: Policy.can?(scope, :create_task, project.id),
        columns: @columns,
        mobile_column: :planning,
        scheduling_task: nil,
        schedule_form: nil
      )
      |> load_board()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :new}} = socket) do
    socket = maybe_set_mobile_column(socket, params["column"])
    {:noreply, assign_new_task_form(socket, %{"work_type" => "code"})}
  end

  def handle_params(params, _uri, socket) do
    socket = maybe_set_mobile_column(socket, params["column"])
    {:noreply, assign(socket, new_form: nil)}
  end

  @impl true
  def handle_event("start_task", %{"id" => id}, socket) do
    case Runtime.start_task(socket.assigns.current_scope, Tasks.get_task!(id)) do
      {:ok, _task} ->
        {:noreply, load_board(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.transition_error(reason))}
    end
  end

  def handle_event("open_schedule", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, scheduling_task: Tasks.get_task!(id), schedule_form: ScheduleForm.new())}
  end

  def handle_event("close_schedule", _params, socket) do
    {:noreply, close_schedule(socket)}
  end

  def handle_event("schedule_task", %{"schedule" => params}, socket) do
    case ScheduleForm.parse(params) do
      {:ok, scheduled_at} ->
        socket.assigns.current_scope
        |> Runtime.start_task(socket.assigns.scheduling_task, scheduled_at: scheduled_at)
        |> case do
          {:ok, _task} ->
            {:noreply, socket |> close_schedule() |> load_board()}

          {:error, reason} ->
            {:noreply,
             socket
             |> close_schedule()
             |> put_flash(:error, FlashMessages.transition_error(reason))}
        end

      {:error, form} ->
        {:noreply, assign(socket, schedule_form: form)}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    case Tasks.archive(socket.assigns.current_scope, Tasks.get_task!(id)) do
      {:ok, _task} ->
        {:noreply, load_board(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.transition_error(reason))}
    end
  end

  def handle_event("select_column", %{"column" => column}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/projects/#{socket.assigns.project.id}/board?column=#{column}",
       replace: true
     )}
  end

  def handle_event("validate", %{"task" => params}, socket) do
    {:noreply, assign_new_task_form(socket, params)}
  end

  def handle_event("create_task", %{"task" => params}, socket) do
    case Tasks.create_task(socket.assigns.current_scope, socket.assigns.project.id, params) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Task created.")
         |> push_patch(to: ~p"/projects/#{socket.assigns.project.id}/board")
         |> load_board()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, FlashMessages.transition_error(:unauthorized))}

      {:error, changeset} ->
        {:noreply, assign(socket, new_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_info({:board_changed, _project_id, _task_id}, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp close_schedule(socket), do: assign(socket, scheduling_task: nil, schedule_form: nil)

  defp maybe_set_mobile_column(socket, nil), do: socket

  defp maybe_set_mobile_column(socket, column) do
    case Enum.find(Keyword.keys(@columns), &(Atom.to_string(&1) == column)) do
      nil -> socket
      column -> assign(socket, mobile_column: column)
    end
  end

  defp load_board(socket) do
    project = socket.assigns.project
    board = Tasks.board(project.id)
    tasks = board |> Map.values() |> List.flatten()
    task_ids = Enum.map(tasks, & &1.id)
    review_ids = Enum.map(board.review, & &1.id)

    # A task waiting on its own clock is not in line behind anything,
    # so it takes no position — numbering it would leave gaps in the
    # sequence the other cards show.
    queued_positions =
      Tasks.queued_tasks()
      |> Enum.reject(&Task.scheduled?/1)
      |> Enum.with_index(1)
      |> Map.new(fn {task, position} -> {task.id, position} end)

    socket
    |> assign(
      board: board,
      spend: Costs.spend_by_task(task_ids),
      today_spend: Costs.project_spend_today(project.id),
      running_count: Enum.count(board.running, &(&1.run_state == :executing)),
      queued_positions: queued_positions,
      review_verdicts: Reviews.verdicts_by_task(review_ids),
      reviewer_counts: Map.new(review_ids, &{&1, length(Tasks.reviewers(&1))}),
      done_notes: Tasks.commit_notes(Enum.map(board.done, & &1.id)),
      # Live-process truth, not task state: surveys write nothing to the
      # row, so the board reads the registry on every (re)load.
      surveying: MapSet.new(LiveRuns.surveying_task_ids()),
      agents: Map.new(Agents.list_agents(project.id), &{&1.id, &1})
    )
    |> NavContext.put_stats(Costs.project_spend_month(project.id))
  end

  defp assign_new_task_form(socket, params) do
    work_type = parse_work_type(params["work_type"])
    project_id = socket.assigns.project.id
    params = maybe_prefill_repository(params, project_id)

    assign(socket,
      new_form: to_form(Task.create_changeset(%Task{}, params)),
      repositories: Projects.list_repositories(project_id),
      executors: Agents.eligible_executors(work_type, project_id)
    )
  end

  # Only prefills on the modal's first render (no "repository_id" key yet)
  # — every later "validate" event carries the field's current value, and
  # overwriting that on each change would fight the user's own selection.
  defp maybe_prefill_repository(params, project_id) do
    if Map.has_key?(params, "repository_id") do
      params
    else
      case Projects.default_repository(project_id) do
        nil -> params
        repository -> Map.put(params, "repository_id", repository.id)
      end
    end
  end

  defp parse_work_type("design"), do: :design
  defp parse_work_type("content"), do: :content
  defp parse_work_type("file"), do: :file
  defp parse_work_type(_), do: :code

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
      <header class="flex h-[58px] shrink-0 items-center gap-3.5 border-b border-border bg-surface px-4 sm:px-5">
        <Layouts.sidebar_toggle />
        <.project_dot color={@project.color} />
        <span class="truncate text-[15px] font-semibold text-text">{@project.name}</span>
        <span
          :if={@running_count > 0}
          class="hidden items-center gap-1.5 rounded-full bg-run-soft px-2.5 py-1 text-xs font-semibold text-run sm:inline-flex"
        >
          <span class="size-1.5 animate-pulse rounded-full bg-run" /> {@running_count} running
        </span>
        <span class="hidden font-mono text-xs text-text2 md:inline">
          {Format.cents(@today_spend.cost_cents)} today
        </span>
        <div class="flex-1" />
        <.button
          :if={@can_create?}
          variant="primary"
          patch={~p"/projects/#{@project.id}/board/new"}
          id="new-task-button"
          class="max-lg:hidden!"
        >
          <.icon name="hero-plus" class="size-3.5" /> New task
        </.button>
      </header>

      <%!-- Desktop hands scrolling to the individual columns so the headers stay
            put; below `lg` there is only one column, so the pane scrolls it. --%>
      <div class="min-h-0 flex-1 overflow-y-auto p-4 sm:p-5 lg:overflow-hidden">
        <%!-- Desktop: all four columns --%>
        <div class="hidden gap-4 lg:grid lg:h-full lg:grid-cols-4">
          <.board_column
            :for={{column, title} <- @columns}
            id={"board-column-#{column}"}
            column={column}
            title={title}
            tasks={@board[column]}
            ctx={board_ctx(assigns)}
            id_prefix=""
          />
        </div>

        <%!-- Mobile: segmented switcher + one column --%>
        <div class="overflow-x-hidden lg:hidden">
          <div class="mb-3 flex gap-1 overflow-x-auto rounded-[11px] bg-surface2 p-1">
            <button
              :for={{column, title} <- @columns}
              type="button"
              phx-click="select_column"
              phx-value-column={column}
              class={[
                "flex-1 whitespace-nowrap rounded-lg px-2 py-1.5 text-xs",
                column == @mobile_column && "bg-surface font-bold text-text shadow-sm",
                column != @mobile_column && "font-semibold text-text2"
              ]}
            >
              {title}
              <span class="ml-0.5 font-mono text-[10.5px] text-text3">
                {length(@board[column])}
              </span>
            </button>
          </div>
          <div
            id="mobile-board-pane"
            phx-hook=".SwipeColumn"
            class="touch-pan-y"
            data-column={@mobile_column}
            data-columns={Enum.map_join(@columns, ",", fn {column, _title} -> column end)}
          >
            <.board_column
              id={"m-board-column-#{@mobile_column}"}
              column={@mobile_column}
              title={@columns[@mobile_column]}
              tasks={@board[@mobile_column]}
              ctx={board_ctx(assigns)}
              id_prefix="m-"
              headerless
            />
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SwipeColumn">
        // Mobile-only pane navigation: a horizontal drag translates the
        // pane with the finger — bounded, with more resistance at the
        // ends where there is no adjacent column — so the gesture reads
        // as "this is going to swipe." A commit-worthy release slides the
        // pane the rest of the way off and fires the same "select_column"
        // event the segmented switcher buttons send; anything short of
        // that springs back. Never touches task state.
        export default {
          mounted() {
            this.touch = null
            this.axis = null
            this.committing = false
            this.resetTimer = null

            const rubberBand = (delta, max) => (delta * max) / (Math.abs(delta) + max)

            this.onTouchStart = (e) => {
              if (e.touches.length !== 1) { this.touch = null; return }
              const t = e.touches[0]
              this.touch = {x: t.clientX, y: t.clientY, at: Date.now()}
              this.axis = null
              this.el.style.transition = "none"
            }

            this.onTouchMove = (e) => {
              if (!this.touch) { return }
              const t = e.touches[0]
              const dx = t.clientX - this.touch.x
              const dy = t.clientY - this.touch.y

              if (this.axis === null && Math.max(Math.abs(dx), Math.abs(dy)) > 10) {
                this.axis = Math.abs(dx) > Math.abs(dy) * 1.5 ? "x" : "y"
              }
              if (this.axis !== "x") { return }

              e.preventDefault()

              const columns = this.el.dataset.columns.split(",")
              const index = columns.indexOf(this.el.dataset.column)
              const hasTarget = dx < 0 ? index < columns.length - 1 : index > 0
              const max = hasTarget ? Math.min(this.el.clientWidth * 0.3, 120) : 24

              this.el.style.transform = `translateX(${rubberBand(dx, max)}px)`
            }

            this.onTouchEnd = (e) => {
              if (!this.touch) { return }
              const t = e.changedTouches[0]
              const dx = t.clientX - this.touch.x
              const dy = t.clientY - this.touch.y
              const elapsed = Date.now() - this.touch.at
              const dragged = this.axis === "x"
              this.touch = null
              this.axis = null

              if (!dragged) { return }

              this.el.style.transition = "transform 200ms ease-out"

              const MIN_DISTANCE = 60
              const columns = this.el.dataset.columns.split(",")
              const index = columns.indexOf(this.el.dataset.column)
              const nextIndex = dx < 0 ? index + 1 : index - 1
              const withinAngle = Math.abs(dx) >= Math.abs(dy) * 1.5
              const commit =
                Math.abs(dx) >= MIN_DISTANCE && withinAngle && elapsed <= 600 &&
                nextIndex >= 0 && nextIndex < columns.length

              if (commit) {
                this.el.style.transform =
                  `translateX(${dx < 0 ? -this.el.clientWidth : this.el.clientWidth}px)`
                this.committing = true
                this.pushEvent("select_column", {column: columns[nextIndex]})
                clearTimeout(this.resetTimer)
                this.resetTimer = setTimeout(() => this.resetTransform(), 800)
              } else {
                this.el.style.transform = "translateX(0px)"
                this.el.addEventListener("transitionend", () => { this.el.style.transition = "" }, {once: true})
              }
            }

            this.onTouchCancel = () => {
              this.touch = null
              this.axis = null
              this.el.style.transition = "transform 200ms ease-out"
              this.el.style.transform = "translateX(0px)"
              this.el.addEventListener("transitionend", () => { this.el.style.transition = "" }, {once: true})
            }

            this.el.addEventListener("touchstart", this.onTouchStart, {passive: true})
            this.el.addEventListener("touchmove", this.onTouchMove, {passive: false})
            this.el.addEventListener("touchend", this.onTouchEnd, {passive: true})
            this.el.addEventListener("touchcancel", this.onTouchCancel, {passive: true})
          },

          updated() {
            // Fires once the swiped-to column's markup has landed. Reset
            // now so the new pane appears already in place instead of
            // the old one snapping back into view first.
            if (this.committing) {
              this.committing = false
              clearTimeout(this.resetTimer)
              this.resetTransform()
            }
          },

          resetTransform() {
            this.el.style.transition = "none"
            this.el.style.transform = "translateX(0px)"
            requestAnimationFrame(() => { this.el.style.transition = "" })
          },

          destroyed() {
            clearTimeout(this.resetTimer)
            this.el.removeEventListener("touchstart", this.onTouchStart)
            this.el.removeEventListener("touchmove", this.onTouchMove)
            this.el.removeEventListener("touchend", this.onTouchEnd)
            this.el.removeEventListener("touchcancel", this.onTouchCancel)
          }
        }
      </script>

      <.fab :if={@can_create?} patch={~p"/projects/#{@project.id}/board/new"} label="New task" />

      <.new_task_modal
        :if={@live_action == :new && @new_form}
        form={@new_form}
        project={@project}
        repositories={@repositories}
        executors={@executors}
      />

      <.schedule_modal
        :if={@scheduling_task}
        form={@schedule_form}
        task_title={@scheduling_task.title}
      />
    </Layouts.app>
    """
  end

  defp board_ctx(assigns) do
    Map.take(assigns, [
      :project,
      :can_operate?,
      :spend,
      :agents,
      :queued_positions,
      :review_verdicts,
      :reviewer_counts,
      :done_notes,
      :surveying
    ])
  end

  attr :id, :string, required: true
  attr :column, :atom, required: true
  attr :title, :string, required: true
  attr :tasks, :list, required: true
  attr :ctx, :map, required: true
  attr :id_prefix, :string, default: ""
  attr :headerless, :boolean, default: false

  defp board_column(assigns) do
    ~H"""
    <div id={@id} class="flex min-h-0 min-w-0 flex-col gap-2.5">
      <div :if={!@headerless} class="flex shrink-0 items-center gap-2 px-1">
        <span class="text-[11.5px] font-semibold uppercase tracking-widest text-text2">
          {@title}
        </span>
        <span class="rounded-[7px] bg-surface2 px-1.5 font-mono text-[11px] text-text3">
          {length(@tasks)}
        </span>
      </div>
      <%!-- Inert on mobile: with no definite height above it, `flex-1` resolves
            to auto and the cards grow the board pane instead. --%>
      <div class="flex min-h-0 flex-1 flex-col gap-2.5 overflow-y-auto">
        <.empty_state :if={@tasks == []} title="No tasks" icon="hero-inbox" />
        <.board_card
          :for={task <- @tasks}
          id={"#{@id_prefix}task-card-#{task.id}"}
          task={task}
          column={@column}
          ctx={@ctx}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :task, :map, required: true
  attr :column, :atom, required: true
  attr :ctx, :map, required: true

  defp board_card(assigns) do
    agent = assigns.ctx.agents[assigns.task.agent_id]

    spend =
      assigns.ctx.spend[assigns.task.id] ||
        %{cost_cents: 0, tokens: 0, duration_ms: 0, provider_kinds: []}

    assigns =
      assign(assigns,
        agent_name: agent && agent.name,
        harness: agent && agent.harness,
        spend: spend,
        cost_mode: Agents.billing_mode(spend.provider_kinds)
      )

    ~H"""
    <.task_card
      id={@id}
      title={@task.title}
      description={@task.description}
      agent_name={@agent_name}
      harness={@harness}
      cost_cents={@spend.cost_cents}
      tokens={@spend.tokens}
      duration_ms={@spend.duration_ms}
      cost_mode={@cost_mode}
      navigate={~p"/projects/#{@ctx.project.id}/tasks/#{@task.id}?column=#{@column}"}
      warn={@task.attention != nil}
      muted={@column == :done}
    >
      <:corner :if={@task.attention}>
        <.badge variant={:warn}>{attention_badge(@task.attention.type)}</.badge>
      </:corner>
      <:footer>
        <.card_footer task={@task} column={@column} ctx={@ctx} card_id={@id} />
      </:footer>
    </.task_card>
    """
  end

  defp attention_badge(:agent_question), do: "Question"
  defp attention_badge(:permission_request), do: "Permission"
  defp attention_badge(:review_ready), do: "Needs approval"
  defp attention_badge(:run_failed), do: "Failed"
  defp attention_badge(:finalize_failed), do: "Finalize failed"
  defp attention_badge(:finalize_interrupted), do: "Interrupted"
  defp attention_badge(_), do: "Attention"

  attr :task, :map, required: true
  attr :column, :atom, required: true
  attr :ctx, :map, required: true
  # The card's own id, so the desktop and mobile copies of a card don't
  # give their buttons the same one.
  attr :card_id, :string, required: true

  defp card_footer(%{column: :planning} = assigns) do
    agent = assigns.ctx.agents[assigns.task.agent_id]

    assigns =
      assign(assigns,
        startable?: Runtime.startable?(assigns.task, agent),
        surveying?: MapSet.member?(assigns.ctx.surveying, assigns.task.id)
      )

    ~H"""
    <div class="flex items-center gap-1.5 text-[11px] text-text3">
      <span class="font-mono">{@task.work_type} · {@task.target}</span>
      <span
        :if={@surveying?}
        id={"#{@card_id}-surveying-hint"}
        class="inline-flex items-center gap-1.5 rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[10.5px] font-semibold text-text2"
      >
        <span class="size-1.5 animate-pulse rounded-full bg-accent" /> surveying
      </span>
      <div :if={@startable? and @ctx.can_operate?} class="ml-auto flex items-center">
        <button
          type="button"
          phx-click="start_task"
          phx-value-id={@task.id}
          id={"#{@card_id}-start"}
          class="cursor-pointer rounded-l-md px-1.5 py-0.5 font-semibold text-accent hover:bg-accent-soft"
        >
          Start ▸
        </button>
        <button
          type="button"
          phx-click="open_schedule"
          phx-value-id={@task.id}
          id={"#{@card_id}-schedule"}
          title="Schedule this run"
          aria-label="Schedule this run"
          class="cursor-pointer rounded-r-md border-l border-border px-1.5 py-0.5 text-accent hover:bg-accent-soft"
        >
          <.icon name="hero-clock" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  defp card_footer(%{column: :running, task: %{run_state: :queued}} = assigns) do
    assigns =
      assign(assigns,
        position: assigns.ctx.queued_positions[assigns.task.id],
        scheduled?: Task.scheduled?(assigns.task)
      )

    ~H"""
    <span
      :if={@scheduled?}
      class="inline-flex items-center gap-1.5 rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[10.5px] font-semibold text-text2"
    >
      ⏱ starts {Format.absolute(@task.scheduled_at)}
    </span>
    <span
      :if={!@scheduled?}
      class="inline-flex items-center gap-1.5 rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[10.5px] font-semibold text-text2"
    >
      ⏸ queued{if @position, do: " · ##{@position}"}
    </span>
    """
  end

  defp card_footer(%{column: :running, task: %{run_state: :failed}} = assigns) do
    ~H"""
    <div class="text-[11.5px] font-medium text-warn">
      {(@task.attention && @task.attention.detail) || "Run failed — retry or cancel."}
    </div>
    """
  end

  defp card_footer(%{column: :running} = assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div :if={@task.attention && @task.attention.detail} class="text-[11.5px] font-medium text-warn">
        {@task.attention.detail}
      </div>
      <span :if={!@task.attention} class="flex items-center gap-1.5 font-mono text-[10.5px] text-run">
        <span class="size-1.5 animate-pulse rounded-full bg-run" />
        {if @task.run_state == :executing, do: "running", else: @task.run_state} · since {Format.relative(
          @task.updated_at
        )}
      </span>
    </div>
    """
  end

  defp card_footer(%{column: :review} = assigns) do
    verdicts = assigns.ctx.review_verdicts[assigns.task.id] || []
    settled = Enum.reject(verdicts, &is_nil/1)
    counts = Enum.frequencies(settled)
    reviewer_count = assigns.ctx.reviewer_counts[assigns.task.id] || 0
    pending? = reviewer_count > 0 and length(settled) < reviewer_count

    assigns =
      assign(assigns,
        counts: counts,
        reviewer_count: reviewer_count,
        pending?: pending?,
        settled: settled
      )

    ~H"""
    <div class="flex items-center gap-1.5 text-[11.5px] text-text2">
      <span
        :if={@task.run_state == :finalizing}
        id={"#{@card_id}-finalizing-hint"}
        class="inline-flex items-center gap-1.5 rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[10.5px] font-semibold text-text2"
      >
        <span class="size-1.5 animate-pulse rounded-full bg-accent" /> finalizing
      </span>
      <span :if={@pending?} class="inline-flex items-center gap-1.5">
        <span class="size-1.5 animate-pulse rounded-full bg-text3" /> Reviewer running…
      </span>
      <span :if={!@pending? && @settled != []}>
        {@reviewer_count} {if @reviewer_count == 1, do: "reviewer", else: "reviewers"}
        <span :if={@counts[:pass]} class="font-semibold text-ok">· {@counts[:pass]} pass</span>
        <span :if={@counts[:concerns]} class="font-semibold text-warn">
          · {@counts[:concerns]} concerns
        </span>
        <span :if={@counts[:block]} class="font-semibold text-del-text">
          · {@counts[:block]} block
        </span>
      </span>
      <span :if={!@pending? && @settled == []}>Awaiting your review</span>
    </div>
    """
  end

  defp card_footer(%{column: :done} = assigns) do
    # A done card links either the forge (repo targets) or the artifact
    # (folder targets) — never both, so one `ml-auto` decides the layout.
    assigns =
      assigns
      |> assign(:note, assigns.ctx.done_notes[assigns.task.id])
      |> assign(:artifact?, assigns.task.target == :folder)
      |> assign(:link?, assigns.task.pr_url != nil or assigns.task.target == :folder)

    ~H"""
    <div class="flex items-center gap-1.5">
      <span class="truncate font-mono text-[11px] text-ok">✓ {@note || "completed"}</span>
      <.link
        :if={@task.pr_url}
        href={@task.pr_url}
        target="_blank"
        rel="noopener noreferrer"
        id={"#{@card_id}-forge-link"}
        class="ml-auto shrink-0 rounded-md px-1.5 py-0.5 text-[11px] font-semibold text-accent hover:bg-surface2"
      >
        {Format.forge_link(@task.pr_url_kind)}
      </.link>
      <.link
        :if={@artifact?}
        href={~p"/projects/#{@task.project_id}/tasks/#{@task.id}/artifact"}
        download
        id={"#{@card_id}-artifact-link"}
        class={[
          "shrink-0 rounded-md px-1.5 py-0.5 text-[11px] font-semibold text-accent hover:bg-surface2",
          !@task.pr_url && "ml-auto"
        ]}
      >
        Download
      </.link>
      <button
        :if={@ctx.can_operate?}
        type="button"
        phx-click="archive"
        phx-value-id={@task.id}
        class={[
          "shrink-0 cursor-pointer rounded-md px-1.5 py-0.5 text-[11px] font-semibold text-text3 hover:bg-surface2 hover:text-text2",
          !@link? && "ml-auto"
        ]}
      >
        Archive
      </button>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :project, :map, required: true
  attr :repositories, :list, required: true
  attr :executors, :list, required: true

  defp new_task_modal(assigns) do
    assigns = assign(assigns, :discard_confirm, discard_confirm(assigns.form))

    ~H"""
    <div class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/45 p-4 pt-[8vh]">
      <.link
        patch={~p"/projects/#{@project.id}/board"}
        class="absolute inset-0"
        aria-label="Close"
        data-confirm={@discard_confirm}
      >
        <span class="sr-only">Close</span>
      </.link>
      <div class="relative w-full max-w-lg rounded-2xl border border-border bg-surface p-6 shadow-2xl">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-[15px] font-bold text-text">New task</h2>
          <.link
            patch={~p"/projects/#{@project.id}/board"}
            class="flex size-8 items-center justify-center rounded-lg text-text3 hover:bg-surface2"
            aria-label="Close"
            data-confirm={@discard_confirm}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.link>
        </div>
        <.form for={@form} id="new-task-form" phx-change="validate" phx-submit="create_task">
          <.input field={@form[:title]} type="text" label="Title" placeholder="What needs doing?" />
          <.input
            field={@form[:description]}
            type="textarea"
            label="Description"
            rows="3"
            placeholder="Context, goal, constraints…"
          />
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@form[:work_type]}
              type="select"
              label="Work type"
              options={work_type_options()}
            />
            <.input
              field={@form[:priority]}
              type="select"
              label="Priority"
              options={priority_options()}
            />
          </div>
          <div class="grid grid-cols-2 gap-3">
            <.input
              field={@form[:target]}
              type="select"
              label="Target"
              prompt="Default for work type"
              options={target_options()}
            />
            <.input
              field={@form[:repository_id]}
              type="select"
              label="Repository"
              options={Enum.map(@repositories, &{&1.name, &1.id})}
            />
          </div>
          <.input
            field={@form[:agent_id]}
            type="select"
            label="Executor"
            prompt="Choose later"
            options={Enum.map(@executors, &{&1.name, &1.id})}
          />
          <div class="mt-4 flex justify-end gap-2">
            <.button patch={~p"/projects/#{@project.id}/board"} data-confirm={@discard_confirm}>
              Cancel
            </.button>
            <.button variant="primary" type="submit" phx-disable-with="Creating…">
              Create task
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp discard_confirm(form) do
    if blank?(form[:title].value) and blank?(form[:description].value) do
      nil
    else
      "Discard this task? Your changes will be lost."
    end
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""

  defp work_type_options, do: FormOptions.work_types()
  defp target_options, do: FormOptions.targets()
  defp priority_options, do: @priorities
end

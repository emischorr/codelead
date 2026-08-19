defmodule CodeLeadWeb.TaskLive do
  @moduledoc """
  The task page: Task / Agent / Review / Terminal tabs, opening on the
  tab matching the task's state. All side-effecting actions go through
  `CodeLead.Runtime`; live agent output arrives over the task topic.
  """
  use CodeLeadWeb, :live_view

  require Logger

  alias CodeLead.AgentFeed
  alias CodeLead.Agents
  alias CodeLead.Costs
  alias CodeLead.Finalizer
  alias CodeLead.Git
  alias CodeLead.Git.DiffFile
  alias CodeLead.License
  alias CodeLead.Planning
  alias CodeLead.Preview
  alias CodeLead.PreviewGateway
  alias CodeLead.Projects
  alias CodeLead.Reviews
  alias CodeLead.Runtime
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Terminal
  alias CodeLead.Workspace
  alias CodeLeadWeb.DiffComponents
  alias CodeLeadWeb.FlashMessages
  alias CodeLeadWeb.Format
  alias CodeLeadWeb.NavContext
  alias CodeLeadWeb.ScheduleForm
  alias CodeLeadWeb.TaskLive.AgentFeedBlocks
  alias CodeLeadWeb.TaskLive.AgentTab
  alias CodeLeadWeb.TaskLive.ReviewTab
  alias CodeLeadWeb.TaskLive.TaskTab
  alias CodeLeadWeb.TaskLive.TerminalTab

  @tabs [:task, :agent, :review, :terminal]

  # Trailing-edge debounce: a burst of tool calls collapses into one
  # `git diff`. Below ~1s it stops coalescing — ACP harnesses emit both a
  # tool_call and a tool_call_update per call.
  @diff_refresh_ms 1_500

  @impl true
  def mount(%{"project_id" => project_id, "id" => id}, _session, socket) do
    project = Projects.get_project!(project_id)
    task = Tasks.get_task!(id)

    if connected?(socket) do
      Tasks.subscribe_task(task.id)
      Tasks.subscribe_board(project.id)
    end

    socket =
      socket
      |> assign(
        project: project,
        task: task,
        live_message: nil,
        feed_blocks: [],
        all_runs?: false,
        chat_pending?: false,
        survey_pending?: false,
        show_feedback?: false,
        editing?: false,
        schedule_form: nil,
        diff_files: nil,
        diff_stats: nil,
        diff_error: nil,
        diff_loading?: false,
        diff_expanded: MapSet.new(),
        diff_stale?: false,
        diff_refresh_timer: nil,
        following?: false,
        follow_path: nil,
        follow_anchor: nil,
        folder_artifact: nil,
        terminal_subscribed?: false,
        live_usage: nil,
        tick_timer: nil,
        now: DateTime.utc_now(),
        container_licensed?: License.feature_enabled?(:container_execution_env),
        board_column: nil
      )
      |> load_task()
      |> stream_configure(:feed, dom_id: &"agent-block-#{&1.id}")
      |> load_feed()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = parse_tab(params["tab"], socket.assigns.task)
    previous_tab = Map.get(socket.assigns, :tab)
    entering_review? = tab == :review and previous_tab != :review

    # Leaving the terminal detaches this viewer; the session (and the
    # shell in it) stays alive for the idle window.
    if previous_tab == :terminal and tab != :terminal do
      Terminal.detach(socket.assigns.task.id)
    end

    # Same contract for the preview server's viewer-keyed idle window.
    if previous_tab == :review and tab != :review do
      Preview.detach(socket.assigns.task.id)
    end

    socket = assign(socket, tab: tab)
    socket = maybe_set_board_column(socket, params["column"])
    socket = if tab == :review, do: enter_review(socket, entering_review?), else: socket

    # LiveView prunes stream inserts after every render, whether or not
    # the container was on screen, so the feed has to be re-streamed from
    # the server-side copy each time the tab comes back into view.
    socket =
      if tab == :agent,
        do: stream(socket, :feed, socket.assigns.feed_blocks, reset: true),
        else: socket

    {:noreply, socket}
  end

  ## Actions

  @impl true
  def handle_event("start_run", _params, socket) do
    socket.assigns.task |> Runtime.start_task() |> after_action(socket)
  end

  def handle_event("cancel_run", _params, socket) do
    socket.assigns.task |> Runtime.cancel_task() |> after_action(socket)
  end

  def handle_event("run_now", _params, socket) do
    socket.assigns.task |> Runtime.run_now() |> after_action(socket)
  end

  def handle_event("open_schedule", _params, socket) do
    {:noreply, assign(socket, schedule_form: ScheduleForm.new())}
  end

  def handle_event("close_schedule", _params, socket) do
    {:noreply, assign(socket, schedule_form: nil)}
  end

  def handle_event("schedule_task", %{"schedule" => params}, socket) do
    case ScheduleForm.parse(params) do
      {:ok, scheduled_at} ->
        socket = assign(socket, schedule_form: nil)

        socket.assigns.task
        |> Runtime.start_task(scheduled_at: scheduled_at)
        |> after_action(socket)

      {:error, form} ->
        {:noreply, assign(socket, schedule_form: form)}
    end
  end

  def handle_event("retry_run", _params, socket) do
    socket.assigns.task |> Runtime.retry_task() |> after_action(socket)
  end

  def handle_event("approve", _params, socket) do
    case Runtime.approve(socket.assigns.task) do
      {:ok, _task, outcome} ->
        {:noreply, socket |> put_flash(:info, outcome.note) |> load_task()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.finalize_error(reason))}
    end
  end

  def handle_event("set_finalize_mode", %{"finalize_mode" => mode}, socket) do
    case Tasks.set_finalize_mode(socket.assigns.task, mode) do
      {:ok, _task} ->
        {:noreply, load_task(socket)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "That finalize mode does not fit this task's target.")}
    end
  end

  def handle_event("send_back", _params, socket) do
    socket.assigns.task |> Runtime.send_back_to_planning() |> after_action(socket)
  end

  def handle_event("toggle_feedback", _params, socket) do
    {:noreply, assign(socket, show_feedback?: !socket.assigns.show_feedback?)}
  end

  def handle_event("submit_feedback", %{"feedback" => feedback}, socket) do
    case String.trim(feedback) do
      "" ->
        {:noreply, put_flash(socket, :error, "Describe the changes you need first.")}

      feedback ->
        socket = assign(socket, show_feedback?: false)
        socket.assigns.task |> Runtime.request_changes(feedback) |> after_action(socket)
    end
  end

  def handle_event("answer_permission", %{"ref" => ref, "granted" => granted}, socket) do
    case Runtime.answer_permission(socket.assigns.task, ref, granted == "true") do
      :ok ->
        {:noreply, load_task(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't answer the request: #{inspect(reason)}")}
    end
  end

  def handle_event("answer_question", %{"ref" => ref} = params, socket) do
    submit_answer(socket, ref, {:accept, Map.get(params, "answer", %{})})
  end

  def handle_event("skip_question", %{"ref" => ref}, socket) do
    submit_answer(socket, ref, :decline)
  end

  def handle_event("archive", _params, socket) do
    socket.assigns.task |> Tasks.archive() |> after_action(socket)
  end

  ## Agent feed

  def handle_event("toggle_block", %{"id" => id}, socket) do
    {blocks, block} = AgentFeedBlocks.toggle(socket.assigns.feed_blocks, String.to_integer(id))
    socket = assign(socket, feed_blocks: blocks)

    {:noreply, if(block, do: stream_insert(socket, :feed, block), else: socket)}
  end

  def handle_event("show_earlier_runs", _params, socket) do
    {:noreply, socket |> assign(all_runs?: true) |> load_feed()}
  end

  ## Diff

  def handle_event("toggle_file", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(diff_expanded: toggle_path(socket.assigns.diff_expanded, path))
     |> unfollow()}
  end

  def handle_event("focus_file", %{"path" => path}, socket) do
    {:noreply, socket |> unfollow() |> focus_path(path)}
  end

  def handle_event("follow_agent", _params, socket) do
    socket = assign(socket, following?: true)

    case socket.assigns.follow_path do
      nil -> {:noreply, socket}
      path -> {:noreply, socket |> assign(follow_anchor: path) |> focus_path(path)}
    end
  end

  def handle_event("diff_unfollow", _params, socket) do
    {:noreply, unfollow(socket)}
  end

  def handle_event("refresh_diff", _params, socket) do
    {:noreply, start_diff_load(socket)}
  end

  ## Terminal

  def handle_event("terminal_ready", %{"cols" => cols, "rows" => rows}, socket) do
    task = socket.assigns.task
    socket = subscribe_terminal(socket)
    extra_env = PreviewGateway.preview_env(task, CodeLeadWeb.Endpoint.url())

    with {:ok, _pid} <-
           Terminal.ensure_session(task, cols: cols, rows: rows, extra_env: extra_env),
         {:ok, scrollback, pty?} <- Terminal.attach(task.id) do
      {:reply, %{scrollback: Base.encode64(scrollback), pty: pty?}, socket}
    else
      {:error, reason} -> {:reply, %{error: terminal_error(reason)}, socket}
    end
  end

  def handle_event("terminal_resize", %{"cols" => cols, "rows" => rows}, socket) do
    Terminal.resize(socket.assigns.task.id, cols, rows)
    {:noreply, socket}
  end

  def handle_event("terminal_input", %{"data" => encoded}, socket) do
    case Base.decode64(encoded) do
      {:ok, data} -> Terminal.send_input(socket.assigns.task.id, data)
      :error -> :ok
    end

    {:noreply, socket}
  end

  ## Preview server

  def handle_event("preview_start", _params, socket) do
    task = socket.assigns.task
    extra_env = PreviewGateway.preview_env(task, CodeLeadWeb.Endpoint.url())

    case Preview.ensure_session(task, extra_env: extra_env) do
      {:ok, _pid} ->
        Preview.attach(task.id)
        {:noreply, assign(socket, preview_run: Preview.status(task.id))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, preview_error(reason))}
    end
  end

  def handle_event("preview_stop", _params, socket) do
    Preview.stop(socket.assigns.task.id)
    {:noreply, assign(socket, preview_run: :stopped)}
  end

  ## Planning: edits, executor/reviewers, chat

  # Edit mode is server state, not a `JS.toggle`: a re-render — a save, a
  # board broadcast, an agent event — would otherwise leave the form open
  # over stale values.
  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, editing?: !socket.assigns.editing?) |> reset_edit_form()}
  end

  def handle_event("validate_edit", %{"task" => params}, socket) do
    changeset = Task.planning_changeset(socket.assigns.task, params)
    {:noreply, assign(socket, edit_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_edit", %{"task" => params}, socket) do
    case Tasks.update_task(socket.assigns.task, params) do
      {:ok, _task} ->
        {:noreply,
         socket |> assign(editing?: false) |> put_flash(:info, "Task updated.") |> load_task()}

      {:error, changeset} ->
        {:noreply, assign(socket, edit_form: to_form(changeset))}
    end
  end

  def handle_event("delete_task", _params, socket) do
    case Tasks.delete_task(socket.assigns.task) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> put_flash(:info, "Task deleted.")
         |> push_navigate(to: ~p"/projects/#{socket.assigns.project.id}/board")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.delete_error(reason))}
    end
  end

  # The target form is a bare `phx-change` form, so `repository_id` and
  # `execution_env` are simply absent while the target is `:folder`.
  def handle_event("set_target", params, socket) do
    case Tasks.update_task(
           socket.assigns.task,
           Map.take(params, ["target", "repository_id", "execution_env"])
         ) do
      {:ok, _task} ->
        {:noreply, load_task(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update the target.")}
    end
  end

  def handle_event("set_executor", %{"agent_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("set_executor", %{"agent_id" => agent_id}, socket) do
    socket.assigns.task
    |> Tasks.set_executor(String.to_integer(agent_id))
    |> after_action(socket)
  end

  def handle_event("set_reviewers", params, socket) do
    ids = params |> Map.get("reviewer_ids", []) |> Enum.map(&String.to_integer/1)

    case Tasks.set_reviewers(socket.assigns.task, ids) do
      :ok ->
        {:noreply, load_task(socket)}

      {:error, {:ineligible, _ids}} ->
        {:noreply, put_flash(socket, :error, "Some selected agents can't review this work type.")}
    end
  end

  def handle_event("set_planner", %{"agent_id" => agent_id}, socket) do
    planner = Enum.find(socket.assigns.eligible_planners, &(to_string(&1.id) == agent_id))

    {:noreply, assign(socket, selected_planner: planner || socket.assigns.selected_planner)}
  end

  def handle_event("send_chat", %{"message" => message}, socket) do
    %{task: task, selected_planner: planner} = socket.assigns

    case {String.trim(message), planner} do
      {"", _planner} ->
        {:noreply, socket}

      {_message, nil} ->
        {:noreply,
         put_flash(socket, :error, "No planning agent is configured for this work type.")}

      {content, planner} ->
        {:noreply,
         socket
         |> assign(chat_pending?: true, pending_chat: content)
         |> start_async(:chat_reply, fn -> Planning.send_message(task, planner.id, content) end)}
    end
  end

  def handle_event("run_survey", _params, socket) do
    %{task: task, selected_planner: planner} = socket.assigns

    case planner && Planning.start_survey(task, planner.id) do
      {:ok, :started} ->
        {:noreply, assign(socket, survey_pending?: true)}

      nil ->
        {:noreply, put_flash(socket, :error, FlashMessages.survey_error(:no_planner))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.survey_error(reason))}
    end
  end

  ## Async results

  @impl true
  def handle_async(:chat_reply, {:ok, result}, socket) do
    socket = assign(socket, chat_pending?: false, pending_chat: nil)

    case result do
      {:ok, _message} ->
        {:noreply, assign(socket, messages: Planning.list_messages(socket.assigns.task.id))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Assistant call failed: #{inspect(reason)}")}
    end
  end

  def handle_async(:chat_reply, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(chat_pending?: false, pending_chat: nil)
     |> put_flash(:error, "Assistant call crashed: #{inspect(reason)}")}
  end

  def handle_async(:load_diff, {:ok, {:ok, files, stats}}, socket) do
    %{diff_files: previous, diff_expanded: expanded} = socket.assigns

    socket =
      socket
      |> assign(
        diff_loading?: false,
        diff_error: nil,
        diff_files: files,
        diff_stats: stats,
        diff_expanded: merge_expanded(previous, expanded, files)
      )
      |> apply_follow(files)
      |> schedule_diff_refresh()

    {:noreply, socket}
  end

  def handle_async(:load_diff, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(diff_loading?: false) |> diff_failed("git diff failed", reason)}
  end

  def handle_async(:load_diff, {:exit, reason}, socket) do
    {:noreply,
     socket |> assign(diff_loading?: false) |> diff_failed("diff crashed", inspect(reason))}
  end

  ## PubSub

  @impl true
  def handle_info({:agent_feed, _task_id, row}, socket) do
    changed? = AgentFeed.file_changing?(row.kind, row.data["tool_kind"])

    {:noreply,
     socket
     |> apply_feed_row(row)
     |> track_follow_path(row)
     |> maybe_mark_diff_stale(changed?)}
  end

  def handle_info({:task_event, _task_id, event}, socket) do
    state_bearing? = state_bearing?(event)

    {:noreply,
     socket
     |> ingest_event(event)
     |> maybe_reload(state_bearing?)
     |> maybe_mark_diff_stale(state_bearing?)}
  end

  def handle_info(:tick, socket) do
    {:noreply, reschedule_tick(socket)}
  end

  def handle_info(:refresh_diff, socket) do
    {:noreply, socket |> assign(diff_refresh_timer: nil) |> refresh_diff()}
  end

  def handle_info({:board_changed, project_id, task_id}, socket) do
    cond do
      task_id != socket.assigns.task.id ->
        {:noreply, socket}

      is_nil(Tasks.get_task(task_id)) ->
        {:noreply,
         socket
         |> put_flash(:info, "This task was deleted.")
         |> push_navigate(to: ~p"/projects/#{project_id}/board")}

      true ->
        {:noreply, load_task(socket)}
    end
  end

  # Output for a hidden tab is dropped — the session's scrollback
  # repaints the terminal when the tab (re)attaches.
  def handle_info({:preview_state, _task_id, status}, socket) do
    {:noreply, assign(socket, preview_run: status)}
  end

  def handle_info({:terminal_data, _task_id, chunk}, %{assigns: %{tab: :terminal}} = socket) do
    {:noreply, push_event(socket, "terminal:data", %{data: Base.encode64(chunk)})}
  end

  def handle_info({:terminal_data, _task_id, _chunk}, socket), do: {:noreply, socket}

  def handle_info({:terminal_exit, _task_id, status}, %{assigns: %{tab: :terminal}} = socket) do
    {:noreply, push_event(socket, "terminal:exit", %{status: status})}
  end

  def handle_info({:terminal_exit, _task_id, _status}, socket), do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  ## Data loading

  defp load_task(socket) do
    task = Tasks.get_task!(socket.assigns.task.id)
    project = socket.assigns.project
    planning? = task.state == :planning

    repository = task.repository_id && Projects.get_repository!(task.repository_id)
    finalize = finalize_context(task, repository)
    agents = Map.new(Agents.list_agents(project.id), &{&1.id, &1})
    executor = task.agent_id && agents[task.agent_id]
    steps = Tasks.steps(task.id)
    runs = Costs.task_runs(task.id)

    socket
    |> assign(
      task: task,
      page_title: task.title,
      repository: repository,
      preview_available?: preview_available?(task),
      preview_command?: preview_command?(repository),
      preview_run: preview_run(socket),
      finalize_mode: finalize.mode,
      project_finalize_mode: finalize.project_mode,
      forge_known?: finalize.forge_known?,
      executor: executor,
      startable_reason: Tasks.startable(task, executor),
      agents: agents,
      steps: steps,
      run_started_at: last_run_started_at(steps),
      reviewers: Tasks.reviewers(task.id),
      reviews: Reviews.list_reviews(task.id),
      task_spend: Costs.task_spend(task.id),
      task_duration_ms: Costs.task_duration_ms(task.id),
      cost_mode: runs |> Enum.map(& &1.provider_kind) |> Agents.billing_mode(),
      runs: runs,
      messages: Planning.list_messages(task.id),
      eligible_executors:
        (planning? && Agents.eligible_executors(task.work_type, project.id)) || [],
      eligible_reviewers:
        (planning? && Agents.eligible_reviewers(task.work_type, project.id)) || [],
      repositories: (planning? && Projects.list_repositories(project.id)) || []
    )
    |> maybe_reset_edit_form()
    |> load_planners(task, project.id, planning?)
    |> NavContext.put_stats(
      length(Tasks.attention_tasks(project.id)),
      Costs.project_spend_month(project.id)
    )
    |> drop_stale_live_usage()
    |> reschedule_tick()
  end

  # Everything the Approve button and the finalize selector need. The
  # mode the finalizer would actually run, the mode the *project* would
  # run (what the selector's "Project default" option names, so the
  # task's own override has to be taken out of it), and whether the
  # remote has a forge convention at all — one that has none can be
  # pushed to but not opened a PR on, which is a different promise.
  defp finalize_context(task, repository) do
    project_mode =
      Finalizer.resolve_mode(
        task.target,
        nil,
        Map.fetch!(Projects.finalize_defaults(task.project_id), task.target)
      )

    %{
      mode: Tasks.finalize_mode(task),
      project_mode: project_mode,
      forge_known?: repository != nil and Git.forge(repository.git_url) != :other
    }
  end

  # A reload that lands mid-edit — a board broadcast, an agent event —
  # must not throw away what the user has typed.
  defp maybe_reset_edit_form(%{assigns: %{editing?: true}} = socket), do: socket
  defp maybe_reset_edit_form(socket), do: reset_edit_form(socket)

  defp reset_edit_form(socket) do
    assign(socket, edit_form: to_form(Task.planning_changeset(socket.assigns.task, %{})))
  end

  # Once the run's own `agent_runs` row exists, `task_spend` already
  # counts it — keeping the snapshot would double the money on screen.
  defp drop_stale_live_usage(socket) do
    if executing?(socket.assigns.task),
      do: socket,
      else: assign(socket, live_usage: nil)
  end

  # A run's start is already on the timeline; no need to plumb it
  # through the event stream just to drive the elapsed counter.
  defp last_run_started_at(steps) do
    steps
    |> Enum.filter(&(&1.kind == :run))
    |> List.last()
    |> case do
      nil -> nil
      step -> step.inserted_at
    end
  end

  # Which agent the human is planning *with* is a tool choice, not task
  # state, so it lives in the socket. A reload keeps the current pick as
  # long as it is still eligible.
  defp load_planners(socket, task, project_id, planning?) do
    planners = (planning? && Agents.eligible_planners(task.work_type, project_id)) || []
    previous = socket.assigns[:selected_planner]

    selected =
      Enum.find(planners, List.first(planners), &(previous && &1.id == previous.id))

    assign(socket, eligible_planners: planners, selected_planner: selected)
  end

  ## Elapsed counter

  defp reschedule_tick(socket) do
    if timer = socket.assigns[:tick_timer], do: Process.cancel_timer(timer)

    timer =
      if connected?(socket) and executing?(socket.assigns.task),
        do: Process.send_after(self(), :tick, 1_000)

    socket
    |> assign(tick_timer: timer, now: DateTime.utc_now())
    |> put_task_stat()
  end

  # The single stat the header, Agent tab and Cost card all render:
  # everything already recorded, plus whatever the run in flight has
  # reported so far.
  defp put_task_stat(socket) do
    %{task_spend: spend, task_duration_ms: duration, live_usage: live, task: task} =
      socket.assigns

    assign(socket, :task_stat, %{
      cost_cents: spend.cost_cents + live_cost_cents(live),
      tokens: spend.tokens,
      duration_ms:
        duration +
          live_elapsed_ms(socket.assigns.run_started_at, task.run_state, socket.assigns.now),
      cost_mode: socket.assigns.cost_mode
    })
  end

  # Wall-clock elapsed for the run in flight. The persisted `duration_ms`
  # takes over the moment the run lands.
  defp live_elapsed_ms(nil, _run_state, _now), do: 0

  defp live_elapsed_ms(started_at, :executing, now),
    do: max(DateTime.diff(now, started_at, :millisecond), 0)

  defp live_elapsed_ms(_started_at, _run_state, _now), do: 0

  defp live_cost_cents(%{cost_cents: cents}) when is_integer(cents), do: cents
  defp live_cost_cents(_live_usage), do: 0

  defp cost_mode_hint(:estimated),
    do: "Subscription run — API-equivalent estimate, not money billed"

  defp cost_mode_hint(:free), do: "Locally hosted model — no per-token cost"
  defp cost_mode_hint(_mode), do: nil

  # The URL itself is never rendered here — the Open-preview link goes
  # through `/preview/launch/:task_id`, so the gateway stays the only
  # producer of browser-facing preview URLs.
  defp preview_available?(task) do
    match?({:ok, _url}, PreviewGateway.impl().url_for(task))
  end

  defp subscribe_terminal(%{assigns: %{terminal_subscribed?: true}} = socket), do: socket

  defp subscribe_terminal(socket) do
    Terminal.subscribe(socket.assigns.task.id)
    assign(socket, terminal_subscribed?: true)
  end

  defp preview_command?(repository) do
    repository != nil and repository.preview_command != nil
  end

  # A failed session is gone from the registry, so its terminal state
  # would read :stopped on the next reload — keep the failure visible
  # until a new start (or an explicit stop) replaces it.
  defp preview_run(socket) do
    case {Map.get(socket.assigns, :preview_run), Preview.status(socket.assigns.task.id)} do
      {{:failed, _tail} = failed, :stopped} -> failed
      {_previous, status} -> status
    end
  end

  defp preview_error(:no_preview_command),
    do: "Declare a preview command on the repository to start the preview from here."

  defp preview_error(:no_worktree),
    do: "This task has no worktree yet — the preview starts after the first run."

  defp preview_error(:container_unlicensed),
    do: "Container execution requires a commercial license, so the preview cannot start."

  defp preview_error({:shell_not_found, shell}),
    do: "No #{inspect(shell)} shell is available on the server."

  defp preview_error(reason), do: "The preview could not start: #{inspect(reason)}"

  defp terminal_empty_message(%Task{state: :done}),
    do: "The execution context was pruned when this task was finalized."

  defp terminal_empty_message(%Task{target: :folder}),
    do: "A task folder is provisioned when the first run starts."

  defp terminal_empty_message(%Task{}),
    do: "A worktree is provisioned when a repo-targeted run starts."

  defp terminal_error(:no_context),
    do: "No execution context yet — the terminal opens once a run has provisioned one."

  defp terminal_error(:container_unlicensed),
    do: "Container execution is not enabled by the instance license."

  defp terminal_error({:shell_not_found, shell}),
    do: "Shell `#{shell}` was not found on this server."

  defp terminal_error(reason), do: "The terminal could not start: #{inspect(reason)}"

  # "diff" survives as an alias — the tab carried that name before the
  # preview landed, and bookmarked URLs keep working.
  defp parse_tab("diff", _task), do: :review

  defp parse_tab(param, task) do
    case Enum.find(@tabs, &(Atom.to_string(&1) == param)) do
      nil -> default_tab(task.state)
      tab -> tab
    end
  end

  defp default_tab(:planning), do: :task
  defp default_tab(:running), do: :agent
  defp default_tab(:review), do: :review
  defp default_tab(_state), do: :task

  # The board link the task arrived from carries the mobile column it was
  # opened from, so "back to board" (button or browser back) restores it
  # instead of always landing on Planning.
  defp maybe_set_board_column(socket, nil), do: socket
  defp maybe_set_board_column(socket, column), do: assign(socket, board_column: column)

  defp board_path(project_id, nil), do: ~p"/projects/#{project_id}/board"
  defp board_path(project_id, column), do: ~p"/projects/#{project_id}/board?column=#{column}"

  defp enter_review(socket, entering?) do
    # Register as a preview viewer (no-op without a live session) and
    # pick up the session's current state.
    if entering? do
      Preview.attach(socket.assigns.task.id)
    end

    socket =
      if entering?,
        do: assign(socket, :preview_run, preview_run(socket)),
        else: socket

    enter_diff(socket, entering?)
  end

  # Entering the tab always collapses back to the first file, and picks
  # up anything that went stale while another tab was on screen.
  defp enter_diff(socket, entering?) do
    socket
    |> then(&if entering?, do: reset_diff_view(&1), else: &1)
    |> then(
      &if &1.assigns.diff_files == nil or &1.assigns.diff_stale?,
        do: start_diff_load(&1),
        else: &1
    )
  end

  defp reset_diff_view(socket) do
    assign(socket,
      following?: false,
      follow_anchor: nil,
      diff_expanded: initial_expanded(socket.assigns.diff_files)
    )
  end

  defp start_diff_load(%{assigns: %{task: task}} = socket) do
    cond do
      socket.assigns.diff_loading? ->
        socket

      task.target == :repo and is_binary(task.worktree_path) and socket.assigns.repository ->
        worktree = task.worktree_path
        base = socket.assigns.repository.default_branch

        socket
        |> assign(diff_loading?: true, diff_stale?: false)
        |> start_async(:load_diff, fn -> run_diff(worktree, base) end)

      task.target == :folder ->
        assign(socket,
          diff_stale?: false,
          folder_artifact: load_folder_artifact(task.id)
        )

      true ->
        socket
    end
  end

  defp maybe_mark_diff_stale(socket, false), do: socket

  defp maybe_mark_diff_stale(socket, true) do
    socket |> assign(diff_stale?: true) |> schedule_diff_refresh()
  end

  # Off the diff tab only the flag accumulates — `enter_diff/2` picks it
  # up — so no git runs for a page nobody is looking at.
  defp schedule_diff_refresh(
         %{
           assigns: %{
             tab: :review,
             diff_stale?: true,
             diff_refresh_timer: nil
           }
         } = socket
       ) do
    assign(socket,
      diff_refresh_timer: Process.send_after(self(), :refresh_diff, @diff_refresh_ms)
    )
  end

  defp schedule_diff_refresh(socket), do: socket

  defp refresh_diff(
         %{
           assigns: %{
             tab: :review,
             diff_stale?: true,
             diff_loading?: false
           }
         } = socket
       ),
       do: start_diff_load(socket)

  defp refresh_diff(socket), do: socket

  # A failed refresh must not blank a diff that is already on screen.
  defp diff_failed(%{assigns: %{diff_files: nil}} = socket, label, reason) do
    assign(socket, diff_error: "#{label}: #{reason}")
  end

  defp diff_failed(socket, label, reason) do
    Logger.debug("#{label} on task #{socket.assigns.task.id}: #{reason}")
    socket
  end

  defp merge_expanded(nil, _expanded, files), do: initial_expanded(files)

  defp merge_expanded(_previous, expanded, files) do
    MapSet.intersection(expanded, MapSet.new(files, &DiffFile.path/1))
  end

  defp initial_expanded([first | _rest]), do: MapSet.new([DiffFile.path(first)])
  defp initial_expanded(_files), do: MapSet.new()

  defp toggle_path(expanded, path) do
    if MapSet.member?(expanded, path) do
      MapSet.delete(expanded, path)
    else
      MapSet.put(expanded, path)
    end
  end

  defp focus_path(socket, path) do
    socket
    |> assign(diff_expanded: MapSet.new([path]))
    |> push_event("diff:scroll_to", %{id: DiffComponents.file_dom_id(path)})
  end

  ## Follow mode

  # Tracked even while follow is off, so engaging it lands on the file
  # the agent is working in right now.
  defp track_follow_path(socket, %{data: %{"locations" => [_ | _] = locations}}) do
    case worktree_relative(locations, socket.assigns.task.worktree_path) do
      nil -> socket
      path -> assign(socket, follow_path: path)
    end
  end

  defp track_follow_path(socket, _row), do: socket

  defp worktree_relative(locations, worktree_path),
    do: Enum.find_value(locations, &Format.project_path(&1, worktree_path))

  # Scrolls only when the agent moves to a different file: re-anchoring on
  # every refresh would yank the viewport back through ten edits of the
  # same file.
  defp apply_follow(%{assigns: %{following?: true, follow_path: path}} = socket, files)
       when is_binary(path) do
    if path != socket.assigns.follow_anchor and Enum.any?(files, &(DiffFile.path(&1) == path)) do
      socket |> assign(follow_anchor: path) |> focus_path(path)
    else
      socket
    end
  end

  defp apply_follow(socket, _files), do: socket

  defp unfollow(%{assigns: %{following?: false}} = socket), do: socket
  defp unfollow(socket), do: assign(socket, following?: false, follow_anchor: nil)

  defp run_diff(worktree, base_branch) do
    with {:ok, raw} <- Git.diff(worktree, base_branch) do
      files = Git.Diff.parse(raw)
      {:ok, files, Git.Diff.stats(files)}
    end
  end

  defp load_folder_artifact(task_id) do
    folder = Workspace.task_folder(task_id)

    case File.ls(folder) do
      {:ok, entries} ->
        output =
          case File.read(Path.join(folder, "output.md")) do
            {:ok, content} -> content
            {:error, _reason} -> nil
          end

        %{folder: folder, entries: Enum.sort(entries), output: output}

      {:error, _reason} ->
        nil
    end
  end

  ## Agent feed

  defp load_feed(%{assigns: %{task: task, all_runs?: all_runs?}} = socket) do
    rows = if all_runs?, do: AgentFeed.list_all(task.id), else: AgentFeed.list_run(task.id)
    executing? = executing?(task)
    {rows, live_message} = split_live_message(rows, executing?)
    blocks = AgentFeedBlocks.fold(rows, executing?)

    socket
    |> assign(feed_blocks: blocks, live_message: live_message)
    |> stream(:feed, blocks, reset: true)
  end

  # The runner keeps rewriting the row it is streaming into, so it
  # belongs in the live pane rather than the feed — but only while the
  # run is alive, or a killed runner would strand it there.
  defp split_live_message(rows, true) do
    case List.last(rows) do
      %{streaming: true} = row -> {Enum.drop(rows, -1), row}
      _other -> {rows, nil}
    end
  end

  defp split_live_message(rows, false), do: {rows, nil}

  defp executing?(%Task{run_state: run_state}), do: run_state == :executing

  # A row the runner reopened is already a block in the feed; routing it
  # to the live pane too would render the message twice.
  defp apply_feed_row(socket, %{streaming: true} = row) do
    if AgentFeedBlocks.known?(socket.assigns.feed_blocks, row.id) do
      apply_block_row(socket, row)
    else
      assign(socket, live_message: row)
    end
  end

  defp apply_feed_row(socket, row), do: apply_block_row(socket, row)

  defp apply_block_row(socket, row) do
    {blocks, changed} = AgentFeedBlocks.apply_row(socket.assigns.feed_blocks, row)

    live_message =
      if live_message?(socket.assigns.live_message, row),
        do: nil,
        else: socket.assigns.live_message

    socket = assign(socket, feed_blocks: blocks, live_message: live_message)
    Enum.reduce(changed, socket, &stream_insert(&2, :feed, &1))
  end

  defp live_message?(%{id: id}, %{id: id}), do: true
  defp live_message?(_live_message, _row), do: false

  # Chunks arrive ahead of the row they accumulate into; the row's text
  # is authoritative and replaces this the moment it lands.
  defp ingest_event(socket, {:message_chunk, text}) do
    case socket.assigns.live_message do
      nil -> socket
      row -> assign(socket, live_message: %{row | text: (row.text || "") <> text})
    end
  end

  # Advisory mid-run money. It is deliberately not state-bearing: it must
  # not reload the task, and `load_task/1` drops it again once the run's
  # own `agent_runs` row exists, so the two are never added together.
  defp ingest_event(socket, {:usage, snapshot}) do
    socket |> assign(live_usage: snapshot) |> put_task_stat()
  end

  defp ingest_event(socket, {:survey_completed, _summary}) do
    assign(socket, survey_pending?: false)
  end

  defp ingest_event(socket, _event), do: socket

  @state_bearing_events [
    :run_started,
    :run_completed,
    :run_failed,
    :run_cancelled,
    :question,
    :permission_request,
    :review_completed,
    :review_cycle_completed,
    :survey_completed
  ]

  defp state_bearing?(event) when is_tuple(event), do: elem(event, 0) in @state_bearing_events
  defp state_bearing?(_event), do: false

  defp maybe_reload(socket, false), do: socket

  defp maybe_reload(socket, true) do
    socket = load_task(socket)

    # Nothing left to follow once the agent stops writing.
    if executing?(socket.assigns.task), do: socket, else: unfollow(socket)
  end

  # The resolved row broadcasts itself back through `:agent_feed`, so the
  # card re-renders without any stream bookkeeping here.
  defp submit_answer(socket, ref, answer) do
    case Runtime.answer_question(socket.assigns.task, ref, answer) do
      :ok ->
        {:noreply, load_task(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't send the answer: #{inspect(reason)}")}
    end
  end

  defp after_action(result, socket) do
    case result do
      {:ok, _task} ->
        {:noreply, load_task(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.transition_error(reason))}
    end
  end

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope} sidebar={:closed}>
      <header class="shrink-0 border-b border-border bg-surface">
        <div
          class="h-[3px]"
          style={"background-color: var(--proj-#{@project.color})"}
          title={@project.name}
        />
        <div class="flex items-center gap-2.5 px-4 pt-3.5 sm:gap-3.5 sm:px-6">
          <Layouts.sidebar_toggle />
          <.link
            navigate={board_path(@project.id, @board_column)}
            class="inline-flex size-8 shrink-0 items-center justify-center rounded-[9px] border border-border bg-surface text-text2 hover:bg-surface2"
            aria-label="Back to board"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </.link>
          <h1 class="min-w-0 truncate text-[15px] font-semibold tracking-tight text-text sm:text-lg">
            {@task.title}
          </h1>
          <.state_badge state={@task.state} run_state={@task.run_state} />
          <span
            :if={Task.scheduled?(@task)}
            id="scheduled-hint"
            class="hidden items-center gap-1.5 rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[10.5px] font-semibold text-text2 sm:inline-flex"
          >
            ⏱ starts {Format.absolute(@task.scheduled_at)}
          </span>
          <.agent_pill :if={@executor} name={@executor.name} harness={@executor.harness} />
          <.cost_stat
            cost_cents={@task_stat.cost_cents}
            tokens={@task_stat.tokens}
            duration_ms={@task_stat.duration_ms}
            cost_mode={@task_stat.cost_mode}
            title={cost_mode_hint(@task_stat.cost_mode)}
            class="hidden md:inline"
          />
          <div class="flex-1" />
          <div class="hidden items-center gap-2 lg:flex">
            <.header_actions
              task={@task}
              scheduled?={Task.scheduled?(@task)}
              finalize_mode={@finalize_mode}
              forge_known?={@forge_known?}
              base_branch={@repository && @repository.default_branch}
              startable_reason={@startable_reason}
            />
          </div>
        </div>
        <.tab_nav tabs={tab_links(@project, @task)} active={@tab} class="mt-3 px-4 sm:px-6" />
      </header>

      <div class="min-h-0 flex-1 overflow-auto">
        <TaskTab.task_tab
          :if={@tab == :task}
          task={@task}
          repository={@repository}
          repositories={@repositories}
          executor={@executor}
          agents={@agents}
          steps={@steps}
          reviewers={@reviewers}
          reviews={@reviews}
          runs={@runs}
          task_stat={@task_stat}
          messages={@messages}
          eligible_planners={@eligible_planners}
          selected_planner={@selected_planner}
          chat_pending?={@chat_pending?}
          survey_pending?={@survey_pending?}
          pending_chat={assigns[:pending_chat]}
          eligible_executors={@eligible_executors}
          eligible_reviewers={@eligible_reviewers}
          edit_form={@edit_form}
          editing?={@editing?}
          show_feedback?={@show_feedback?}
          finalize_mode={@finalize_mode}
          project_finalize_mode={@project_finalize_mode}
          container_licensed?={@container_licensed?}
        />
        <AgentTab.agent_tab
          :if={@tab == :agent}
          task={@task}
          blocks={@streams.feed}
          live_message={@live_message}
          executing?={@task.run_state == :executing}
          all_runs?={@all_runs?}
          task_stat={@task_stat}
        />
        <ReviewTab.review_tab
          :if={@tab == :review}
          task={@task}
          reviews={@reviews}
          diff_files={@diff_files}
          diff_stats={@diff_stats}
          diff_error={@diff_error}
          diff_loading?={@diff_loading?}
          expanded={@diff_expanded}
          following?={@following?}
          executing?={@task.run_state == :executing}
          folder_artifact={@folder_artifact}
          preview_available?={@preview_available?}
          preview_command?={@preview_command?}
          preview_run={@preview_run}
        />
        <TerminalTab.terminal_tab
          :if={@tab == :terminal}
          task_id={@task.id}
          path={Terminal.context_path(@task)}
          empty_message={terminal_empty_message(@task)}
        />
      </div>

      <%!-- In flow, not `fixed`: it shortens the scroll pane above it, so a tab
            that docks its own bottom chrome (the Agent composer) lands above
            this bar instead of underneath it. --%>
      <div class="flex shrink-0 gap-2.5 border-t border-border bg-surface p-3.5 lg:hidden">
        <.header_actions
          task={@task}
          scheduled?={Task.scheduled?(@task)}
          finalize_mode={@finalize_mode}
          forge_known?={@forge_known?}
          base_branch={@repository && @repository.default_branch}
          startable_reason={@startable_reason}
          mobile
        />
      </div>

      <.feedback_modal :if={@show_feedback?} />

      <.schedule_modal
        :if={@schedule_form}
        form={@schedule_form}
        task_title={@task.title}
        min={ScheduleForm.now_input_value()}
      />
    </Layouts.app>
    """
  end

  defp tab_links(project, task) do
    for tab <- @tabs do
      %{
        id: tab,
        label: tab_label(tab),
        patch: ~p"/projects/#{project.id}/tasks/#{task.id}?tab=#{tab}",
        warn: tab == :agent and match?(%{type: t} when t != :review_ready, task.attention)
      }
    end
  end

  defp tab_label(:task), do: "Task"
  defp tab_label(:agent), do: "Agent"
  defp tab_label(:review), do: "Review"
  defp tab_label(:terminal), do: "Terminal"

  attr :task, :map, required: true
  attr :mobile, :boolean, default: false
  attr :scheduled?, :boolean, default: false
  attr :finalize_mode, :atom, default: :pull_request
  attr :forge_known?, :boolean, default: false
  attr :base_branch, :string, default: nil
  attr :startable_reason, :any, default: :ok

  defp header_actions(%{task: %{state: :planning}} = assigns) do
    assigns = assign(assigns, start_hint: start_hint(assigns.startable_reason))

    ~H"""
    <.button
      phx-click="open_schedule"
      id={action_id("schedule-run", @mobile)}
      disabled={@start_hint != nil}
      title={@start_hint || "Schedule this run"}
    >
      <.icon name="hero-clock" class="size-3.5" />
      <span class={@mobile && "hidden!"}>Schedule</span>
    </.button>
    <.button
      variant="primary"
      phx-click="start_run"
      class={@mobile && "flex-1"}
      id={action_id("start-run", @mobile)}
      disabled={@start_hint != nil}
      title={@start_hint}
    >
      Start run
    </.button>
    """
  end

  defp header_actions(%{task: %{state: :running, run_state: :queued}, scheduled?: true} = assigns) do
    ~H"""
    <.button
      variant="primary"
      phx-click="run_now"
      class={@mobile && "flex-1"}
      id={action_id("run-now", @mobile)}
    >
      Run now
    </.button>
    <.button phx-click="cancel_run" id={action_id("cancel-run", @mobile)}>Cancel run</.button>
    """
  end

  defp header_actions(%{task: %{state: :running, run_state: :failed}} = assigns) do
    ~H"""
    <.button
      variant="primary"
      phx-click="retry_run"
      class={@mobile && "flex-1"}
      id={action_id("retry-run", @mobile)}
    >
      Retry
    </.button>
    <.button phx-click="cancel_run" id={action_id("cancel-run", @mobile)}>Cancel run</.button>
    """
  end

  defp header_actions(%{task: %{state: :running}} = assigns) do
    ~H"""
    <.button phx-click="cancel_run" class={@mobile && "flex-1"} id={action_id("cancel-run", @mobile)}>
      Cancel run
    </.button>
    """
  end

  defp header_actions(%{task: %{state: :review}} = assigns) do
    ~H"""
    <.button
      variant="ghost"
      phx-click="send_back"
      id={action_id("send-back", @mobile)}
      class={@mobile && "flex-1"}
    >
      Send back
    </.button>
    <.button
      phx-click="toggle_feedback"
      class={@mobile && "flex-1"}
      id={action_id("request-changes", @mobile)}
    >
      {if @mobile, do: "Changes", else: "Request changes"}
    </.button>
    <.button
      variant="primary"
      phx-click="approve"
      phx-disable-with="Finalizing…"
      title={Format.finalize_hint(@finalize_mode, @base_branch)}
      class={@mobile && "flex-1"}
      id={action_id("approve", @mobile)}
    >
      {if @mobile,
        do: Format.finalize_action_short(@finalize_mode),
        else: Format.finalize_action(@finalize_mode, @forge_known?)}
    </.button>
    """
  end

  defp header_actions(%{task: %{state: :done, archived_at: nil}} = assigns) do
    ~H"""
    <.button
      :if={@task.pr_url}
      href={@task.pr_url}
      target="_blank"
      rel="noopener noreferrer"
      id={action_id("open-pr", @mobile)}
    >
      <.icon name="hero-arrow-top-right-on-square" class="size-4" />
      {Format.forge_link(@task.pr_url_kind)}
    </.button>
    <.button
      :if={@task.target == :folder}
      href={~p"/projects/#{@task.project_id}/tasks/#{@task.id}/artifact"}
      download
      id={action_id("download-artifact", @mobile)}
    >
      <.icon name="hero-arrow-down-tray" class="size-4" /> Download
    </.button>
    <.button phx-click="archive" class={@mobile && "flex-1"} id={action_id("archive", @mobile)}>
      Archive
    </.button>
    """
  end

  defp header_actions(assigns) do
    ~H"""
    <span class="text-xs text-text3">Archived</span>
    """
  end

  defp action_id(name, mobile), do: if(mobile, do: "m-action-#{name}", else: "action-#{name}")

  defp start_hint(:ok), do: nil
  defp start_hint({:error, reason}), do: FlashMessages.transition_error(reason)

  defp feedback_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/45 p-4 pt-[16vh]">
      <button type="button" phx-click="toggle_feedback" class="absolute inset-0" aria-label="Close" />
      <div class="relative w-full max-w-lg rounded-2xl border border-border bg-surface p-6 shadow-2xl">
        <h2 class="mb-1 text-[15px] font-bold text-text">Request changes</h2>
        <p class="mb-4 text-[13px] text-text2">
          Your feedback becomes the agent's next prompt. The worktree, branch, and session are kept —
          commits accumulate.
        </p>
        <form id="feedback-form" phx-submit="submit_feedback">
          <.input
            type="textarea"
            name="feedback"
            value=""
            rows="4"
            placeholder="What should change?"
            autofocus
          />
          <div class="mt-3 flex justify-end gap-2">
            <.button type="button" phx-click="toggle_feedback">Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Sending…">
              Send back to agent
            </.button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end

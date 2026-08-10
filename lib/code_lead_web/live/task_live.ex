defmodule CodeLeadWeb.TaskLive do
  @moduledoc """
  The task page: Task / Agent / Diff / Terminal tabs, opening on the tab
  matching the task's state. All side-effecting actions go through
  `CodeLead.Runtime`; live agent output arrives over the task topic.
  """
  use CodeLeadWeb, :live_view

  alias CodeLead.Agents
  alias CodeLead.Costs
  alias CodeLead.Git
  alias CodeLead.Planning
  alias CodeLead.Projects
  alias CodeLead.Reviews
  alias CodeLead.Runtime
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace
  alias CodeLeadWeb.FlashMessages
  alias CodeLeadWeb.TaskLive.AgentTab
  alias CodeLeadWeb.TaskLive.DiffTab
  alias CodeLeadWeb.TaskLive.TaskTab
  alias CodeLeadWeb.TaskLive.TerminalTab

  @tabs [:task, :agent, :diff, :terminal]

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
        projects: Projects.list_projects(),
        task: task,
        current_message: nil,
        chat_pending?: false,
        show_feedback?: false,
        diff_files: nil,
        diff_stats: nil,
        diff_error: nil,
        diff_loading?: false,
        folder_artifact: nil
      )
      |> load_task()
      |> stream_configure(:events, dom_id: & &1.id)
      |> stream(:events, [])
      |> seed_history()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = parse_tab(params["tab"], socket.assigns.task)

    socket = assign(socket, tab: tab)
    socket = if tab == :diff, do: maybe_load_diff(socket), else: socket

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

  def handle_event("retry_run", _params, socket) do
    socket.assigns.task |> Runtime.retry_task() |> after_action(socket)
  end

  def handle_event("approve", _params, socket) do
    case Runtime.approve(socket.assigns.task) do
      {:ok, _task, outcome} ->
        {:noreply, socket |> put_flash(:info, outcome.note) |> load_task()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, approve_error(reason))}
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

  def handle_event("archive", _params, socket) do
    socket.assigns.task |> Tasks.archive() |> after_action(socket)
  end

  ## Planning: edits, executor/reviewers, chat

  def handle_event("validate_edit", %{"task" => params}, socket) do
    changeset = Task.planning_changeset(socket.assigns.task, params)
    {:noreply, assign(socket, edit_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_edit", %{"task" => params}, socket) do
    case Tasks.update_task(socket.assigns.task, params) do
      {:ok, _task} ->
        {:noreply, socket |> put_flash(:info, "Task updated.") |> load_task()}

      {:error, changeset} ->
        {:noreply, assign(socket, edit_form: to_form(changeset))}
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

  def handle_event("send_chat", %{"message" => message}, socket) do
    %{task: task, assistant_agent: assistant} = socket.assigns

    case {String.trim(message), assistant} do
      {"", _assistant} ->
        {:noreply, socket}

      {_message, nil} ->
        {:noreply, put_flash(socket, :error, "No planning assistant (LLM agent) is configured.")}

      {content, assistant} ->
        {:noreply,
         socket
         |> assign(chat_pending?: true, pending_chat: content)
         |> start_async(:chat_reply, fn -> Planning.send_message(task, assistant.id, content) end)}
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

  def handle_async(:load_diff, {:ok, result}, socket) do
    socket = assign(socket, diff_loading?: false)

    case result do
      {:ok, files, stats} ->
        {:noreply, assign(socket, diff_files: files, diff_stats: stats, diff_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, diff_error: "git diff failed: #{inspect(reason)}")}
    end
  end

  def handle_async(:load_diff, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, diff_loading?: false, diff_error: "diff crashed: #{inspect(reason)}")}
  end

  ## PubSub

  @impl true
  def handle_info({:task_event, _task_id, event}, socket) do
    {:noreply, socket |> ingest_event(event) |> maybe_reload(event)}
  end

  def handle_info({:board_changed, _project_id, task_id}, socket) do
    if task_id == socket.assigns.task.id do
      {:noreply, load_task(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  ## Data loading

  defp load_task(socket) do
    task = Tasks.get_task!(socket.assigns.task.id)
    project = socket.assigns.project
    planning? = task.state == :planning

    repository = task.repository_id && Projects.get_repository!(task.repository_id)
    agents = Map.new(Agents.list_agents(project.id), &{&1.id, &1})

    assign(socket,
      task: task,
      page_title: task.title,
      repository: repository,
      executor: task.agent_id && agents[task.agent_id],
      agents: agents,
      steps: Tasks.steps(task.id),
      reviewers: Tasks.reviewers(task.id),
      reviews: Reviews.list_reviews(task.id),
      task_spend: Costs.task_spend(task.id),
      runs: Costs.task_runs(task.id),
      messages: Planning.list_messages(task.id),
      assistant_agent: assistant_agent(project.id),
      eligible_executors:
        (planning? && Agents.eligible_executors(task.work_type, project.id)) || [],
      eligible_reviewers:
        (planning? && Agents.eligible_reviewers(task.work_type, project.id)) || [],
      edit_form: to_form(Task.planning_changeset(task, %{})),
      attention_count: length(Tasks.attention_tasks(project.id)),
      project_spend: Costs.project_spend(project.id)
    )
  end

  defp assistant_agent(project_id) do
    project_id |> Agents.list_agents() |> Enum.find(&(&1.driver == :llm_api))
  end

  defp parse_tab(param, task) do
    case Enum.find(@tabs, &(Atom.to_string(&1) == param)) do
      nil -> default_tab(task.state)
      tab -> tab
    end
  end

  defp default_tab(:planning), do: :task
  defp default_tab(:running), do: :agent
  defp default_tab(:review), do: :diff
  defp default_tab(_state), do: :task

  defp maybe_load_diff(%{assigns: %{task: task}} = socket) do
    cond do
      socket.assigns.diff_loading? or socket.assigns.diff_files != nil ->
        socket

      task.target == :repo and is_binary(task.worktree_path) and socket.assigns.repository ->
        worktree = task.worktree_path
        base = socket.assigns.repository.default_branch

        socket
        |> assign(diff_loading?: true, diff_error: nil)
        |> start_async(:load_diff, fn -> run_diff(worktree, base) end)

      task.target == :folder ->
        assign(socket, folder_artifact: load_folder_artifact(task.id))

      true ->
        socket
    end
  end

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

  ## Live event ingestion (Agent tab)

  defp ingest_event(socket, {:message_chunk, text}) do
    assign(socket, current_message: (socket.assigns.current_message || "") <> text)
  end

  defp ingest_event(socket, event) do
    socket
    |> flush_current_message()
    |> stream_event(event)
  end

  defp flush_current_message(%{assigns: %{current_message: nil}} = socket), do: socket

  defp flush_current_message(%{assigns: %{current_message: text}} = socket) do
    socket
    |> assign(current_message: nil)
    |> stream_insert(:events, event_entry(:message, "MSG", text))
  end

  defp stream_event(socket, {:run_started, agent_name}) do
    stream_insert(socket, :events, event_entry(:system, "RUN", "#{agent_name} started"))
  end

  defp stream_event(socket, {:tool_call, detail}) do
    text = tool_call_text(detail)
    stream_insert(socket, :events, event_entry(:tool, "TOOL", text))
  end

  defp stream_event(socket, {:question, text}) do
    stream_insert(socket, :events, event_entry(:question, "QUESTION", text))
  end

  defp stream_event(socket, {:permission_request, %{id: id, detail: detail}}) do
    entry = event_entry(:permission, "PERMISSION", detail, %{ref: to_string(id)})
    stream_insert(socket, :events, entry)
  end

  defp stream_event(socket, {:run_completed, result}) do
    text = "success · #{Format.cost_tokens(usage_cents(result), usage_tokens(result))}"
    stream_insert(socket, :events, event_entry(:result_ok, "RESULT", text))
  end

  defp stream_event(socket, {:run_failed, detail}) do
    stream_insert(socket, :events, event_entry(:result_error, "RESULT", "failed · #{detail}"))
  end

  defp stream_event(socket, {:run_cancelled, _result}) do
    stream_insert(socket, :events, event_entry(:system, "RESULT", "cancelled"))
  end

  defp stream_event(socket, {:review_completed, %{agent: agent, verdict: verdict}}) do
    text = "#{agent} reviewed · #{verdict || "no verdict"}"
    stream_insert(socket, :events, event_entry(:system, "REVIEW", text))
  end

  defp stream_event(socket, {:review_cycle_completed, cycle}) do
    stream_insert(
      socket,
      :events,
      event_entry(:system, "REVIEW", "review cycle #{cycle} finished")
    )
  end

  defp stream_event(socket, _unknown), do: socket

  defp tool_call_text(%{name: name, detail: detail}), do: "#{name} #{detail}"
  defp tool_call_text(%{name: name}), do: to_string(name)
  defp tool_call_text(other), do: inspect(other)

  defp usage_tokens(%{usage: %{total_tokens: tokens}}), do: tokens
  defp usage_tokens(_result), do: nil

  defp usage_cents(%{usage: %{cost_cents: cents}}), do: cents
  defp usage_cents(_result), do: nil

  defp event_entry(kind, label, text, meta \\ %{}) do
    %{
      id: "evt-#{System.unique_integer([:positive, :monotonic])}",
      kind: kind,
      label: label,
      text: text,
      at: DateTime.utc_now(),
      meta: meta
    }
  end

  # Events aren't persisted; seed the feed with the audit trail so the
  # Agent tab has history after a reload.
  defp seed_history(socket) do
    entries =
      Enum.map(socket.assigns.steps, fn step ->
        %{
          id: "step-#{step.id}",
          kind: :step,
          label: step.kind |> Atom.to_string() |> String.upcase(),
          text: step.summary,
          at: step.inserted_at,
          meta: %{executor_type: step.executor_type, executor_name: step.executor_name}
        }
      end)

    stream(socket, :events, entries)
  end

  @state_bearing_events [
    :run_started,
    :run_completed,
    :run_failed,
    :run_cancelled,
    :question,
    :permission_request,
    :review_completed,
    :review_cycle_completed
  ]

  defp maybe_reload(socket, event)
       when is_tuple(event) and elem(event, 0) in @state_bearing_events do
    load_task(socket)
  end

  defp maybe_reload(socket, _event), do: socket

  defp after_action(result, socket) do
    case result do
      {:ok, _task} ->
        {:noreply, load_task(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FlashMessages.transition_error(reason))}
    end
  end

  defp approve_error(reason) when reason in [:invalid_state],
    do: FlashMessages.transition_error(reason)

  defp approve_error(reason), do: "Finalization failed: #{inspect(reason)}"

  ## Template

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      project={@project}
      projects={@projects}
      attention_count={@attention_count}
      project_spend={@project_spend}
      budget_limit_cents={@project.budget_limit_cents}
      sidebar={:rail}
    >
      <header class="shrink-0 border-b border-border bg-surface">
        <div class="flex items-center gap-2.5 px-4 pt-3.5 sm:gap-3.5 sm:px-6">
          <Layouts.sidebar_toggle />
          <.link
            navigate={~p"/projects/#{@project.id}/board"}
            class="inline-flex size-8 shrink-0 items-center justify-center rounded-[9px] border border-border bg-surface text-text2 hover:bg-surface2"
            aria-label="Back to board"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </.link>
          <h1 class="min-w-0 truncate text-[15px] font-semibold tracking-tight text-text sm:text-lg">
            {@task.title}
          </h1>
          <.state_badge state={@task.state} run_state={@task.run_state} />
          <.agent_pill :if={@executor} name={@executor.name} harness={@executor.harness} />
          <.cost_stat
            cost_cents={@task_spend.cost_cents}
            tokens={@task_spend.tokens}
            class="hidden md:inline"
          />
          <div class="flex-1" />
          <div class="hidden items-center gap-2 lg:flex">
            <.header_actions task={@task} />
          </div>
        </div>
        <.tab_nav tabs={tab_links(@project, @task)} active={@tab} class="mt-3 px-4 sm:px-6" />
      </header>

      <div class="min-h-0 flex-1 overflow-auto pb-24 lg:pb-0">
        <TaskTab.task_tab
          :if={@tab == :task}
          task={@task}
          repository={@repository}
          executor={@executor}
          steps={@steps}
          reviewers={@reviewers}
          reviews={@reviews}
          runs={@runs}
          task_spend={@task_spend}
          messages={@messages}
          assistant_agent={@assistant_agent}
          chat_pending?={@chat_pending?}
          pending_chat={assigns[:pending_chat]}
          eligible_executors={@eligible_executors}
          eligible_reviewers={@eligible_reviewers}
          edit_form={@edit_form}
          show_feedback?={@show_feedback?}
        />
        <AgentTab.agent_tab
          :if={@tab == :agent}
          task={@task}
          events={@streams.events}
          current_message={@current_message}
          task_spend={@task_spend}
        />
        <DiffTab.diff_tab
          :if={@tab == :diff}
          task={@task}
          reviews={@reviews}
          diff_files={@diff_files}
          diff_stats={@diff_stats}
          diff_error={@diff_error}
          diff_loading?={@diff_loading?}
          folder_artifact={@folder_artifact}
        />
        <TerminalTab.terminal_tab :if={@tab == :terminal} task={@task} />
      </div>

      <div class="fixed inset-x-0 bottom-0 z-30 flex gap-2.5 border-t border-border bg-surface p-3.5 lg:hidden">
        <.header_actions task={@task} mobile />
      </div>

      <.feedback_modal :if={@show_feedback?} />
    </Layouts.app>
    """
  end

  defp tab_links(project, task) do
    for tab <- @tabs do
      %{
        id: tab,
        label: tab_label(tab),
        patch: ~p"/projects/#{project.id}/tasks/#{task.id}?tab=#{tab}"
      }
    end
  end

  defp tab_label(:task), do: "Task"
  defp tab_label(:agent), do: "Agent"
  defp tab_label(:diff), do: "Diff"
  defp tab_label(:terminal), do: "Terminal"

  attr :task, :map, required: true
  attr :mobile, :boolean, default: false

  defp header_actions(%{task: %{state: :planning}} = assigns) do
    ~H"""
    <.button
      variant="primary"
      phx-click="start_run"
      class={@mobile && "flex-1"}
      id={action_id("start-run", @mobile)}
    >
      Start run
    </.button>
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
      class={@mobile && "hidden"}
    >
      Send back
    </.button>
    <.button phx-click="toggle_feedback" id={action_id("request-changes", @mobile)}>
      {if @mobile, do: "Changes", else: "Request changes"}
    </.button>
    <.button
      variant="primary"
      phx-click="approve"
      class={@mobile && "flex-1"}
      id={action_id("approve", @mobile)}
    >
      Approve & merge
    </.button>
    """
  end

  defp header_actions(%{task: %{state: :done, archived_at: nil}} = assigns) do
    ~H"""
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

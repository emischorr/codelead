defmodule CodeLeadWeb.TaskLive.TaskTab do
  @moduledoc """
  The Task tab: attention banner, description/spec (editable while in
  Planning), the planning-assistant chat, the timeline, and the
  executor/reviewers/cost rail.
  """
  use CodeLeadWeb, :html

  alias CodeLead.Agents

  attr :task, :map, required: true
  attr :repository, :map, default: nil
  attr :executor, :map, default: nil
  attr :steps, :list, required: true
  attr :reviewers, :list, required: true
  attr :reviews, :list, required: true
  attr :runs, :list, required: true
  attr :task_stat, :map, required: true
  attr :messages, :list, required: true
  attr :assistant_agent, :map, default: nil
  attr :chat_pending?, :boolean, default: false
  attr :pending_chat, :string, default: nil
  attr :eligible_executors, :list, default: []
  attr :eligible_reviewers, :list, default: []
  attr :edit_form, :any, required: true
  attr :show_feedback?, :boolean, default: false

  def task_tab(assigns) do
    ~H"""
    <div class="mx-auto grid max-w-6xl items-start gap-4 p-4 sm:p-6 xl:grid-cols-[1fr_320px]">
      <div class="flex min-w-0 flex-col gap-4">
        <.attention_banner
          :if={@task.attention}
          type={@task.attention.type}
          detail={@task.attention.detail}
        >
          <:actions :if={@task.attention.type == :permission_request && @task.attention.ref}>
            <.button
              variant="primary"
              phx-click="answer_permission"
              phx-value-ref={@task.attention.ref}
              phx-value-granted="true"
              id="banner-grant"
            >
              Allow
            </.button>
            <.button
              phx-click="answer_permission"
              phx-value-ref={@task.attention.ref}
              phx-value-granted="false"
              id="banner-deny"
            >
              Deny
            </.button>
          </:actions>
        </.attention_banner>

        <.description_card
          task={@task}
          repository={@repository}
          edit_form={@edit_form}
          editable?={@task.state == :planning}
        />

        <.chat_card
          task={@task}
          messages={@messages}
          assistant_agent={@assistant_agent}
          chat_pending?={@chat_pending?}
          pending_chat={@pending_chat}
        />

        <.section_card label="Timeline" id="timeline-card">
          <ol class="flex flex-col">
            <.timeline_start id="timeline-start" at={@task.inserted_at} />
            <.timeline_entry
              :for={step <- @steps}
              id={"timeline-step-#{step.id}"}
              executor_type={step.executor_type}
              summary={step.summary}
              at={step.inserted_at}
            />
          </ol>
          <p :if={@steps == []} class="text-[13px] text-text3">Nothing else has happened yet.</p>
        </.section_card>
      </div>

      <div class="flex flex-col gap-4">
        <.people_card
          task={@task}
          executor={@executor}
          reviewers={@reviewers}
          reviews={@reviews}
          eligible_executors={@eligible_executors}
          eligible_reviewers={@eligible_reviewers}
        />
        <.cost_card runs={@runs} task_stat={@task_stat} />
      </div>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :repository, :map, default: nil
  attr :edit_form, :any, required: true
  attr :editable?, :boolean, required: true

  defp description_card(assigns) do
    ~H"""
    <.section_card label="Description" id="description-card">
      <:actions :if={@editable?}>
        <button
          type="button"
          phx-click={JS.toggle(to: "#task-edit-form") |> JS.toggle(to: "#task-description-view")}
          class="cursor-pointer text-xs font-semibold text-accent hover:underline"
          id="toggle-edit"
        >
          Edit
        </button>
      </:actions>

      <div id="task-description-view" class="flex flex-col gap-2.5">
        <p class="whitespace-pre-wrap text-[13.5px] leading-relaxed text-text" phx-no-format>{@task.description || "No description yet."}</p>
        <div :if={@task.spec} class="flex flex-col gap-1.5">
          <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
            Spec / acceptance criteria
          </span>
          <p class="whitespace-pre-wrap text-[13px] leading-relaxed text-text2" phx-no-format>{@task.spec}</p>
        </div>
        <div class="mt-0.5 flex flex-wrap gap-1.5">
          <span class="rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[11px] text-text2">
            {@task.work_type}
          </span>
          <span class="rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[11px] text-text2">
            {@task.target}
          </span>
          <span
            :if={@repository}
            class="rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[11px] text-text2"
          >
            repo: {@repository.name}
          </span>
          <span
            :if={@task.branch_name}
            class="rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[11px] text-text2"
          >
            branch: {@task.branch_name}
          </span>
          <span class="rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[11px] text-text2">
            {priority_label(@task.priority)}
          </span>
          <span
            :if={@task.ready_flag}
            class="rounded-full bg-ok-soft px-2.5 py-0.5 font-mono text-[11px] font-semibold text-ok"
          >
            ✓ ready
          </span>
        </div>
      </div>

      <.form
        :if={@editable?}
        for={@edit_form}
        id="task-edit-form"
        phx-change="validate_edit"
        phx-submit="save_edit"
        class="hidden"
      >
        <.input field={@edit_form[:title]} type="text" label="Title" />
        <.input field={@edit_form[:description]} type="textarea" label="Description" rows="3" />
        <.input field={@edit_form[:spec]} type="textarea" label="Spec / acceptance criteria" rows="4" />
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@edit_form[:priority]}
            type="select"
            label="Priority"
            options={[Low: "low", Normal: "normal", High: "high", Urgent: "urgent"]}
          />
          <div class="flex items-end pb-2">
            <.input field={@edit_form[:ready_flag]} type="checkbox" label="Ready to run" />
          </div>
        </div>
        <div class="flex justify-end gap-2">
          <.button
            type="button"
            phx-click={JS.toggle(to: "#task-edit-form") |> JS.toggle(to: "#task-description-view")}
          >
            Cancel
          </.button>
          <.button variant="primary" type="submit" phx-disable-with="Saving…">Save</.button>
        </div>
      </.form>
    </.section_card>
    """
  end

  attr :task, :map, required: true
  attr :messages, :list, required: true
  attr :assistant_agent, :map, default: nil
  attr :chat_pending?, :boolean, required: true
  attr :pending_chat, :string, default: nil

  defp chat_card(assigns) do
    ~H"""
    <.section_card label="Planning assistant" id="chat-card">
      <div
        :if={@messages != [] || @pending_chat}
        class="flex max-h-96 flex-col gap-2.5 overflow-y-auto"
        id="chat-messages"
      >
        <.chat_bubble :for={message <- @messages} role={message.role} content={message.content} />
        <.chat_bubble :if={@pending_chat} role={:user} content={@pending_chat} />
        <div :if={@chat_pending?} class="flex items-center gap-2 text-xs text-text3">
          <span class="size-1.5 animate-pulse rounded-full bg-accent" /> Assistant is thinking…
        </div>
      </div>
      <p
        :if={@messages == [] && !@pending_chat && @task.state == :planning}
        class="text-[13px] text-text3"
      >
        Sharpen the spec together before starting the run.
      </p>

      <form
        :if={@task.state == :planning}
        id="chat-form"
        phx-submit="send_chat"
        class="flex gap-2"
      >
        <input
          type="text"
          name="message"
          placeholder={chat_placeholder(@assistant_agent)}
          disabled={@chat_pending? || is_nil(@assistant_agent)}
          autocomplete="off"
          class="h-10 min-w-0 flex-1 rounded-lg border border-border bg-bg px-3.5 text-[13px] text-text placeholder:text-text3 focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/40 disabled:opacity-60"
        />
        <button
          type="submit"
          disabled={@chat_pending? || is_nil(@assistant_agent)}
          class="flex size-10 shrink-0 cursor-pointer items-center justify-center rounded-lg bg-accent text-white hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
          aria-label="Send message"
        >
          <.icon name="hero-paper-airplane" class="size-4" />
        </button>
      </form>
      <p :if={@task.state != :planning && @messages == []} class="text-[13px] text-text3">
        No planning conversation was recorded.
      </p>
    </.section_card>
    """
  end

  defp chat_placeholder(nil), do: "No LLM agent configured for planning"
  defp chat_placeholder(_assistant), do: "Ask the assistant to refine the spec…"

  attr :task, :map, required: true
  attr :executor, :map, default: nil
  attr :reviewers, :list, required: true
  attr :reviews, :list, required: true
  attr :eligible_executors, :list, default: []
  attr :eligible_reviewers, :list, default: []

  defp people_card(assigns) do
    assigns = assign(assigns, :latest_verdicts, latest_verdicts(assigns.reviews))

    ~H"""
    <.section_card label="Executor" id="people-card">
      <div :if={@executor} class="flex items-center gap-2.5">
        <span class="flex size-8 items-center justify-center rounded-[9px] bg-surface2">
          <.agent_dot harness={@executor.harness} />
        </span>
        <div class="flex min-w-0 flex-col">
          <span class="truncate text-[13px] font-semibold text-text">{@executor.name}</span>
          <span class="truncate font-mono text-[10.5px] text-text3">
            {@executor.driver}{if @executor.model_variant, do: " · #{@executor.model_variant}"}
          </span>
        </div>
      </div>
      <p :if={!@executor && @task.state != :planning} class="text-[13px] text-text3">
        No executor selected.
      </p>
      <form :if={@task.state == :planning} id="executor-form" phx-change="set_executor">
        <select
          name="agent_id"
          class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text focus:border-accent focus:outline-none"
        >
          <option value="">Choose executor…</option>
          <option
            :for={agent <- @eligible_executors}
            value={agent.id}
            selected={@task.agent_id == agent.id}
          >
            {agent.name}
          </option>
        </select>
      </form>

      <div class="h-px bg-border" />

      <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">Reviewers</span>
      <div :if={@task.state != :planning} class="flex flex-col gap-2">
        <div :for={reviewer <- @reviewers} class="flex items-center gap-2">
          <span class={["size-[7px] rounded-full", verdict_dot(@latest_verdicts[reviewer.id])]} />
          <span class="min-w-0 flex-1 truncate text-[12.5px] font-medium text-text">
            {reviewer.name}
          </span>
          <span class="font-mono text-[10.5px] text-text3">
            {verdict_text(@latest_verdicts[reviewer.id])}
          </span>
        </div>
        <p :if={@reviewers == []} class="text-[13px] text-text3">
          No reviewers — review is human-only.
        </p>
      </div>
      <form
        :if={@task.state == :planning}
        id="reviewers-form"
        phx-change="set_reviewers"
        class="flex flex-col gap-1.5"
      >
        <label
          :for={agent <- @eligible_reviewers}
          class="flex cursor-pointer items-center gap-2 text-[13px] text-text"
        >
          <input
            type="checkbox"
            name="reviewer_ids[]"
            value={agent.id}
            checked={Enum.any?(@reviewers, &(&1.id == agent.id))}
            class="size-4 rounded border-border accent-accent"
          />
          {agent.name}
        </label>
        <p :if={@eligible_reviewers == []} class="text-[13px] text-text3">
          No review-capable agents for this work type.
        </p>
      </form>
    </.section_card>
    """
  end

  attr :harness, :atom, default: nil

  defp agent_dot(assigns) do
    ~H"""
    <span
      class="size-2.5 rounded-full"
      style={"background: #{if @harness == :claude_code, do: "#D97757", else: "var(--run)"}"}
    />
    """
  end

  defp latest_verdicts(reviews) do
    # list_reviews/1 orders newest cycle first; first hit per agent wins.
    Enum.reduce(reviews, %{}, fn review, acc ->
      Map.put_new(acc, review.agent_id, review.verdict)
    end)
  end

  defp verdict_dot(:pass), do: "bg-ok"
  defp verdict_dot(:concerns), do: "bg-warn"
  defp verdict_dot(:block), do: "bg-del-text"
  defp verdict_dot(_pending), do: "bg-text3 animate-pulse"

  defp verdict_text(nil), do: "pending"
  defp verdict_text(verdict), do: to_string(verdict)

  attr :runs, :list, required: true
  attr :task_stat, :map, required: true

  defp cost_card(assigns) do
    ~H"""
    <.section_card label="Cost" id="cost-card">
      <div class="flex flex-col gap-2 font-mono text-xs">
        <div
          :for={run <- Enum.take(@runs, 8)}
          class="flex items-center justify-between gap-2 text-text2"
          title={token_breakdown(run)}
        >
          <span class="min-w-0 flex-1 truncate">
            {run.agent_name || "run"} <span class={run_status_class(run.status)}>·</span>
          </span>
          <span class="shrink-0">
            {Format.run_stat(
              run.cost_cents,
              run.total_tokens,
              run.duration_ms,
              Agents.billing_mode(run.provider_kind)
            )}
          </span>
        </div>
        <p :if={@runs == []} class="font-sans text-[13px] text-text3">No runs yet.</p>
        <div :if={@runs != []} class="h-px bg-border" />
        <div class="flex items-center justify-between font-semibold text-text">
          <span>total</span>
          <span>
            {Format.run_stat(
              @task_stat.cost_cents,
              @task_stat.tokens,
              @task_stat.duration_ms,
              @task_stat.cost_mode
            )}
          </span>
        </div>
      </div>
    </.section_card>
    """
  end

  # Hover detail: where a run's tokens actually went. Cache reads are
  # usually the bulk of a coding run and are billed differently, so the
  # single total on the row can look surprising without it.
  defp token_breakdown(run) do
    [
      {"in", run.prompt_tokens},
      {"out", run.completion_tokens},
      {"cache read", run.cached_read_tokens},
      {"cache write", run.cached_write_tokens},
      {"reasoning", run.reasoning_tokens}
    ]
    |> Enum.reject(fn {_label, count} -> count in [nil, 0] end)
    |> case do
      [] -> nil
      parts -> Enum.map_join(parts, ", ", fn {label, n} -> "#{label} #{Format.tokens(n)}" end)
    end
  end

  defp run_status_class(:ok), do: "text-ok"
  defp run_status_class(:error), do: "text-del-text"
  defp run_status_class(_status), do: "text-text3"

  defp priority_label(priority), do: "P: #{priority}"
end

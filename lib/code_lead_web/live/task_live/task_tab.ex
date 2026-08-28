defmodule CodeLeadWeb.TaskLive.TaskTab do
  @moduledoc """
  The Task tab: attention banner, description/spec (editable while in
  Planning), the planning-agent card, the timeline, and the
  executor/reviewers/cost rail.
  """
  use CodeLeadWeb, :html

  alias CodeLead.Agents
  alias CodeLead.Findings.Finding
  alias CodeLead.Git
  alias CodeLeadWeb.ForgeLinks
  alias CodeLeadWeb.FormOptions

  attr :task, :map, required: true
  attr :repository, :map, default: nil
  attr :repositories, :list, default: []
  attr :executor, :map, default: nil
  attr :agents, :map, default: %{}
  attr :steps, :list, required: true
  attr :reviewers, :list, required: true
  attr :reviews, :list, required: true
  attr :runs, :list, required: true
  attr :task_stat, :map, required: true
  attr :findings, :list, default: []
  attr :decisions, :string, default: ""
  attr :survey_run_count, :integer, default: 0
  attr :survey_report, :map, default: nil
  attr :survey_delta, :map, default: nil
  attr :latest_survey_step, :map, default: nil
  attr :finding_expanded, :any, default: nil
  attr :finding_action, :map, default: nil
  attr :show_raw_report?, :boolean, default: false
  attr :hide_resolved?, :boolean, default: false
  attr :eligible_planners, :list, default: []
  attr :selected_planner, :map, default: nil
  attr :survey_pending?, :boolean, default: false
  attr :eligible_executors, :list, default: []
  attr :eligible_reviewers, :list, default: []
  attr :edit_form, :any, required: true
  attr :editing?, :boolean, default: false
  attr :show_feedback?, :boolean, default: false
  attr :finalize_mode, :atom, default: :pull_request
  attr :project_finalize_mode, :atom, default: :pull_request
  attr :container_licensed?, :boolean, default: false

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
          <%!-- The form itself lives on the Agent tab beside the question,
                where the agent's options and their descriptions are. --%>
          <:actions :if={@task.attention.type == :agent_question && @task.attention.ref}>
            <.button
              variant="primary"
              patch={~p"/projects/#{@task.project_id}/tasks/#{@task.id}?tab=agent"}
              id="banner-answer-question"
            >
              Answer
            </.button>
            <.button
              phx-click="skip_question"
              phx-value-ref={@task.attention.ref}
              id="banner-skip-question"
            >
              Skip
            </.button>
          </:actions>
        </.attention_banner>

        <.description_card
          task={@task}
          edit_form={@edit_form}
          decisions={@decisions}
          editable?={@task.state == :planning}
          editing?={@editing? && @task.state == :planning}
        />

        <.planning_card
          task={@task}
          findings={@findings}
          agents={@agents}
          repository={@repository}
          survey_run_count={@survey_run_count}
          survey_report={@survey_report}
          survey_delta={@survey_delta}
          latest_survey_step={@latest_survey_step}
          finding_expanded={@finding_expanded}
          finding_action={@finding_action}
          show_raw_report?={@show_raw_report?}
          hide_resolved?={@hide_resolved?}
          eligible_planners={@eligible_planners}
          selected_planner={@selected_planner}
          survey_pending?={@survey_pending?}
        />

        <.section_card label="Timeline" id="timeline-card">
          <ol class="flex flex-col">
            <.timeline_start id="timeline-start" at={@task.inserted_at} />
            <.timeline_entry
              :for={step <- @steps}
              id={"timeline-step-#{step.id}"}
              executor_type={step.executor_type}
              summary={Format.step_summary(step.summary)}
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
        <.target_card
          task={@task}
          repository={@repository}
          repositories={@repositories}
          finalize_mode={@finalize_mode}
          project_finalize_mode={@project_finalize_mode}
          container_licensed?={@container_licensed?}
        />
        <.cost_card runs={@runs} task_stat={@task_stat} />
      </div>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :edit_form, :any, required: true
  attr :decisions, :string, default: ""
  attr :editable?, :boolean, required: true
  attr :editing?, :boolean, required: true

  defp description_card(assigns) do
    ~H"""
    <.section_card label="Description" id="description-card">
      <:actions :if={@editable? && !@editing?}>
        <div class="flex items-center gap-3">
          <button
            type="button"
            phx-click="toggle_edit"
            class="cursor-pointer text-xs font-semibold text-accent hover:underline"
            id="toggle-edit"
          >
            Edit
          </button>
          <button
            type="button"
            phx-click="delete_task"
            data-confirm="Delete this task? This can't be undone."
            class="cursor-pointer text-xs font-semibold text-del-text hover:underline"
            id="delete-task"
          >
            Delete
          </button>
        </div>
      </:actions>

      <div :if={!@editing?} id="task-description-view" class="flex flex-col gap-2.5">
        <p class="whitespace-pre-wrap text-[13.5px] leading-relaxed text-text" phx-no-format>{@task.description || "No description yet."}</p>
        <div :if={@task.spec} class="flex flex-col gap-1.5">
          <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
            Spec / acceptance criteria
          </span>
          <p class="whitespace-pre-wrap text-[13px] leading-relaxed text-text2" phx-no-format>{@task.spec}</p>
        </div>
        <%!-- P6: exactly what gets injected into the agent's prompt,
              rendered verbatim. The edit surface is the finding row. --%>
        <div
          :if={@decisions != ""}
          id="task-decisions"
          class="flex flex-col gap-1.5 rounded-xl bg-surface2 px-3.5 py-2.5"
        >
          <span class="text-[10.5px] font-semibold uppercase tracking-wider text-text3">
            Included in the agent's prompt
          </span>
          <.markdown text={@decisions} class="text-[12.5px] text-text2" />
        </div>
        <div class="mt-0.5 flex flex-wrap gap-1.5">
          <%!-- Target, repository and branch live in the Target card on the rail. --%>
          <span class="rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[11px] text-text2">
            {@task.work_type}
          </span>
          <span class="rounded-full bg-surface2 px-2.5 py-0.5 font-mono text-[11px] text-text2">
            {priority_label(@task.priority)}
          </span>
        </div>
      </div>

      <.form
        :if={@editing?}
        for={@edit_form}
        id="task-edit-form"
        phx-change="validate_edit"
        phx-submit="save_edit"
      >
        <.input field={@edit_form[:title]} type="text" label="Title" />
        <.input field={@edit_form[:description]} type="textarea" label="Description" rows="6" />
        <.input field={@edit_form[:spec]} type="textarea" label="Spec / acceptance criteria" rows="4" />
        <div class="grid grid-cols-2 gap-3">
          <.input
            field={@edit_form[:work_type]}
            type="select"
            label="Work type"
            options={FormOptions.work_types()}
          />
          <.input
            field={@edit_form[:priority]}
            type="select"
            label="Priority"
            options={[Low: "low", Normal: "normal", High: "high", Urgent: "urgent"]}
          />
        </div>
        <div class="flex justify-end gap-2">
          <.button type="button" phx-click="toggle_edit" id="cancel-edit">Cancel</.button>
          <.button variant="primary" type="submit" phx-disable-with="Saving…">Save</.button>
        </div>
      </.form>
    </.section_card>
    """
  end

  attr :task, :map, required: true
  attr :findings, :list, required: true
  attr :agents, :map, default: %{}
  attr :repository, :map, default: nil
  attr :survey_run_count, :integer, default: 0
  attr :survey_report, :map, default: nil
  attr :survey_delta, :map, default: nil
  attr :latest_survey_step, :map, default: nil
  attr :finding_expanded, :any, default: nil
  attr :finding_action, :map, default: nil
  attr :show_raw_report?, :boolean, default: false
  attr :hide_resolved?, :boolean, default: false
  attr :eligible_planners, :list, default: []
  attr :selected_planner, :map, default: nil
  attr :survey_pending?, :boolean, default: false

  # One card for the whole planning-agent lifecycle: pick an agent and
  # run it on top, findings (once any exist) and the chat below.
  defp planning_card(assigns) do
    {active, obsolete} =
      Enum.split_with(assigns.findings, &(Finding.display_state(&1) != :obsolete))

    visible =
      if assigns.hide_resolved?,
        do: Enum.filter(active, &is_nil(&1.resolution)),
        else: active

    assigns =
      assign(assigns,
        forge: (assigns.repository && Git.forge(assigns.repository.git_url)) || :other,
        default_branch: assigns.repository && assigns.repository.default_branch,
        visible: visible,
        obsolete: obsolete,
        any_resolved?: Enum.any?(assigns.findings, & &1.resolution),
        parse_failed?: assigns.survey_report != nil and assigns.survey_report.parse_failed?,
        repo_aware?: repo_aware?(assigns.selected_planner)
      )

    ~H"""
    <.section_card label="Planning agent" id="planning-card">
      <:actions>
        <div class="flex items-center gap-3">
          <span :if={@survey_run_count > 1} id="findings-run-count" class="text-[11px] text-text3">
            run {@survey_run_count}{delta_caption(@survey_delta)}
          </span>
          <button
            :if={@any_resolved?}
            type="button"
            id="toggle-hide-resolved"
            phx-click="toggle_hide_resolved"
            class="cursor-pointer text-xs font-semibold text-accent hover:underline"
          >
            {if @hide_resolved?, do: "Show resolved", else: "Hide resolved"}
          </button>
          <button
            :if={@survey_report}
            type="button"
            id="toggle-raw-report"
            phx-click="toggle_raw_report"
            class="cursor-pointer text-xs font-semibold text-accent hover:underline"
          >
            {if @show_raw_report?, do: "Hide raw report", else: "Show raw report"}
          </button>
        </div>
      </:actions>

      <div :if={@task.state == :planning} class="flex flex-col gap-2">
        <div class="flex items-center gap-2">
          <form id="planner-form" phx-change="set_planner" class="min-w-0 flex-1">
            <select
              name="agent_id"
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text focus:border-accent focus:outline-none"
            >
              <option :if={@eligible_planners == []} value="">
                No planning agents for this work type
              </option>
              <option
                :for={agent <- @eligible_planners}
                value={agent.id}
                selected={@selected_planner && @selected_planner.id == agent.id}
              >
                {agent.name} · {agent_level(agent)}
              </option>
            </select>
          </form>

          <%!-- Same button either level; only the repo-level survey needs
                a repository to read. --%>
          <button
            type="button"
            id="run-refinement"
            phx-click="run_refinement"
            disabled={
              @survey_pending? || is_nil(@selected_planner) ||
                (@repo_aware? && is_nil(@task.repository_id))
            }
            class="flex h-10 shrink-0 cursor-pointer items-center justify-center gap-2 rounded-lg border border-border bg-surface px-3.5 text-[13px] font-medium text-text hover:border-accent disabled:cursor-not-allowed disabled:opacity-50"
          >
            <.icon name="hero-magnifying-glass" class="size-4" />
            {if @repo_aware? && is_nil(@task.repository_id),
              do: "Link a repository first",
              else: "Run agent refinement"}
          </button>
        </div>

        <div :if={@survey_pending?} class="flex items-center gap-2 text-xs text-text3">
          <span class="size-1.5 animate-pulse rounded-full bg-accent" />
          Refinement running — this can take a few minutes…
        </div>
      </div>

      <p :if={@parse_failed?} id="findings-parse-hint" class="text-xs text-text3">
        Could not parse findings from the last survey — showing the raw report.
      </p>

      <div
        :if={@survey_report && (@show_raw_report? || @parse_failed?)}
        id="findings-raw-report"
        class="flex flex-col gap-1.5 rounded-xl bg-surface2 px-3.5 py-2.5"
      >
        <span class="text-[10.5px] font-semibold uppercase tracking-wider text-text3">
          {survey_label(@survey_report.message, @agents)}
        </span>
        <.markdown text={@survey_report.message.content} class="text-[13px]" />
      </div>

      <details
        :if={
          !@show_raw_report? && !@parse_failed? && @survey_report &&
            @survey_report.narrative not in [nil, ""]
        }
        id="findings-narrative"
        class="group rounded-xl bg-surface2"
        open={@findings == []}
      >
        <summary class="flex cursor-pointer list-none items-center gap-2 px-3.5 py-2.5 [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right"
            class="size-3.5 text-text3 transition-transform group-open:rotate-90"
          />
          <span class="text-[10.5px] font-semibold uppercase tracking-wider text-text3">
            {survey_label(@survey_report.message, @agents)}
          </span>
        </summary>
        <.markdown text={@survey_report.narrative} class="px-3.5 pb-3 text-[13px]" />
      </details>

      <div :if={@visible != []} id="findings-list" class="flex flex-col">
        <.finding_row
          :for={finding <- @visible}
          finding={finding}
          task_state={@task.state}
          forge={@forge}
          default_branch={@default_branch}
          latest_survey_step={@latest_survey_step}
          expanded?={@finding_expanded && MapSet.member?(@finding_expanded, finding.id)}
          action={@finding_action}
        />
      </div>

      <p
        :if={@findings == [] && @survey_report && !@parse_failed?}
        class="text-[13px] text-text3"
      >
        The survey reported no findings.
      </p>

      <details :if={@obsolete != []} id="findings-obsolete" class="group">
        <summary class="flex cursor-pointer list-none items-center gap-2 text-xs text-text3 [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right"
            class="size-3.5 transition-transform group-open:rotate-90"
          />
          {length(@obsolete)} no longer applicable
        </summary>
        <div class="mt-1.5 flex flex-col gap-1 pl-5.5">
          <span
            :for={finding <- @obsolete}
            id={"finding-obsolete-#{finding.id}"}
            class="text-[13px] text-text3 line-through"
          >
            {finding.title}
          </span>
        </div>
      </details>

      <p
        :if={@task.state != :planning && @findings == [] && is_nil(@survey_report)}
        class="text-[13px] text-text3"
      >
        No refinement was recorded.
      </p>
    </.section_card>
    """
  end

  attr :finding, :map, required: true
  attr :task_state, :atom, required: true
  attr :forge, :any, required: true
  attr :default_branch, :string, default: nil
  attr :latest_survey_step, :map, default: nil
  attr :expanded?, :boolean, default: false
  attr :action, :map, default: nil

  defp finding_row(assigns) do
    finding = assigns.finding

    assigns =
      assign(assigns,
        state: Finding.display_state(finding),
        actionable?: assigns.task_state == :planning,
        agent_resolved?: Finding.agent_resolved?(finding),
        still_flagged?: Finding.still_flagged?(finding, assigns.latest_survey_step),
        note_form?: assigns.action != nil and assigns.action.id == finding.id
      )

    ~H"""
    <div
      class="border-t border-border py-2.5 first:border-t-0 first:pt-0"
      id={"finding-#{@finding.id}"}
    >
      <div class="flex items-center gap-2.5">
        <%!-- The checkbox is the human's tick, never the agent's: it only
              reflects (and toggles) the `:addressed` resolution. --%>
        <.icon :if={@state == :dismissed} name="hero-no-symbol" class="size-4 shrink-0 text-text3" />
        <button
          :if={@state != :dismissed && @actionable?}
          type="button"
          role="checkbox"
          aria-checked={to_string(@state == :addressed)}
          id={"finding-check-#{@finding.id}"}
          phx-click={if @state == :addressed, do: "reopen_finding", else: "finding_action"}
          phx-value-id={@finding.id}
          phx-value-resolution="addressed"
          class={[
            "flex size-4 shrink-0 cursor-pointer items-center justify-center rounded border",
            @state == :addressed && "border-accent bg-accent text-white",
            @state != :addressed && "border-border bg-surface hover:border-accent"
          ]}
        >
          <.icon :if={@state == :addressed} name="hero-check" class="size-3" />
        </button>
        <span
          :if={@state != :dismissed && !@actionable?}
          class={[
            "flex size-4 shrink-0 items-center justify-center rounded border",
            @state == :addressed && "border-accent bg-accent text-white",
            @state != :addressed && "border-border bg-surface"
          ]}
        >
          <.icon :if={@state == :addressed} name="hero-check" class="size-3" />
        </span>

        <.badge variant={severity_variant(@finding.severity)}>{@finding.severity}</.badge>

        <button
          type="button"
          id={"finding-toggle-#{@finding.id}"}
          phx-click="toggle_finding"
          phx-value-id={@finding.id}
          class="flex min-w-0 flex-1 cursor-pointer items-center gap-2 text-left"
        >
          <span class={[
            "truncate text-[13px]",
            (@state == :dismissed && "text-text3") || "text-text"
          ]}>
            {@finding.title}
          </span>
          <span :if={@agent_resolved?} class="shrink-0 text-[11px] text-ok">
            agent considers this resolved
          </span>
          <span :if={@still_flagged?} class="shrink-0 text-[11px] text-warn">
            agent still flags this
          </span>
          <span :if={@finding.resolution} class="ml-auto shrink-0 text-[11px] text-text3">
            {resolver_label(@finding)}
          </span>
          <.icon
            name="hero-chevron-right"
            class={["size-3.5 shrink-0 text-text3 transition-transform", @expanded? && "rotate-90"]}
          />
        </button>
      </div>

      <div
        :if={@expanded?}
        class="mt-2 flex flex-col gap-2 pl-[52px]"
        id={"finding-detail-#{@finding.id}"}
      >
        <.markdown :if={@finding.body} text={@finding.body} class="text-[13px] text-text2" />

        <div :if={@finding.paths != []} class="flex flex-wrap gap-1.5">
          <.cited_path
            :for={path <- @finding.paths}
            path={path}
            forge={@forge}
            default_branch={@default_branch}
          />
        </div>

        <p :if={@finding.resolution_note} class="text-[13px] text-text2">
          <span class="font-semibold text-text3">
            {if @finding.resolution == :dismissed, do: "Dismissed:", else: "Decision:"}
          </span>
          {@finding.resolution_note}
        </p>

        <div :if={@actionable? && @note_form?} class="flex flex-col gap-1">
          <form
            phx-submit="resolve_finding"
            phx-change="validate_finding_note"
            id={"finding-note-form-#{@finding.id}"}
            class="flex flex-col gap-2"
          >
            <input type="hidden" name="finding_id" value={@finding.id} />
            <input type="hidden" name="resolution" value={@action.resolution} />
            <input
              type="text"
              name="note"
              id={"finding-note-#{@finding.id}"}
              placeholder={
                if @action.resolution == :dismissed,
                  do: "(Optional) Why is this out of scope?",
                  else: "What was decided?"
              }
              autocomplete="off"
              class="h-8 w-full rounded-lg border border-border bg-bg px-2.5 text-[13px] text-text placeholder:text-text3 focus:border-accent focus:outline-none"
            />
            <div class="flex items-center gap-3">
              <label
                for={"finding-add-to-spec-checkbox-#{@finding.id}"}
                class="flex cursor-pointer items-center gap-1.5 text-[12px] text-text2"
              >
                <input type="hidden" name="add_to_spec" value="false" />
                <input
                  type="checkbox"
                  id={"finding-add-to-spec-checkbox-#{@finding.id}"}
                  name="add_to_spec"
                  value="true"
                  class="size-3.5 rounded border-border bg-surface text-accent accent-accent focus:ring-accent/40"
                /> Add to spec
              </label>
              <div class="ml-auto flex items-center gap-2">
                <.button
                  variant="primary"
                  type="submit"
                  disabled={@action.resolution == :addressed && !@action.note_present?}
                >
                  Save
                </.button>
                <.button type="button" phx-click="cancel_finding_action">Cancel</.button>
              </div>
            </div>
          </form>
          <p class="text-[11px] text-text3">
            Add a note to carry this decision into the run.
          </p>
        </div>

        <div :if={@actionable? && !@note_form?} class="flex items-center gap-3">
          <button
            :if={@state == :open}
            type="button"
            id={"finding-address-#{@finding.id}"}
            phx-click="finding_action"
            phx-value-id={@finding.id}
            phx-value-resolution="addressed"
            class="cursor-pointer text-xs font-semibold text-accent hover:underline"
          >
            Address
          </button>
          <button
            :if={@state == :open}
            type="button"
            id={"finding-dismiss-#{@finding.id}"}
            phx-click="finding_action"
            phx-value-id={@finding.id}
            phx-value-resolution="dismissed"
            class="cursor-pointer text-xs font-semibold text-text3 hover:underline"
          >
            Dismiss
          </button>
          <button
            :if={@state in [:addressed, :dismissed]}
            type="button"
            id={"finding-reopen-#{@finding.id}"}
            phx-click="reopen_finding"
            phx-value-id={@finding.id}
            class="cursor-pointer text-xs font-semibold text-text3 hover:underline"
          >
            Reopen
          </button>
          <button
            :if={@state in [:addressed, :dismissed] && @finding.resolution_note}
            type="button"
            id={"finding-add-to-spec-#{@finding.id}"}
            phx-click="add_finding_to_spec"
            phx-value-id={@finding.id}
            class="cursor-pointer text-xs font-semibold text-accent hover:underline"
          >
            Add to spec
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :forge, :any, required: true
  attr :default_branch, :string, default: nil

  defp cited_path(assigns) do
    url =
      assigns.default_branch &&
        ForgeLinks.file_url(assigns.forge, assigns.default_branch, assigns.path)

    assigns = assign(assigns, :url, url)

    ~H"""
    <a
      :if={@url}
      href={@url}
      target="_blank"
      rel="noreferrer"
      class="rounded bg-surface2 px-1.5 py-0.5 font-mono text-[11px] text-accent hover:underline"
    >
      {@path}
    </a>
    <span :if={!@url} class="rounded bg-surface2 px-1.5 py-0.5 font-mono text-[11px] text-text2">
      {@path}
    </span>
    """
  end

  # An ACP plan agent traverses the repo; an llm_api one reasons over
  # the text it is given. Same slot, different depth.
  defp repo_aware?(%{driver: :acp}), do: true
  defp repo_aware?(_planner), do: false

  defp agent_level(%{driver: :acp}), do: "Repo level"
  defp agent_level(_agent), do: "Task level"

  defp survey_label(%{kind: :survey} = message, agents) do
    case agents[message.agent_id] do
      nil -> "Repo survey"
      agent -> "Repo survey · #{agent.name}"
    end
  end

  defp survey_label(_message, _agents), do: nil

  defp severity_variant(:high), do: :danger
  defp severity_variant(:medium), do: :warn
  defp severity_variant(:low), do: :ok

  defp delta_caption(nil), do: ""

  defp delta_caption(delta) do
    parts =
      [
        {delta.new, "new"},
        {delta.resolved, "resolved"},
        {delta.not_applicable, "no longer applicable"}
      ]
      |> Enum.filter(fn {count, _label} -> count > 0 end)
      |> Enum.map_join(", ", fn {count, label} -> "#{count} #{label}" end)

    if parts == "", do: "", else: " · #{parts}"
  end

  defp resolver_label(%{resolved_by: %{username: username}} = finding) do
    "#{username} · #{Format.relative(finding.resolved_at)}"
  end

  defp resolver_label(finding), do: Format.relative(finding.resolved_at)

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

  attr :task, :map, required: true
  attr :repository, :map, default: nil
  attr :repositories, :list, default: []
  attr :finalize_mode, :atom, default: :pull_request
  attr :project_finalize_mode, :atom, default: nil
  attr :container_licensed?, :boolean, default: false

  defp target_card(assigns) do
    ~H"""
    <.section_card label="Target" id="target-card">
      <%!-- Planning is the only state where the execution shape is editable;
            afterwards a worktree or task folder already exists for it. --%>
      <form
        :if={@task.state == :planning}
        id="target-form"
        phx-change="set_target"
        class="flex flex-col gap-2.5"
      >
        <select
          name="target"
          class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text focus:border-accent focus:outline-none"
        >
          <option
            :for={{label, value} <- FormOptions.targets()}
            value={value}
            selected={to_string(@task.target) == value}
          >
            {label}
          </option>
        </select>
        <select
          :if={@task.target == :repo}
          name="repository_id"
          class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text focus:border-accent focus:outline-none"
        >
          <option value="">Choose repository…</option>
          <option
            :for={repository <- @repositories}
            value={repository.id}
            selected={@task.repository_id == repository.id}
          >
            {repository.name}
          </option>
        </select>
        <%!-- The Container option is disabled rather than dropped when the
              instance is unlicensed: a task already set to :container would
              otherwise render with Local selected and misreport itself. --%>
        <label :if={@task.target == :repo} class="flex flex-col gap-1">
          <span class="text-[12px] text-text3">Execution</span>
          <select
            name="execution_env"
            class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text focus:border-accent focus:outline-none"
          >
            <option
              :for={{label, value} <- FormOptions.execution_envs()}
              value={value}
              disabled={value == "container" and not @container_licensed?}
              selected={to_string(@task.execution_env) == value}
            >
              {label}
            </option>
          </select>
          <span :if={not @container_licensed?} class="text-[12px] text-text3">
            Container execution requires a commercial license.
          </span>
        </label>
      </form>

      <div :if={@task.state != :planning} class="flex flex-col gap-2 text-[13px]">
        <div class="flex items-center justify-between gap-2">
          <span class="text-text3">Target</span>
          <span class="font-mono text-[12px] text-text">{@task.target}</span>
        </div>
        <div :if={@repository} class="flex items-center justify-between gap-2">
          <span class="shrink-0 text-text3">Repository</span>
          <span class="min-w-0 truncate font-mono text-[12px] text-text">{@repository.name}</span>
        </div>
        <div :if={@task.target == :repo} class="flex items-center justify-between gap-2">
          <span class="text-text3">Execution</span>
          <span class="font-mono text-[12px] text-text">{@task.execution_env}</span>
        </div>
      </div>

      <p :if={@task.target == :repo && is_nil(@task.repository_id)} class="text-[13px] text-warn">
        Pick a repository before running this task.
      </p>

      <%!-- What Approve will do. It lives here rather than in the action
            bar because it is a property of where the work lands, and the
            bar stays a single primary button. --%>
      <div :if={@task.state != :done && is_nil(@task.archived_at)} class="flex flex-col gap-2">
        <div class="h-px bg-border" />
        <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
          On approve
        </span>
        <form id="finalize-form" phx-change="set_finalize_mode">
          <select
            name="finalize_mode"
            class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text focus:border-accent focus:outline-none"
          >
            <option value="" selected={is_nil(@task.finalize_mode)}>
              Project default · {FormOptions.finalize_mode_label(@project_finalize_mode)}
            </option>
            <option
              :for={{label, value} <- FormOptions.finalize_modes(@task.target)}
              value={value}
              selected={to_string(@task.finalize_mode) == value}
            >
              {label}
            </option>
          </select>
        </form>
        <p class="text-[12px] leading-relaxed text-text3">
          {Format.finalize_hint(@finalize_mode, @repository && @repository.default_branch)}
        </p>
        <p
          :if={@finalize_mode == :commit_to_path && is_nil(@task.repository_id)}
          class="text-[13px] text-warn"
        >
          This mode commits the artifact into a repository, but none is linked.
        </p>
      </div>

      <div :if={@task.branch_name} class="flex flex-col gap-1">
        <div class="h-px bg-border" />
        <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">Branch</span>
        <span class="truncate font-mono text-[11.5px] text-text2" title={@task.branch_name}>
          {@task.branch_name}
        </span>
      </div>

      <div :if={@task.target == :folder && @task.state == :done} class="flex flex-col gap-1">
        <div class="h-px bg-border" />
        <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">Artifact</span>
        <.link
          href={~p"/projects/#{@task.project_id}/tasks/#{@task.id}/artifact"}
          download
          id="task-artifact-link"
          class="inline-flex items-center gap-1.5 text-[12.5px] text-accent hover:underline"
        >
          <.icon name="hero-arrow-down-tray" class="size-3.5" /> task-{@task.id}.zip
        </.link>
      </div>
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

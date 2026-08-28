defmodule CodeLeadWeb.TaskLive.ReviewTab do
  @moduledoc """
  The Review tab: reviewer findings plus the artifact to judge — the
  worktree diff for repo targets or the artifact preview for folder
  targets, always on screen. When the repository declares a
  `preview_port` a preview strip sits above the diff: run status,
  Start/Stop for the one-click preview, and an Open-preview link that
  opens the running app in a new browser tab (there is no embedded
  frame — the tab's own URL bar, history, and devtools are the
  toolbar). The link goes through `/preview/launch/:task_id`, the only
  web surface that turns a task into a preview URL.
  """
  use CodeLeadWeb, :html

  import CodeLeadWeb.DiffComponents
  import CodeLeadWeb.TaskLive.FindingsComponents

  alias CodeLead.Git.DiffFile

  attr :task, :map, required: true
  attr :reviews, :list, required: true
  attr :review_findings, :list, default: []
  attr :review_reports, :map, default: %{}, doc: "review id => %{narrative, parse_failed?}"
  attr :review_steps, :map, default: %{}, doc: "review id => its TaskStep"
  attr :finding_expanded, :any, default: nil
  attr :finding_action, :map, default: nil
  attr :review_raw_expanded, :any, default: nil, doc: "MapSet of review ids showing raw"
  attr :forge, :any, default: :other
  attr :default_branch, :string, default: nil
  attr :diff_files, :list, default: nil
  attr :diff_stats, :map, default: nil
  attr :diff_error, :string, default: nil
  attr :diff_loading?, :boolean, default: false
  attr :expanded, :any, required: true, doc: "MapSet of expanded file paths"
  attr :following?, :boolean, default: false
  attr :executing?, :boolean, default: false
  attr :folder_artifact, :map, default: nil
  attr :preview_available?, :boolean, default: false
  attr :preview_command?, :boolean, default: false
  attr :preview_run, :any, default: :stopped

  def review_tab(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col">
      <.preview_strip
        :if={@preview_available?}
        task_id={@task.id}
        preview_command?={@preview_command?}
        preview_run={@preview_run}
      />

      <div
        :if={!@preview_available? && @task.target == :repo}
        id="preview-hint"
        class="shrink-0 border-b border-border bg-surface px-4 py-1.5 text-[11.5px] text-text3 sm:px-6"
      >
        Declare a preview port on the
        <.link
          navigate={~p"/settings/projects/#{@task.project_id}"}
          class="font-medium text-text2 underline decoration-border underline-offset-2 hover:text-text"
        >
          repository
        </.link>
        to enable live preview.
      </div>

      <div
        :if={match?({:failed, _tail}, @preview_run)}
        id="preview-failure"
        class="shrink-0 border-b border-border bg-surface px-4 py-3 sm:px-6"
      >
        <p class="mb-2 text-[12px] font-semibold text-warn">
          The preview command failed to start — its output:
        </p>
        <pre class="max-h-40 overflow-auto rounded-[9px] border border-border bg-surface2 p-3 font-mono text-[11px] leading-relaxed text-text2 whitespace-pre-wrap">{failure_tail(@preview_run)}</pre>
      </div>

      <div class="min-h-0 flex-1">
        <.diff_view
          task={@task}
          reviews={@reviews}
          review_findings={@review_findings}
          review_reports={@review_reports}
          review_steps={@review_steps}
          finding_expanded={@finding_expanded}
          finding_action={@finding_action}
          review_raw_expanded={@review_raw_expanded}
          forge={@forge}
          default_branch={@default_branch}
          diff_files={@diff_files}
          diff_stats={@diff_stats}
          diff_error={@diff_error}
          diff_loading?={@diff_loading?}
          expanded={@expanded}
          following?={@following?}
          executing?={@executing?}
          folder_artifact={@folder_artifact}
        />
      </div>
    </div>
    """
  end

  attr :task_id, :integer, required: true
  attr :preview_command?, :boolean, default: false
  attr :preview_run, :any, default: :stopped

  defp preview_strip(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center gap-2 border-b border-border bg-surface px-4 py-1.5 sm:px-6">
      <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
        Live preview
      </span>

      <div class="ml-auto flex items-center gap-2">
        <span
          :if={@preview_command? && @preview_run != :stopped}
          id="preview-run-status"
          class={[
            "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-[11px] font-semibold",
            run_status_class(@preview_run)
          ]}
        >
          <span class={["h-1.5 w-1.5 rounded-full", run_dot_class(@preview_run)]}></span>
          {run_status_label(@preview_run)}
        </span>
        <button
          :if={
            @preview_command? && (@preview_run == :stopped or match?({:failed, _tail}, @preview_run))
          }
          id="preview-server-start"
          type="button"
          phx-click="preview_start"
          class="rounded-[9px] border border-border bg-surface2 px-3 py-1 text-[11.5px] font-semibold text-text2 transition-colors hover:text-text"
        >
          Start preview
        </button>
        <button
          :if={@preview_command? && @preview_run in [:starting, :ready, :unreachable]}
          id="preview-server-stop"
          type="button"
          phx-click="preview_stop"
          class="rounded-[9px] border border-border bg-surface2 px-3 py-1 text-[11.5px] font-semibold text-text2 transition-colors hover:text-text"
        >
          Stop
        </button>
        <a
          id="preview-open"
          href={~p"/preview/launch/#{@task_id}"}
          target="_blank"
          rel="noopener"
          class="inline-flex items-center gap-1.5 rounded-[9px] bg-accent px-3 py-1 text-[11.5px] font-semibold text-white transition-opacity hover:opacity-90"
        >
          Open preview <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </a>
      </div>
    </div>
    """
  end

  defp run_status_label(:starting), do: "Starting…"
  defp run_status_label(:ready), do: "Running"
  defp run_status_label(:unreachable), do: "Unreachable"
  defp run_status_label({:failed, _tail}), do: "Failed"
  defp run_status_label(_other), do: ""

  defp run_status_class(:ready), do: "border-ok/30 text-ok"
  defp run_status_class(:unreachable), do: "border-warn-border text-warn"
  defp run_status_class({:failed, _tail}), do: "border-warn-border text-warn"
  defp run_status_class(_starting), do: "border-border text-text3"

  defp run_dot_class(:ready), do: "bg-ok"
  defp run_dot_class(:unreachable), do: "bg-warn"
  defp run_dot_class({:failed, _tail}), do: "bg-warn"
  defp run_dot_class(_starting), do: "animate-pulse bg-text3"

  defp failure_tail({:failed, tail}) when is_binary(tail) and tail != "", do: tail
  defp failure_tail(_other), do: "(no output)"

  attr :task, :map, required: true
  attr :reviews, :list, required: true
  attr :review_findings, :list, default: []
  attr :review_reports, :map, default: %{}
  attr :review_steps, :map, default: %{}
  attr :finding_expanded, :any, default: nil
  attr :finding_action, :map, default: nil
  attr :review_raw_expanded, :any, default: nil
  attr :forge, :any, default: :other
  attr :default_branch, :string, default: nil
  attr :diff_files, :list, default: nil
  attr :diff_stats, :map, default: nil
  attr :diff_error, :string, default: nil
  attr :diff_loading?, :boolean, default: false
  attr :expanded, :any, required: true
  attr :following?, :boolean, default: false
  attr :executing?, :boolean, default: false
  attr :folder_artifact, :map, default: nil

  defp diff_view(assigns) do
    ~H"""
    <div class="flex h-full min-h-0">
      <aside
        :if={@diff_files}
        class="hidden w-[300px] shrink-0 overflow-y-auto border-r border-border bg-surface p-3 lg:block"
      >
        <.file_list files={@diff_files} stats={@diff_stats} expanded={@expanded} />
      </aside>

      <div id="diff-pane" phx-hook=".ScrollToFile" class="min-w-0 flex-1 overflow-y-auto">
        <.diff_toolbar
          :if={@diff_files}
          stats={@diff_stats}
          refreshing?={@diff_loading?}
          following?={@following?}
          executing?={@executing?}
        />

        <div class="mx-auto flex max-w-4xl flex-col gap-4 p-4 sm:p-6">
          <.findings_section
            :if={@reviews != []}
            task={@task}
            reviews={@reviews}
            review_findings={@review_findings}
            review_reports={@review_reports}
            review_steps={@review_steps}
            finding_expanded={@finding_expanded}
            finding_action={@finding_action}
            review_raw_expanded={@review_raw_expanded}
            forge={@forge}
            default_branch={@default_branch}
          />

          <div
            :if={@diff_loading? && is_nil(@diff_files)}
            class="flex items-center gap-2 text-[13px] text-text3"
          >
            <.pulse_dot class="bg-accent" /> Loading diff…
          </div>

          <.empty_state
            :if={@diff_error}
            icon="hero-exclamation-triangle"
            title="Couldn't load the diff"
          >
            {@diff_error}
          </.empty_state>

          <.empty_state
            :if={no_content?(assigns)}
            icon="hero-code-bracket"
            title="Nothing to show yet"
          >
            {empty_reason(@task)}
          </.empty_state>

          <.empty_state
            :if={@diff_files == []}
            icon="hero-code-bracket"
            title="No changes in the worktree"
          >
            The agent hasn't changed any files against the base branch.
          </.empty_state>

          <.file_diff
            :for={file <- @diff_files || []}
            :key={DiffFile.path(file)}
            file={file}
            expanded?={MapSet.member?(@expanded, DiffFile.path(file))}
          />

          <.folder_preview :if={@folder_artifact} artifact={@folder_artifact} />
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToFile">
      const SCROLL_KEYS = new Set([
        "PageUp", "PageDown", "Home", "End", "ArrowUp", "ArrowDown", " "
      ])

      const typing = (el) => el && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)

      // This pane is what scrolls, not the window — the app shell is h-dvh
      // overflow-hidden. Listeners still sit on the document (key events
      // reach it wherever focus is), and scrolling is delegated to
      // scrollIntoView, which moves whichever ancestors need to move.
      export default {
        mounted() {
          this.programmatic = false
          this.released = false

          this.handleEvent("diff:scroll_to", ({id}) => {
            const el = document.getElementById(id)
            if (!el) { return }

            this.released = false
            this.hold()
            el.scrollIntoView({behavior: "smooth", block: "start"})
          })

          // wheel/touch/keys never fire for a programmatic scroll, so they
          // need no guard and release follow mode mid-animation. The
          // capture-phase scroll listener is the backstop for scrollbar
          // drags, which emit nothing else — that one does need the guard.
          this.onIntent = () => this.release()
          this.onKey = (e) => {
            if (SCROLL_KEYS.has(e.key) && !typing(e.target)) { this.release() }
          }
          this.onScroll = () => { if (!this.programmatic) { this.release() } }

          document.addEventListener("wheel", this.onIntent, {passive: true})
          document.addEventListener("touchmove", this.onIntent, {passive: true})
          document.addEventListener("keydown", this.onKey)
          document.addEventListener("scroll", this.onScroll, {capture: true, passive: true})
        },

        // One push per gesture, not per scroll tick.
        release() {
          if (this.released) { return }
          this.released = true
          this.pushEvent("diff_unfollow")
        },

        hold() {
          this.programmatic = true
          clearTimeout(this.holdTimer)
          this.holdTimer = setTimeout(() => { this.programmatic = false }, 1000)
        },

        destroyed() {
          clearTimeout(this.holdTimer)
          document.removeEventListener("wheel", this.onIntent)
          document.removeEventListener("touchmove", this.onIntent)
          document.removeEventListener("keydown", this.onKey)
          document.removeEventListener("scroll", this.onScroll, {capture: true})
        }
      }
    </script>
    """
  end

  attr :stats, :map, required: true
  attr :refreshing?, :boolean, required: true
  attr :following?, :boolean, required: true
  attr :executing?, :boolean, required: true

  defp diff_toolbar(assigns) do
    ~H"""
    <div
      id="diff-toolbar"
      class="sticky top-0 z-20 flex items-center gap-2.5 border-b border-border bg-surface/95 px-4 py-2 backdrop-blur sm:px-6"
    >
      <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
        {@stats.files} {if @stats.files == 1, do: "file", else: "files"} changed
      </span>
      <span class="font-mono text-[11px]">
        <span class="text-add-text">+{@stats.additions}</span>
        <span class="text-del-text">−{@stats.deletions}</span>
      </span>

      <div class="flex-1" />

      <button
        :if={@following?}
        id="diff-following"
        type="button"
        phx-click="diff_unfollow"
        title="Stop following"
        aria-label="Stop following the agent"
        class="inline-flex items-center gap-1.5 rounded-full bg-run/15 px-2.5 py-1 text-[11px] font-medium text-run transition-colors hover:bg-run/25"
      >
        <.pulse_dot /> Following agent
      </button>
      <button
        :if={@executing? && !@following?}
        id="diff-follow"
        type="button"
        phx-click="follow_agent"
        class="inline-flex items-center gap-1.5 rounded-full border border-border px-2.5 py-1 text-[11px] font-medium text-text2 hover:bg-surface2"
      >
        <.icon name="hero-play" class="size-3" /> Follow agent
      </button>

      <button
        id="diff-refresh"
        type="button"
        phx-click="refresh_diff"
        aria-label="Refresh diff"
        class="inline-flex size-7 items-center justify-center rounded-[9px] border border-border text-text2 hover:bg-surface2"
      >
        <.icon name="hero-arrow-path" class={["size-3.5", @refreshing? && "animate-spin"]} />
      </button>
    </div>
    """
  end

  defp no_content?(assigns) do
    is_nil(assigns.diff_files) and is_nil(assigns.folder_artifact) and
      not assigns.diff_loading? and is_nil(assigns.diff_error)
  end

  defp empty_reason(%{target: :repo, worktree_path: nil, state: :done, branch_name: branch})
       when is_binary(branch),
       do:
         "The worktree was pruned when this task was finalized. " <>
           "The work is on #{branch} — or already merged into the default branch."

  defp empty_reason(%{target: :repo, worktree_path: nil}),
    do: "A diff appears once a run has provisioned a worktree."

  defp empty_reason(%{target: :folder}),
    do: "The artifact preview appears once a run has produced output."

  defp empty_reason(_task), do: "No execution context yet."

  attr :task, :map, required: true
  attr :reviews, :list, required: true
  attr :review_findings, :list, default: []
  attr :review_reports, :map, default: %{}
  attr :review_steps, :map, default: %{}
  attr :finding_expanded, :any, default: nil
  attr :finding_action, :map, default: nil
  attr :review_raw_expanded, :any, default: nil
  attr :forge, :any, default: :other
  attr :default_branch, :string, default: nil

  # One box per latest-cycle reviewer. Findings whose agent is absent
  # from the latest cycle don't render in any box; they stay in the
  # data and in the request-changes prefill.
  defp findings_section(assigns) do
    assigns = assign(assigns, :latest, latest_cycle_reviews(assigns.reviews))

    ~H"""
    <div class="flex flex-col gap-2.5" id="reviewer-findings">
      <.reviewer_box
        :for={review <- @latest}
        review={review}
        task={@task}
        review_findings={@review_findings}
        report={@review_reports[review.id]}
        step={@review_steps[review.id]}
        finding_expanded={@finding_expanded}
        finding_action={@finding_action}
        review_raw_expanded={@review_raw_expanded}
        forge={@forge}
        default_branch={@default_branch}
      />
    </div>
    """
  end

  attr :review, :map, required: true
  attr :task, :map, required: true
  attr :review_findings, :list, default: []
  attr :report, :map, default: nil
  attr :step, :map, default: nil
  attr :finding_expanded, :any, default: nil
  attr :finding_action, :map, default: nil
  attr :review_raw_expanded, :any, default: nil
  attr :forge, :any, default: :other
  attr :default_branch, :string, default: nil

  defp reviewer_box(assigns) do
    review = assigns.review
    report = assigns.report
    parse_failed? = report != nil and report.parse_failed?

    raw_toggled? =
      assigns.review_raw_expanded != nil and
        MapSet.member?(assigns.review_raw_expanded, review.id)

    assigns =
      assign(assigns,
        findings: Enum.filter(assigns.review_findings, &(&1.agent_id == review.agent_id)),
        parse_failed?: parse_failed?,
        raw?: parse_failed? or raw_toggled?,
        raw_toggled?: raw_toggled?,
        narrative: report && report.narrative
      )

    ~H"""
    <details
      class="group rounded-[14px] border border-border bg-surface"
      open={@review.verdict != :pass}
    >
      <summary class="flex cursor-pointer list-none items-center gap-2.5 p-4 [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="size-3.5 text-text3 transition-transform group-open:rotate-90"
        />
        <span class="min-w-0 flex-1 truncate text-[13.5px] font-semibold text-text">
          {(@review.agent && @review.agent.name) || "Reviewer"}
        </span>
        <.badge variant={verdict_variant(@review.verdict)}>
          {@review.verdict || "pending"}
        </.badge>
      </summary>
      <div class="flex flex-col gap-3 border-t border-border px-4 py-3.5">
        <div :if={@review.findings} class="flex items-center gap-3">
          <p :if={@parse_failed?} id={"review-parse-hint-#{@review.id}"} class="text-xs text-text3">
            Could not parse this report — showing it raw.
          </p>
          <button
            :if={!@parse_failed?}
            type="button"
            id={"toggle-review-raw-#{@review.id}"}
            phx-click="toggle_review_raw"
            phx-value-id={@review.id}
            class="ml-auto cursor-pointer text-xs font-semibold text-accent hover:underline"
          >
            {if @raw_toggled?, do: "Hide raw report", else: "Show raw report"}
          </button>
        </div>

        <.markdown
          :if={@raw? && @review.findings}
          id={"review-raw-#{@review.id}"}
          text={@review.findings}
          class="rounded-xl bg-surface2 px-3.5 py-2.5 text-[13px]"
        />

        <.markdown
          :if={!@raw? && @narrative not in [nil, ""]}
          text={@narrative}
          class="text-[13px]"
        />

        <p
          :if={!@raw? && @narrative in [nil, ""] && @findings == []}
          class="text-[13px] text-text3"
        >
          No findings recorded.
        </p>

        <div :if={@findings != []} class="flex flex-col">
          <.finding_row
            :for={finding <- @findings}
            finding={finding}
            actionable?={@task.state == :review}
            note_required?={false}
            add_to_spec?={false}
            note_hint="Notes are prefilled into the Request-changes feedback."
            forge={@forge}
            default_branch={@default_branch}
            latest_step={@step}
            expanded?={@finding_expanded && MapSet.member?(@finding_expanded, finding.id)}
            action={@finding_action}
          />
        </div>
      </div>
    </details>
    """
  end

  defp latest_cycle_reviews([]), do: []

  defp latest_cycle_reviews(reviews) do
    latest_cycle = reviews |> Enum.map(& &1.cycle) |> Enum.max()
    Enum.filter(reviews, &(&1.cycle == latest_cycle))
  end

  defp verdict_variant(:pass), do: :ok
  defp verdict_variant(:concerns), do: :warn
  defp verdict_variant(:block), do: :warn
  defp verdict_variant(_pending), do: :neutral

  attr :artifact, :map, required: true

  defp folder_preview(assigns) do
    ~H"""
    <div class="flex flex-col gap-4" id="folder-artifact">
      <.section_card label="Artifact files">
        <ul class="flex flex-col gap-1 font-mono text-xs text-text2">
          <li :for={entry <- @artifact.entries} class="truncate">{entry}</li>
        </ul>
        <p :if={@artifact.entries == []} class="text-[13px] text-text3">The task folder is empty.</p>
      </.section_card>
      <.section_card :if={@artifact.output} label="output.md">
        <pre class="overflow-x-auto whitespace-pre-wrap font-mono text-xs leading-relaxed text-text">{@artifact.output}</pre>
      </.section_card>
    </div>
    """
  end
end

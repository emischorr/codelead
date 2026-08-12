defmodule CodeLeadWeb.TaskLive.DiffTab do
  @moduledoc """
  The Diff tab: reviewer findings plus the worktree diff for repo
  targets, or the artifact preview for folder targets.
  """
  use CodeLeadWeb, :html

  import CodeLeadWeb.DiffComponents

  alias CodeLead.Git.DiffFile

  attr :task, :map, required: true
  attr :reviews, :list, required: true
  attr :diff_files, :list, default: nil
  attr :diff_stats, :map, default: nil
  attr :diff_error, :string, default: nil
  attr :diff_loading?, :boolean, default: false
  attr :expanded, :any, required: true, doc: "MapSet of expanded file paths"
  attr :following?, :boolean, default: false
  attr :executing?, :boolean, default: false
  attr :folder_artifact, :map, default: nil

  def diff_tab(assigns) do
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
          <.findings_section :if={@reviews != []} reviews={@reviews} />

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

      // The app shell has no fixed height, so the window is what scrolls —
      // not this pane. Every listener therefore sits on the document, and
      // scrolling is delegated to scrollIntoView, which moves whichever
      // ancestors actually need to move.
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

  attr :reviews, :list, required: true

  defp findings_section(assigns) do
    assigns = assign(assigns, :latest, latest_cycle_reviews(assigns.reviews))

    ~H"""
    <div class="flex flex-col gap-2.5" id="reviewer-findings">
      <details
        :for={review <- @latest}
        class="group rounded-[14px] border border-border bg-surface"
        open={review.verdict != :pass}
      >
        <summary class="flex cursor-pointer list-none items-center gap-2.5 p-4 [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right"
            class="size-3.5 text-text3 transition-transform group-open:rotate-90"
          />
          <span class="min-w-0 flex-1 truncate text-[13.5px] font-semibold text-text">
            {(review.agent && review.agent.name) || "Reviewer"}
          </span>
          <.badge variant={verdict_variant(review.verdict)}>
            {review.verdict || "pending"}
          </.badge>
        </summary>
        <div class="border-t border-border px-4 py-3.5">
          <p class="whitespace-pre-wrap text-[13px] leading-relaxed text-text2" phx-no-format>{review.findings || "No findings recorded."}</p>
        </div>
      </details>
    </div>
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

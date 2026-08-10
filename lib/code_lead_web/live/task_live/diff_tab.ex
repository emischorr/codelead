defmodule CodeLeadWeb.TaskLive.DiffTab do
  @moduledoc """
  The Diff tab: reviewer findings plus the worktree diff for repo
  targets, or the artifact preview for folder targets.
  """
  use CodeLeadWeb, :html

  import CodeLeadWeb.DiffComponents

  attr :task, :map, required: true
  attr :reviews, :list, required: true
  attr :diff_files, :list, default: nil
  attr :diff_stats, :map, default: nil
  attr :diff_error, :string, default: nil
  attr :diff_loading?, :boolean, default: false
  attr :folder_artifact, :map, default: nil

  def diff_tab(assigns) do
    ~H"""
    <div class="flex h-full min-h-0">
      <aside
        :if={@diff_files}
        class="hidden w-[300px] shrink-0 overflow-y-auto border-r border-border bg-surface p-3 lg:block"
      >
        <.file_list files={@diff_files} stats={@diff_stats} />
      </aside>

      <div class="min-w-0 flex-1 overflow-y-auto">
        <div class="mx-auto flex max-w-4xl flex-col gap-4 p-4 sm:p-6">
          <.findings_section :if={@reviews != []} reviews={@reviews} />

          <div :if={@diff_loading?} class="flex items-center gap-2 text-[13px] text-text3">
            <span class="size-1.5 animate-pulse rounded-full bg-accent" /> Loading diff…
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

          <.file_diff :for={file <- @diff_files || []} file={file} />

          <.folder_preview :if={@folder_artifact} artifact={@folder_artifact} />
        </div>
      </div>
    </div>
    """
  end

  defp no_content?(assigns) do
    is_nil(assigns.diff_files) and is_nil(assigns.folder_artifact) and
      not assigns.diff_loading? and is_nil(assigns.diff_error)
  end

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

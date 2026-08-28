defmodule CodeLeadWeb.TaskLive.FindingsComponents do
  @moduledoc """
  The finding row shared by the planning card and the review tab: one
  severity-labelled item with expand, address/dismiss (with an optional
  note), and reopen. The caller decides whether the row is actionable
  and which phase affordances apply (`note_required?`, `add_to_spec?`);
  the events bubble to `CodeLeadWeb.TaskLive` in both places.
  """
  use CodeLeadWeb, :html

  alias CodeLead.Findings.Finding
  alias CodeLeadWeb.ForgeLinks

  attr :finding, :map, required: true
  attr :actionable?, :boolean, required: true
  attr :note_required?, :boolean, default: true
  attr :add_to_spec?, :boolean, default: true
  attr :note_hint, :string, default: nil
  attr :forge, :any, required: true
  attr :default_branch, :string, default: nil
  attr :latest_step, :map, default: nil
  attr :expanded?, :boolean, default: false
  attr :action, :map, default: nil

  def finding_row(assigns) do
    finding = assigns.finding

    assigns =
      assign(assigns,
        state: Finding.display_state(finding),
        agent_resolved?: Finding.agent_resolved?(finding),
        still_flagged?: Finding.still_flagged?(finding, assigns.latest_step),
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
            {note_label(@finding.resolution, @note_required?)}
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
              placeholder={note_placeholder(@action.resolution, @note_required?)}
              autocomplete="off"
              class="h-8 w-full rounded-lg border border-border bg-bg px-2.5 text-[13px] text-text placeholder:text-text3 focus:border-accent focus:outline-none"
            />
            <div class="flex items-center gap-3">
              <label
                :if={@add_to_spec?}
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
                  disabled={
                    @note_required? && @action.resolution == :addressed && !@action.note_present?
                  }
                >
                  Save
                </.button>
                <.button type="button" phx-click="cancel_finding_action">Cancel</.button>
              </div>
            </div>
          </form>
          <p :if={@note_hint} class="text-[11px] text-text3">
            {@note_hint}
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
            :if={@add_to_spec? && @state in [:addressed, :dismissed] && @finding.resolution_note}
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

  def cited_path(assigns) do
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

  @spec severity_variant(atom()) :: atom()
  def severity_variant(:high), do: :danger
  def severity_variant(:medium), do: :warn
  def severity_variant(:low), do: :ok

  defp note_label(:dismissed, _note_required?), do: "Dismissed:"
  defp note_label(_resolution, true), do: "Decision:"
  defp note_label(_resolution, false), do: "Note:"

  defp note_placeholder(resolution, note_required?) do
    case {resolution, note_required?} do
      {:dismissed, _} -> "(Optional) Why is this out of scope?"
      {_, true} -> "What was decided?"
      {_, false} -> "(Optional) What should the agent change?"
    end
  end

  defp resolver_label(%{resolved_by: %{username: username}} = finding) do
    "#{username} · #{Format.relative(finding.resolved_at)}"
  end

  defp resolver_label(finding), do: Format.relative(finding.resolved_at)
end

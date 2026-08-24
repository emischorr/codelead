defmodule CodeLeadWeb.UIComponents do
  @moduledoc """
  CodeLead's design-language components: badges, pills, cards, kanban
  building blocks, and the task-card shell. All styling is built on the
  design tokens defined in `assets/css/app.css`.

  Components take precomputed scalars and flags; callers resolve domain
  lookups (agent names, costs, verdict summaries) before rendering.
  """
  use Phoenix.Component

  import CodeLeadWeb.CoreComponents, only: [button: 1, icon: 1, input: 1]

  alias CodeLeadWeb.Format

  @doc """
  Renders a rounded pill badge.

  ## Examples

      <.badge variant={:warn}>Question</.badge>
      <.badge variant={:ok} soft={false}>2</.badge>
  """
  attr :variant, :atom, default: :neutral, values: [:neutral, :accent, :run, :warn, :ok]
  attr :soft, :boolean, default: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-[11px] font-semibold",
      badge_classes(@variant, @soft),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_classes(:neutral, true), do: "bg-surface2 text-text2"
  defp badge_classes(:accent, true), do: "bg-accent-soft text-accent"
  defp badge_classes(:run, true), do: "bg-run-soft text-run"
  defp badge_classes(:warn, true), do: "bg-warn-soft text-warn"
  defp badge_classes(:ok, true), do: "bg-ok-soft text-ok"
  defp badge_classes(:neutral, false), do: "bg-text3 text-surface"
  defp badge_classes(:accent, false), do: "bg-accent text-white"
  defp badge_classes(:run, false), do: "bg-run text-white"
  defp badge_classes(:warn, false), do: "bg-warn text-surface"
  defp badge_classes(:ok, false), do: "bg-ok text-white"

  @doc """
  Renders the task-state badge, with a pulsing dot while executing.
  """
  attr :state, :atom, required: true
  attr :run_state, :atom, default: :idle

  def state_badge(assigns) do
    ~H"""
    <.badge variant={state_variant(@state)}>
      <span
        :if={@state == :running and @run_state == :executing}
        class="size-1.5 animate-pulse rounded-full bg-run"
      />
      {state_label(@state, @run_state)}
    </.badge>
    """
  end

  defp state_variant(:planning), do: :neutral
  defp state_variant(:running), do: :run
  defp state_variant(:review), do: :accent
  defp state_variant(:done), do: :ok
  defp state_variant(_), do: :neutral

  defp state_label(:running, :failed), do: "Failed"
  defp state_label(:running, :queued), do: "Queued"

  defp state_label(state, _run_state) do
    state |> Atom.to_string() |> String.capitalize()
  end

  @doc """
  Renders the executor pill: a harness-colored dot plus the agent name.
  """
  attr :name, :string, required: true
  attr :harness, :atom, default: nil, doc: ":claude_code | :codex | nil"

  def agent_pill(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 rounded-full bg-surface2 px-2.5 py-0.5 text-[11px] font-semibold text-text2">
      <span class="size-1.5 rounded-full" style={"background: #{harness_color(@harness)}"} />
      {@name}
    </span>
    """
  end

  # Claude's brand orange is theme-independent; the rest use tokens.
  defp harness_color(:claude_code), do: "#D97757"
  defp harness_color(:codex), do: "var(--run)"
  defp harness_color(_), do: "var(--accent)"

  @doc """
  Renders a small pulsing status dot.
  """
  attr :class, :any, default: "bg-run"

  def pulse_dot(assigns) do
    ~H"""
    <span class={["inline-block size-1.5 animate-pulse rounded-full", @class]} />
    """
  end

  @doc """
  Renders a project's identity dot in its chosen color. `pulse` is set
  by the caller when the project has a task in Running — the dot then
  fades in its own color rather than borrowing `--run`, and gains a thin
  static ring so the fade reads clearly against the ring instead of just
  shrinking against the page background.
  """
  attr :color, :atom, required: true
  attr :pulse, :boolean, default: false
  attr :class, :any, default: nil

  def project_dot(assigns) do
    ~H"""
    <span class={["relative inline-flex size-2 shrink-0 items-center justify-center", @class]}>
      <span
        :if={@pulse}
        class="absolute -inset-[3px] rounded-full border"
        style={"border-color: var(--proj-#{@color})"}
      />
      <span class={[
        "size-2 shrink-0 rounded-[3px]",
        project_color_class(@color),
        @pulse && "animate-pulse"
      ]} />
    </span>
    """
  end

  @doc """
  Maps a project color to its Tailwind background utility.
  """
  @spec project_color_class(atom()) :: String.t()
  def project_color_class(:blue), do: "bg-proj-blue"
  def project_color_class(:indigo), do: "bg-proj-indigo"
  def project_color_class(:violet), do: "bg-proj-violet"
  def project_color_class(:pink), do: "bg-proj-pink"
  def project_color_class(:red), do: "bg-proj-red"
  def project_color_class(:cyan), do: "bg-proj-cyan"
  def project_color_class(:teal), do: "bg-proj-teal"
  def project_color_class(:green), do: "bg-proj-green"
  def project_color_class(:lime), do: "bg-proj-lime"
  def project_color_class(:yellow), do: "bg-proj-yellow"

  @doc """
  Renders a row of color swatches as a radio group, for picking a
  project's identity color. `options` is `FormOptions.project_colors/0`.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true
  slot :label

  def color_picker(assigns) do
    ~H"""
    <fieldset class="mb-4">
      <legend :if={@label != []} class="mb-1.5 text-[13.5px] font-medium text-text">
        {render_slot(@label)}
      </legend>
      <div class="flex flex-wrap gap-2">
        <label :for={{label, value} <- @options} class="cursor-pointer" title={label}>
          <input
            type="radio"
            name={@field.name}
            value={value}
            checked={to_string(@field.value) == value}
            class="peer sr-only"
          />
          <span class={[
            "block size-7 rounded-full ring-2 ring-transparent ring-offset-2 ring-offset-surface transition-shadow peer-checked:ring-text peer-focus-visible:ring-text",
            project_color_class(String.to_existing_atom(value))
          ]} />
        </label>
      </div>
    </fieldset>
    """
  end

  @doc """
  Renders the mono run stat, e.g. `$2.07 · 183.5k · 2m 14s`.

  `cost_mode` says how to read the money: `:exact` was billed,
  `:estimated` is the API-equivalent of a subscription run, `:free`
  is a local model. The caller resolves it — this component knows
  nothing about providers.
  """
  attr :cost_cents, :integer, default: nil
  attr :tokens, :integer, default: nil
  attr :duration_ms, :integer, default: nil
  attr :cost_mode, :atom, default: :exact
  attr :title, :string, default: nil
  attr :class, :any, default: nil

  def cost_stat(assigns) do
    ~H"""
    <span class={["font-mono text-[11px] text-text3", @class]} title={@title}>
      {Format.run_stat(@cost_cents, @tokens, @duration_ms, @cost_mode)}
    </span>
    """
  end

  @doc """
  Renders a headline readout: a big number with its label, an icon chip,
  and an optional detail line. `tone` colors the chip and the number.

  The caller formats `value` — this component does no number formatting,
  so the same tile carries counts, money, and durations.

  ## Examples

      <.stat_tile id="s" icon="hero-eye" label="Needs approval" value="4" tone={:warn} />
  """
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, default: nil
  attr :tone, :atom, default: :neutral, values: [:neutral, :accent, :run, :warn, :ok]
  attr :navigate, :string, default: nil
  slot :meter
  slot :footer, doc: "rows under the readout — a list the tile's number counts"

  def stat_tile(%{navigate: nil} = assigns) do
    ~H"""
    <div id={@id} class="rounded-[14px] border border-border bg-surface p-4">
      <.stat_tile_body {assigns} />
    </div>
    """
  end

  def stat_tile(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="block rounded-[14px] border border-border bg-surface p-4 transition-colors hover:border-accent"
    >
      <.stat_tile_body {assigns} />
    </.link>
    """
  end

  defp stat_tile_body(assigns) do
    ~H"""
    <div class="flex items-start gap-3">
      <span class={[
        "flex size-9 shrink-0 items-center justify-center rounded-[10px]",
        tone_chip(@tone)
      ]}>
        <.icon name={@icon} class="size-[18px]" />
      </span>
      <div class="min-w-0 flex-1">
        <span class="block text-[11px] font-semibold uppercase tracking-wider text-text3">
          {@label}
        </span>
        <span class={["mt-1 block font-mono text-[22px] font-semibold leading-none", tone_text(@tone)]}>
          {@value}
        </span>
        <span :if={@detail} class="mt-1.5 block truncate text-[11.5px] text-text3">{@detail}</span>
      </div>
    </div>
    {render_slot(@meter)}
    <div :if={@footer != []} class="mt-3 flex flex-col border-t border-border pt-1">
      {render_slot(@footer)}
    </div>
    """
  end

  defp tone_chip(:neutral), do: "bg-surface2 text-text2"
  defp tone_chip(:accent), do: "bg-accent-soft text-accent"
  defp tone_chip(:run), do: "bg-run-soft text-run"
  defp tone_chip(:warn), do: "bg-warn-soft text-warn"
  defp tone_chip(:ok), do: "bg-ok-soft text-ok"

  defp tone_text(:neutral), do: "text-text"
  defp tone_text(:accent), do: "text-accent"
  defp tone_text(:run), do: "text-run"
  defp tone_text(:warn), do: "text-warn"
  defp tone_text(:ok), do: "text-ok"

  @doc """
  Renders a progress bar for a value against a limit. Renders nothing
  without a limit — a bar with no ceiling would imply one.
  """
  attr :value, :integer, required: true
  attr :max, :integer, default: nil
  attr :tone, :atom, default: :accent, values: [:accent, :run, :warn, :ok]
  attr :class, :any, default: nil

  def meter(assigns) do
    ~H"""
    <div :if={@max && @max > 0} class={["h-1 rounded-full bg-border", @class]}>
      <div
        class={["h-1 rounded-full", meter_fill(@tone)]}
        style={"width: #{meter_percent(@value, @max)}%"}
      />
    </div>
    """
  end

  defp meter_fill(:accent), do: "bg-accent"
  defp meter_fill(:run), do: "bg-run"
  defp meter_fill(:warn), do: "bg-warn"
  defp meter_fill(:ok), do: "bg-ok"

  defp meter_percent(value, max), do: min(100, round(value / max * 100))

  @doc """
  Renders a surface card with an optional uppercase section label.

  ## Examples

      <.section_card label="Description">...</.section_card>
  """
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions

  def section_card(assigns) do
    ~H"""
    <div
      class={["flex flex-col gap-2.5 rounded-[14px] border border-border bg-surface p-4", @class]}
      {@rest}
    >
      <div :if={@label || @actions != []} class="flex items-center justify-between">
        <span :if={@label} class="text-[11px] font-semibold uppercase tracking-wider text-text3">
          {@label}
        </span>
        <div :if={@actions != []}>{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders the warn attention banner for a task's `attention` field.
  """
  attr :type, :atom, required: true
  attr :detail, :string, default: nil
  slot :actions

  def attention_banner(assigns) do
    ~H"""
    <div class="flex items-start gap-3.5 rounded-[14px] border border-warn-border bg-warn-soft p-4">
      <span class="mt-1 size-2 shrink-0 animate-pulse rounded-full bg-warn" />
      <div class="flex min-w-0 flex-1 flex-col gap-1">
        <span class="text-[13.5px] font-bold text-warn">{attention_title(@type)}</span>
        <span :if={@detail} class="break-words text-[13px] leading-relaxed text-text2">
          {@detail}
        </span>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  defp attention_title(:run_failed), do: "Run failed"
  defp attention_title(:review_ready), do: "Needs approval"
  defp attention_title(:agent_question), do: "Agent asks"
  defp attention_title(:permission_request), do: "Permission requested"
  defp attention_title(_), do: "Needs attention"

  @doc """
  Renders a relative timestamp that reveals the full time on hover.

  The `title` is rendered server-side in UTC so it works without
  JavaScript; the `.LocalTime` hook rewrites it to the viewer's zone.
  """
  attr :id, :string, required: true
  attr :at, :any, default: nil

  def timestamp(assigns) do
    ~H"""
    <span
      id={@id}
      class="shrink-0 cursor-help font-mono text-[11px] text-text3"
      phx-hook=".LocalTime"
      data-at={Format.iso8601(@at)}
      title={Format.absolute(@at)}
    >
      {Format.relative(@at)}
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      // `data-timezone` is the signed-in user's saved preference (root.html.heex);
      // empty means "follow the browser", same as `Intl`'s own default.
      const tz = document.documentElement.dataset.timezone || undefined
      const FMT = new Intl.DateTimeFormat(undefined, {dateStyle: "medium", timeStyle: "short", timeZone: tz})

      // The server-rendered UTC title is the no-JS fallback, and morphdom puts
      // it back on every patch — so updated() has to re-localize, not just mounted().
      export default {
        mounted() { this.localize() },
        updated() { this.localize() },
        localize() {
          const at = this.el.dataset.at
          if (!at) { return }
          const parsed = new Date(at)
          if (!isNaN(parsed)) { this.el.setAttribute("title", FMT.format(parsed)) }
        }
      }
    </script>
    """
  end

  @doc """
  Renders the node that opens a timeline — the task's creation. Styled
  apart from the entries below it so the oldest-first order is legible
  at a glance.
  """
  attr :id, :string, required: true
  attr :at, :any, default: nil

  def timeline_start(assigns) do
    ~H"""
    <li id={@id} class="group relative flex gap-3 pb-3 last:pb-0">
      <.timeline_rail />
      <span class="mt-1.5 size-2.5 shrink-0 rounded-full bg-accent ring-4 ring-accent-soft" />
      <span class="min-w-0 flex-1 text-[13px] font-medium text-text">Task created</span>
      <.timestamp id={@id <> "-time"} at={@at} />
    </li>
    """
  end

  @doc """
  Renders one audit-trail entry with the HUMAN/AGENT/SYSTEM chip.
  """
  attr :id, :string, required: true
  attr :executor_type, :atom, required: true, doc: ":human | :agent | :system"
  attr :summary, :string, required: true
  attr :at, :any, default: nil

  def timeline_entry(assigns) do
    ~H"""
    <li id={@id} class="group relative flex gap-3 pb-3 last:pb-0">
      <.timeline_rail />
      <span class="mt-1.5 size-2.5 shrink-0 rounded-full border border-border bg-surface" />
      <span class={[
        "h-[18px] w-[58px] shrink-0 self-start rounded-md text-center text-[10px] font-bold leading-[18px] tracking-wide",
        executor_chip(@executor_type)
      ]}>
        {@executor_type |> Atom.to_string() |> String.upcase()}
      </span>
      <span class="min-w-0 flex-1 break-words text-[13px] text-text">{@summary}</span>
      <.timestamp id={@id <> "-time"} at={@at} />
    </li>
    """
  end

  # The connector between two nodes. Positioned at half the 2.5 node width
  # so it runs through their centers; `group-last:` drops the tail on the
  # final row, which saves threading a `last?` flag through every entry.
  defp timeline_rail(assigns) do
    ~H"""
    <span class="absolute bottom-0 left-[4.5px] top-4 w-px bg-border group-last:hidden" />
    """
  end

  defp executor_chip(:human), do: "bg-surface2 text-text2"
  defp executor_chip(:agent), do: "bg-accent-soft text-accent"
  defp executor_chip(:system), do: "bg-run-soft text-run"

  @doc """
  Renders the underline tab navigation.

  Tabs are maps: `%{id: :task, label: "Task", patch: ~p"...", warn: false}`.
  A `warn: true` tab renders its label and icon in the attention color,
  regardless of whether it's the active tab, so a viewer on another tab
  still sees that a tab needs attention.
  """
  attr :tabs, :list, required: true
  attr :active, :atom, required: true
  attr :class, :any, default: nil

  def tab_nav(assigns) do
    ~H"""
    <nav class={["flex gap-5 overflow-hidden border-b border-border", @class]}>
      <.link
        :for={tab <- @tabs}
        id={"task-tab-#{tab.id}"}
        patch={tab.patch}
        class={[
          "-mb-px flex items-center gap-1.5 whitespace-nowrap border-b-2 pb-2.5 text-[13.5px]",
          tab.id == @active && "font-semibold",
          tab.id != @active && "font-medium",
          tab_nav_color(tab, tab.id == @active)
        ]}
      >
        {tab.label}
        <.icon :if={tab[:warn]} name="hero-hand-raised" class="size-3.5 text-warn" />
      </.link>
    </nav>
    """
  end

  defp tab_nav_color(%{warn: true}, true), do: "border-warn text-warn"
  defp tab_nav_color(%{warn: true}, false), do: "border-transparent text-warn"
  defp tab_nav_color(_tab, true), do: "border-accent text-accent"
  defp tab_nav_color(_tab, false), do: "border-transparent text-text2 hover:text-text"

  @doc """
  Renders a kanban column: uppercase header with count, then the card stack.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  slot :inner_block, required: true

  def kanban_column(assigns) do
    ~H"""
    <div id={@id} class="flex min-w-0 flex-col gap-2.5">
      <div class="flex items-center gap-2 px-1">
        <span class="text-[11.5px] font-semibold uppercase tracking-widest text-text2">
          {@title}
        </span>
        <span class="rounded-[7px] bg-surface2 px-1.5 font-mono text-[11px] text-text3">
          {@count}
        </span>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders the task-card shell: title, clamped description, executor pill and
  cost stat, plus a column-specific `footer` slot. The whole card links to
  the task page.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :agent_name, :string, default: nil
  attr :harness, :atom, default: nil
  attr :cost_cents, :integer, default: nil
  attr :tokens, :integer, default: nil
  attr :duration_ms, :integer, default: nil
  attr :cost_mode, :atom, default: :exact
  attr :navigate, :string, required: true
  attr :warn, :boolean, default: false
  attr :muted, :boolean, default: false, doc: "slightly faded, for Done cards"
  slot :footer
  slot :corner, doc: "top-right corner content, e.g. an attention badge"

  def task_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col gap-2 rounded-xl border border-border bg-surface p-3.5 transition-shadow hover:shadow-md",
        @warn && "border-l-[3px] border-l-warn-border",
        @muted && "opacity-90"
      ]}
    >
      <div class="flex items-start gap-2">
        <.link navigate={@navigate} class="min-w-0 flex-1">
          <div class="text-[13.5px] font-semibold leading-snug text-text">{@title}</div>
          <div :if={@description} class="mt-0.5 line-clamp-2 text-xs leading-normal text-text2">
            {@description}
          </div>
        </.link>
        <div :if={@corner != []} class="shrink-0">{render_slot(@corner)}</div>
      </div>
      <div class="flex flex-wrap items-center gap-1.5">
        <.agent_pill :if={@agent_name} name={@agent_name} harness={@harness} />
        <.cost_stat
          cost_cents={@cost_cents}
          tokens={@tokens}
          duration_ms={@duration_ms}
          cost_mode={@cost_mode}
        />
      </div>
      <div :if={@footer != []}>{render_slot(@footer)}</div>
    </div>
    """
  end

  @doc """
  Renders markdown prose. The caller sets the base font size and color on
  `class`; `.md` sizes everything else relative to it.
  """
  attr :text, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def markdown(assigns) do
    ~H"""
    <div class={["md", @class]} {@rest}>{CodeLeadWeb.Markdown.to_html(@text)}</div>
    """
  end

  @doc """
  Renders a chat message bubble for the planning assistant.
  """
  attr :role, :atom, required: true, doc: ":user | :assistant"
  attr :content, :string, required: true
  attr :label, :string, default: nil, doc: "provenance caption, e.g. a repo survey's agent"

  def chat_bubble(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1", @role == :user && "items-end"]}>
      <span
        :if={@label}
        class="text-[10.5px] font-semibold uppercase tracking-wider text-text3"
      >
        {@label}
      </span>
      <div
        class={[
          "max-w-[85%] whitespace-pre-wrap rounded-xl px-3.5 py-2.5 text-[13px] leading-relaxed",
          @role == :user && "bg-accent-soft text-text",
          @role == :assistant && "bg-surface2 text-text"
        ]}
        phx-no-format
      >{@content}</div>
    </div>
    """
  end

  @doc """
  Renders an empty-state hint.
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-2 rounded-xl border border-dashed border-border px-4 py-8 text-center">
      <.icon name={@icon} class="size-6 text-text3" />
      <span class="text-[13px] font-medium text-text2">{@title}</span>
      <span :if={@inner_block != []} class="text-xs text-text3">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc """
  Renders the "schedule this run" dialog.

  The caller owns the events: `schedule_task` on submit, `close_schedule`
  on dismiss. The date/time is picked in the viewer's own timezone (the
  `.SchedulePicker` hook resolves it, same as `.LocalTime` does for
  display) and converted to UTC server-side in `CodeLeadWeb.ScheduleForm`.
  """
  attr :form, :any, required: true
  attr :task_title, :string, required: true

  def schedule_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/45 p-4 pt-[12vh]"
      id="schedule-modal"
      phx-window-keydown="close_schedule"
      phx-key="escape"
    >
      <button
        type="button"
        phx-click="close_schedule"
        class="absolute inset-0 cursor-default"
        aria-label="Close"
      >
        <span class="sr-only">Close</span>
      </button>
      <div class="relative w-full max-w-sm rounded-2xl border border-border bg-surface p-6 shadow-2xl">
        <div class="mb-1 flex items-center justify-between">
          <h2 class="text-[15px] font-bold text-text">Schedule run</h2>
          <button
            type="button"
            phx-click="close_schedule"
            class="flex size-8 cursor-pointer items-center justify-center rounded-lg text-text3 hover:bg-surface2"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <p class="mb-4 truncate text-[12.5px] text-text2">{@task_title}</p>
        <.form for={@form} id="schedule-form" phx-submit="schedule_task">
          <div id="schedule-picker" phx-hook=".SchedulePicker" phx-update="ignore">
            <div class="mb-3 flex gap-1.5">
              <button
                :for={
                  {label, delta} <- [
                    {"+5 min", "5m"},
                    {"+1 h", "1h"},
                    {"+5 h", "5h"},
                    {"+1 day", "1d"}
                  ]
                }
                type="button"
                data-delta={delta}
                class="schedule-pill rounded-full bg-surface2 px-2.5 py-1 text-[11px] font-semibold text-text2 hover:bg-accent-soft hover:text-accent"
              >
                {label}
              </button>
            </div>
            <label class="mb-1 block text-[13px] font-medium text-text2" for="schedule-date">
              Date
            </label>
            <input
              type="date"
              id="schedule-date"
              class="mb-3 w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/40"
            />
            <span class="mb-1 block text-[13px] font-medium text-text2">Time</span>
            <div class="relative flex h-[160px] justify-center gap-2 overflow-hidden rounded-lg border border-border bg-surface">
              <div class="pointer-events-none absolute inset-x-0 top-1/2 h-8 -translate-y-1/2 rounded-md bg-surface2" />
              <ul
                id="schedule-wheel-hour"
                class="schedule-wheel z-10 h-full snap-y snap-mandatory overflow-y-scroll py-[64px] text-center [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
              >
                <li :for={h <- 0..23} data-value={h} class="h-8 w-12 snap-center leading-8 text-text">
                  {String.pad_leading(Integer.to_string(h), 2, "0")}
                </li>
              </ul>
              <span class="z-10 self-center text-text3">:</span>
              <ul
                id="schedule-wheel-minute"
                class="schedule-wheel z-10 h-full snap-y snap-mandatory overflow-y-scroll py-[64px] text-center [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
              >
                <li
                  :for={m <- 0..55//5}
                  data-value={m}
                  class="h-8 w-12 snap-center leading-8 text-text"
                >
                  {String.pad_leading(Integer.to_string(m), 2, "0")}
                </li>
              </ul>
            </div>
            <.input field={@form[:local_at]} type="hidden" />
            <.input field={@form[:utc_offset_minutes]} type="hidden" />
          </div>
          <p class="mt-3 text-[11.5px] text-text3">
            The card moves to Running now and waits there. Budget and capacity
            are checked again when it starts.
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click="close_schedule">Cancel</.button>
            <.button variant="primary" type="submit" phx-disable-with="Scheduling…">
              Schedule
            </.button>
          </div>
        </.form>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".SchedulePicker">
          // Mirrors `.LocalTime`'s trust boundary: no server-side timezone
          // database exists, so the browser resolves the zone and the UTC
          // offset for the picked date via `Intl`; the server (ScheduleForm)
          // does the actual local-to-UTC arithmetic with that offset.
          const ITEM_HEIGHT = 32 // px, matches h-8 on the <li>s

          function effectiveZone() {
            return document.documentElement.dataset.timezone || undefined
          }

          // "Format `ms` as wall-clock in `zone`, treat those numbers as if
          // they were UTC, diff against `ms`" — the standard technique for
          // getting a zone's offset at a specific instant without a tz db.
          function offsetMinutesFor(ms, zone) {
            const dtf = new Intl.DateTimeFormat("en-US", {
              timeZone: zone,
              hourCycle: "h23",
              year: "numeric", month: "2-digit", day: "2-digit",
              hour: "2-digit", minute: "2-digit", second: "2-digit"
            })
            const parts = dtf.formatToParts(new Date(ms)).reduce((acc, p) => {
              acc[p.type] = p.value
              return acc
            }, {})
            const asUTC = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second)
            return Math.round((asUTC - ms) / 60000)
          }

          function partsInZone(ms, zone) {
            const dtf = new Intl.DateTimeFormat("en-US", {
              timeZone: zone, hourCycle: "h23",
              year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit"
            })
            const parts = dtf.formatToParts(new Date(ms)).reduce((acc, p) => {
              acc[p.type] = p.value
              return acc
            }, {})
            return { year: +parts.year, month: +parts.month, day: +parts.day, hour: +parts.hour, minute: +parts.minute }
          }

          function pad(n) { return String(n).padStart(2, "0") }

          export default {
            mounted() {
              this.zone = effectiveZone()
              this.date = this.el.querySelector("#schedule-date")
              this.hourWheel = this.el.querySelector("#schedule-wheel-hour")
              this.minuteWheel = this.el.querySelector("#schedule-wheel-minute")
              this.localAt = this.el.querySelector('input[name="schedule[local_at]"]')
              this.offset = this.el.querySelector('input[name="schedule[utc_offset_minutes]"]')

              this.date.min = partsInZoneDate(this.zone)
              this.date.addEventListener("change", () => this.refresh())
              this.hourWheel.addEventListener("scroll", () => this.onScroll(this.hourWheel))
              this.minuteWheel.addEventListener("scroll", () => this.onScroll(this.minuteWheel))

              this.el.querySelectorAll(".schedule-pill").forEach((pill) => {
                pill.addEventListener("click", () => this.applyInstant(Date.now() + deltaMs(pill.dataset.delta)))
              })

              this.applyInstant(Date.now())

              function partsInZoneDate(zone) {
                const { year, month, day } = partsInZone(Date.now(), zone)
                return `${year}-${pad(month)}-${pad(day)}`
              }

              function deltaMs(code) {
                const n = parseInt(code, 10)
                if (code.endsWith("m")) return n * 60 * 1000
                if (code.endsWith("h")) return n * 60 * 60 * 1000
                return n * 24 * 60 * 60 * 1000
              }
            },
            applyInstant(ms) {
              // Round to the nearest 5-minute step by nudging the real
              // instant, then let `Intl` recompute the calendar fields —
              // that way an hour/day rollover (e.g. 23:58 -> 00:00) is
              // handled correctly instead of clamping minute to 60.
              const remainder = partsInZone(ms, this.zone).minute % 5
              const roundedMs =
                remainder < 3 ? ms - remainder * 60000 : ms + (5 - remainder) * 60000
              const { year, month, day, hour, minute } = partsInZone(roundedMs, this.zone)

              this.date.value = `${year}-${pad(month)}-${pad(day)}`
              this.scrollTo(this.hourWheel, hour)
              this.scrollTo(this.minuteWheel, minute / 5)
              this.refresh()
            },
            scrollTo(wheel, index) {
              wheel.scrollTo({ top: index * ITEM_HEIGHT, behavior: "instant" })
            },
            onScroll(wheel) {
              clearTimeout(wheel._settleTimer)
              wheel._settleTimer = setTimeout(() => this.refresh(), 120)
            },
            centeredValue(wheel) {
              const index = Math.round(wheel.scrollTop / ITEM_HEIGHT)
              const items = wheel.querySelectorAll("li")
              const item = items[Math.max(0, Math.min(index, items.length - 1))]
              return item ? +item.dataset.value : 0
            },
            refresh() {
              const hour = this.centeredValue(this.hourWheel)
              const minute = this.centeredValue(this.minuteWheel)
              const localAt = `${this.date.value}T${pad(hour)}:${pad(minute)}`
              const guessMs = new Date(`${localAt}:00Z`).getTime()

              this.localAt.value = localAt
              this.offset.value = offsetMinutesFor(guessMs, this.zone)
            }
          }
        </script>
      </div>
    </div>
    """
  end

  @doc """
  Renders the mobile floating action button.
  """
  attr :patch, :string, default: nil
  attr :navigate, :string, default: nil
  attr :label, :string, required: true

  def fab(assigns) do
    ~H"""
    <.link
      patch={@patch}
      navigate={@navigate}
      class="fixed bottom-5 right-5 z-30 flex size-[54px] items-center justify-center rounded-[18px] bg-accent text-white shadow-xl lg:hidden"
      aria-label={@label}
    >
      <.icon name="hero-plus" class="size-5" />
    </.link>
    """
  end
end

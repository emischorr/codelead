defmodule CodeLeadWeb.UIComponents do
  @moduledoc """
  CodeLead's design-language components: badges, pills, cards, kanban
  building blocks, and the task-card shell. All styling is built on the
  design tokens defined in `assets/css/app.css`.

  Components take precomputed scalars and flags; callers resolve domain
  lookups (agent names, costs, verdict summaries) before rendering.
  """
  use Phoenix.Component

  import CodeLeadWeb.CoreComponents, only: [icon: 1]

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
  Renders the mono cost/token stat, e.g. `$2.07 · 183.5k`.
  """
  attr :cost_cents, :integer, default: nil
  attr :tokens, :integer, default: nil
  attr :class, :any, default: nil

  def cost_stat(assigns) do
    ~H"""
    <span class={["font-mono text-[11px] text-text3", @class]}>
      {Format.cost_tokens(@cost_cents, @tokens)}
    </span>
    """
  end

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
  Renders one audit-trail entry with the HUMAN/AGENT/SYSTEM chip.
  """
  attr :executor_type, :atom, required: true, doc: ":human | :agent | :system"
  attr :summary, :string, required: true
  attr :at, :any, default: nil

  def timeline_entry(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <span class={[
        "w-[58px] shrink-0 rounded-md py-0.5 text-center text-[10px] font-bold tracking-wide",
        executor_chip(@executor_type)
      ]}>
        {@executor_type |> Atom.to_string() |> String.upcase()}
      </span>
      <span class="min-w-0 flex-1 break-words text-[13px] text-text">{@summary}</span>
      <span class="shrink-0 font-mono text-[11px] text-text3">{Format.relative(@at)}</span>
    </div>
    """
  end

  defp executor_chip(:human), do: "bg-surface2 text-text2"
  defp executor_chip(:agent), do: "bg-accent-soft text-accent"
  defp executor_chip(:system), do: "bg-run-soft text-run"

  @doc """
  Renders the underline tab navigation.

  Tabs are maps: `%{id: :task, label: "Task", patch: ~p"..."}`.
  """
  attr :tabs, :list, required: true
  attr :active, :atom, required: true
  attr :class, :any, default: nil

  def tab_nav(assigns) do
    ~H"""
    <nav class={["flex gap-5 overflow-x-auto border-b border-border", @class]}>
      <.link
        :for={tab <- @tabs}
        patch={tab.patch}
        class={[
          "whitespace-nowrap pb-2.5 text-[13.5px]",
          tab.id == @active && "-mb-px border-b-2 border-accent font-semibold text-accent",
          tab.id != @active && "font-medium text-text2 hover:text-text"
        ]}
      >
        {tab.label}
      </.link>
    </nav>
    """
  end

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
        <.cost_stat cost_cents={@cost_cents} tokens={@tokens} />
      </div>
      <div :if={@footer != []}>{render_slot(@footer)}</div>
    </div>
    """
  end

  @doc """
  Renders a chat message bubble for the planning assistant.
  """
  attr :role, :atom, required: true, doc: ":user | :assistant"
  attr :content, :string, required: true

  def chat_bubble(assigns) do
    ~H"""
    <div class={["flex", @role == :user && "justify-end"]}>
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

defmodule CodeLeadWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CodeLeadWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: project sidebar (full or icon rail on desktop,
  overlay drawer on mobile) plus the main content area.

  Pages render their own header row inside the content area and open the
  mobile drawer with `<.sidebar_toggle />`.

  ## Examples

      <Layouts.app flash={@flash} project={@project} projects={@projects}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :project, :map, default: nil, doc: "the current project"
  attr :projects, :list, default: [], doc: "all projects, for the switcher"
  attr :attention_count, :integer, default: 0
  attr :project_spend, :map, default: nil, doc: "%{cost_cents: _, tokens: _} for the budget card"
  attr :budget_limit_cents, :integer, default: nil
  attr :sidebar, :atom, default: :full, values: [:full, :rail]

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-bg">
      <aside
        :if={@sidebar == :full}
        class="hidden w-[232px] shrink-0 flex-col gap-1.5 border-r border-border bg-surface px-3.5 py-4 lg:flex"
      >
        <.sidebar_content
          project={@project}
          projects={@projects}
          attention_count={@attention_count}
          project_spend={@project_spend}
          budget_limit_cents={@budget_limit_cents}
        />
      </aside>

      <aside
        :if={@sidebar == :rail}
        class="hidden w-16 shrink-0 flex-col items-center gap-3.5 border-r border-border bg-surface py-4 lg:flex"
      >
        <.sidebar_rail project={@project} attention_count={@attention_count} />
      </aside>

      <div id="mobile-drawer" class="fixed inset-0 z-40 hidden lg:hidden">
        <div class="absolute inset-0 bg-black/45" phx-click={hide_drawer()} aria-hidden="true" />
        <div class="absolute inset-y-0 left-0 flex w-[300px] flex-col gap-1.5 border-r border-border bg-surface px-3.5 py-4 shadow-2xl">
          <.sidebar_content
            project={@project}
            projects={@projects}
            attention_count={@attention_count}
            project_spend={@project_spend}
            budget_limit_cents={@budget_limit_cents}
            closable
          />
        </div>
      </div>

      <main class="flex min-w-0 flex-1 flex-col">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Hamburger button that opens the mobile sidebar drawer. Render it in
  page headers with `lg:hidden`.
  """
  attr :class, :any, default: nil

  def sidebar_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "inline-flex size-[34px] cursor-pointer items-center justify-center rounded-[9px]",
        "border border-border bg-surface text-text2 lg:hidden",
        @class
      ]}
      phx-click={show_drawer()}
      aria-label="Open navigation"
    >
      <.icon name="hero-bars-3" class="size-4" />
    </button>
    """
  end

  attr :project, :map, default: nil
  attr :projects, :list, default: []
  attr :attention_count, :integer, default: 0
  attr :project_spend, :map, default: nil
  attr :budget_limit_cents, :integer, default: nil
  attr :closable, :boolean, default: false

  defp sidebar_content(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5 px-1.5 pb-3">
      <.logo_glyph />
      <span class="text-[15px] font-bold tracking-tight text-text">CodeLead</span>
      <button
        :if={@closable}
        type="button"
        class="ml-auto inline-flex size-[30px] cursor-pointer items-center justify-center rounded-lg text-text3"
        phx-click={hide_drawer()}
        aria-label="Close navigation"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>

    <.project_switcher :if={@project} project={@project} projects={@projects} />

    <div class="h-2.5" />

    <.link
      :if={@project}
      navigate={~p"/projects/#{@project.id}/board"}
      class="flex items-center gap-2.5 rounded-[10px] bg-accent-soft px-2.5 py-2 text-[13.5px] font-semibold text-accent"
    >
      <.icon name="hero-view-columns" class="size-4" /> Board
    </.link>
    <span
      class="flex cursor-not-allowed items-center gap-2.5 rounded-[10px] px-2.5 py-2 text-[13.5px] font-medium text-text3"
      aria-disabled="true"
      title="Coming soon"
    >
      <.icon name="hero-chart-bar" class="size-4" /> Metrics
    </span>
    <span
      class="flex cursor-not-allowed items-center gap-2.5 rounded-[10px] px-2.5 py-2 text-[13.5px] font-medium text-text3"
      aria-disabled="true"
      title="Coming soon"
    >
      <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
    </span>

    <div class="h-3.5" />

    <.link
      :if={@project && @attention_count > 0}
      navigate={~p"/projects/#{@project.id}/board"}
      class="flex items-center gap-2.5 rounded-[10px] border border-warn-border bg-warn-soft px-2.5 py-2 text-[13px] font-semibold text-warn"
    >
      <span class="size-[7px] animate-pulse rounded-full bg-warn" /> Needs attention
      <span class="ml-auto rounded-[7px] bg-warn px-1.5 font-mono text-xs text-surface">
        {@attention_count}
      </span>
    </.link>

    <div class="flex-1" />

    <.budget_card
      :if={@project_spend}
      project_spend={@project_spend}
      budget_limit_cents={@budget_limit_cents}
    />
    """
  end

  attr :project, :map, default: nil
  attr :attention_count, :integer, default: 0

  defp sidebar_rail(assigns) do
    ~H"""
    <.logo_glyph />
    <div class="h-1.5" />
    <.link
      :if={@project}
      navigate={~p"/projects/#{@project.id}/board"}
      class="flex size-[38px] items-center justify-center rounded-[10px] bg-accent-soft text-accent"
      title="Board"
    >
      <.icon name="hero-view-columns" class="size-4" />
    </.link>
    <span
      class="flex size-[38px] cursor-not-allowed items-center justify-center rounded-[10px] text-text3"
      title="Metrics — coming soon"
    >
      <.icon name="hero-chart-bar" class="size-4" />
    </span>
    <span
      class="flex size-[38px] cursor-not-allowed items-center justify-center rounded-[10px] text-text3"
      title="Settings — coming soon"
    >
      <.icon name="hero-cog-6-tooth" class="size-4" />
    </span>
    <div class="flex-1" />
    <span
      :if={@attention_count > 0}
      class="flex size-[26px] items-center justify-center rounded-full bg-warn-soft font-mono text-[11px] font-semibold text-warn"
      title="Tasks needing attention"
    >
      {@attention_count}
    </span>
    """
  end

  defp logo_glyph(assigns) do
    ~H"""
    <div class="flex size-[26px] shrink-0 items-center justify-center rounded-lg bg-accent">
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
        <rect x="2" y="2" width="4" height="10" rx="1.2" fill="#fff" />
        <rect x="8" y="2" width="4" height="6" rx="1.2" fill="#fff" opacity="0.75" />
      </svg>
    </div>
    """
  end

  attr :project, :map, required: true
  attr :projects, :list, default: []

  defp project_switcher(assigns) do
    ~H"""
    <details class="relative">
      <summary class="flex cursor-pointer list-none items-center gap-2 rounded-[10px] border border-border bg-surface2 px-2.5 py-2 text-[13px] font-semibold text-text [&::-webkit-details-marker]:hidden">
        <span class="size-2 rounded-[3px] bg-accent" />
        <span class="truncate">{@project.name}</span>
        <.icon name="hero-chevron-down" class="ml-auto size-3.5 shrink-0 text-text3" />
      </summary>
      <div class="absolute inset-x-0 top-full z-10 mt-1 overflow-hidden rounded-[10px] border border-border bg-surface shadow-lg">
        <.link
          :for={project <- @projects}
          navigate={~p"/projects/#{project.id}/board"}
          class={[
            "flex items-center gap-2 px-2.5 py-2 text-[13px] hover:bg-surface2",
            project.id == @project.id && "font-semibold text-text",
            project.id != @project.id && "text-text2"
          ]}
        >
          <span class="size-2 rounded-[3px] bg-accent opacity-70" />
          <span class="truncate">{project.name}</span>
        </.link>
      </div>
    </details>
    """
  end

  attr :project_spend, :map, required: true
  attr :budget_limit_cents, :integer, default: nil

  defp budget_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 rounded-xl bg-surface2 p-3">
      <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
        Budget · {Calendar.strftime(Date.utc_today(), "%B")}
      </span>
      <span class="font-mono text-[13px] font-semibold text-text">
        {CodeLeadWeb.Format.cents(@project_spend.cost_cents)}
        <span :if={@budget_limit_cents} class="font-normal text-text3">
          / {CodeLeadWeb.Format.cents(@budget_limit_cents)}
        </span>
      </span>
      <div :if={@budget_limit_cents} class="h-1 rounded-full bg-border">
        <div
          class="h-1 rounded-full bg-accent"
          style={"width: #{budget_percent(@project_spend.cost_cents, @budget_limit_cents)}%"}
        />
      </div>
    </div>
    """
  end

  defp budget_percent(_cost_cents, limit) when limit in [nil, 0], do: 0

  defp budget_percent(cost_cents, limit_cents) do
    min(100, round(cost_cents / limit_cents * 100))
  end

  defp show_drawer(js \\ %JS{}), do: JS.remove_class(js, "hidden", to: "#mobile-drawer")

  defp hide_drawer(js \\ %JS{}), do: JS.add_class(js, "hidden", to: "#mobile-drawer")

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-border bg-surface2">
      <div class="absolute h-full w-1/3 rounded-full border border-border bg-surface transition-[left] left-0 [[data-theme-mode=light]_&]:left-1/3 [[data-theme-mode=dark]_&]:left-2/3" />

      <button
        class="z-10 flex w-1/3 cursor-pointer p-2 text-text2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="z-10 flex w-1/3 cursor-pointer p-2 text-text2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="z-10 flex w-1/3 cursor-pointer p-2 text-text2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end

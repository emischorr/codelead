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

  The sidebar is identical on every authenticated page — it renders entirely
  from the `@nav` map that `CodeLeadWeb.NavContext` assigns, so pages never
  assemble the navigation themselves. Pages render their own header row inside
  the content area and open the mobile drawer with `<.sidebar_toggle />`.

  ## Examples

      <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :nav, :map,
    required: true,
    doc: "the navigation state assigned by `CodeLeadWeb.NavContext`"

  attr :sidebar, :atom, default: :full, values: [:full, :rail]
  attr :current_scope, :any, default: nil, doc: "the signed-in scope, when there is one"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-bg">
      <aside
        :if={@sidebar == :full}
        class="hidden w-[232px] shrink-0 flex-col gap-1.5 border-r border-border bg-surface px-3.5 py-4 lg:flex"
      >
        <.sidebar_content nav={@nav} current_scope={@current_scope} />
      </aside>

      <aside
        :if={@sidebar == :rail}
        class="hidden w-16 shrink-0 flex-col items-center gap-3.5 border-r border-border bg-surface py-4 lg:flex"
      >
        <.sidebar_rail nav={@nav} current_scope={@current_scope} />
      </aside>

      <div id="mobile-drawer" class="fixed inset-0 z-40 hidden lg:hidden">
        <div class="absolute inset-0 bg-black/45" phx-click={hide_drawer()} aria-hidden="true" />
        <div class="absolute inset-y-0 left-0 flex w-[300px] flex-col gap-1.5 border-r border-border bg-surface px-3.5 py-4 shadow-2xl">
          <.sidebar_content nav={@nav} current_scope={@current_scope} closable />
        </div>
      </div>

      <.project_store project={@nav.project} />

      <main class="flex min-w-0 flex-1 flex-col">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  # The browser remembers which project you were last in, so the deactivated
  # selector on general pages can still name it. Rendered once per page — the
  # three sidebar copies must not each push.
  attr :project, :map, default: nil

  defp project_store(assigns) do
    ~H"""
    <div
      id="nav-project-store"
      phx-hook=".NavProject"
      data-project-id={@project && @project.id}
      hidden
    />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NavProject">
      export default {
        mounted() { this.sync() },
        updated() { this.sync() },
        sync() {
          const id = this.el.dataset.projectId
          if (id) {
            window.localStorage.setItem("cl:project", id)
          } else if (!this.restored) {
            this.restored = true
            this.pushEvent("nav:restore_project", {id: window.localStorage.getItem("cl:project")})
          }
        }
      }
    </script>
    """
  end

  @doc """
  Renders the chromeless layout used before a user has a project to look at:
  the first-run wizard and the authentication pages. Wordmark, theme toggle,
  and a centered column — no project sidebar.

  ## Examples

      <Layouts.auth flash={@flash} width="max-w-md">
        <div class="rounded-2xl border border-border bg-surface p-6">…</div>
      </Layouts.auth>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :width, :string, default: "max-w-md", doc: "max width of the centered column"

  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-desk">
      <header class="flex h-[58px] shrink-0 items-center gap-2.5 px-4 sm:px-5">
        <.logo_glyph />
        <span class="text-[15px] font-bold tracking-tight text-text">CodeLead</span>
        <div class="flex-1" />
        <.theme_toggle />
      </header>

      <main class="flex flex-1 justify-center px-4 pb-16 pt-[4vh] sm:pt-[7vh]">
        <div class={["w-full", @width]}>{render_slot(@inner_block)}</div>
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

  attr :nav, :map, required: true
  attr :current_scope, :any, default: nil
  attr :closable, :boolean, default: false

  defp sidebar_content(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5 px-1.5 pb-3">
      <.link navigate={~p"/"} class="flex items-center gap-2.5" title="CodeLead">
        <.logo_glyph />
        <span class="text-[15px] font-bold tracking-tight text-text">CodeLead</span>
      </.link>
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

    <.project_switcher id={nav_id(@closable, "project-switcher")} nav={@nav} />

    <div class="h-2.5" />

    <.link
      id={nav_id(@closable, "nav-dashboard")}
      navigate={~p"/"}
      class={nav_class(@nav.current == :dashboard)}
    >
      <.icon name="hero-squares-2x2" class="size-4" /> Dashboard
    </.link>
    <.link
      :if={@nav.project}
      id={nav_id(@closable, "nav-board")}
      navigate={~p"/projects/#{@nav.project.id}/board"}
      class={nav_class(@nav.current == :board)}
    >
      <.icon name="hero-view-columns" class="size-4" /> Board
    </.link>
    <span
      :if={is_nil(@nav.project)}
      id={nav_id(@closable, "nav-board")}
      class={nav_class(:disabled)}
      aria-disabled="true"
      title="No project yet"
    >
      <.icon name="hero-view-columns" class="size-4" /> Board
    </span>
    <span class={nav_class(:disabled)} aria-disabled="true" title="Coming soon">
      <.icon name="hero-chart-bar" class="size-4" /> Metrics
    </span>
    <.link
      id={nav_id(@closable, "nav-settings")}
      navigate={~p"/settings"}
      class={nav_class(@nav.current == :settings)}
    >
      <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
    </.link>

    <div class="h-3.5" />

    <.link
      :if={@nav.project && @nav.attention_count > 0}
      id={nav_id(@closable, "attention-pill")}
      navigate={~p"/projects/#{@nav.project.id}/board"}
      class="flex items-center gap-2.5 rounded-[10px] border border-warn-border bg-warn-soft px-2.5 py-2 text-[13px] font-semibold text-warn"
    >
      <span class="size-[7px] animate-pulse rounded-full bg-warn" /> Needs attention
      <span class="ml-auto rounded-[7px] bg-warn px-1.5 font-mono text-xs text-surface">
        {@nav.attention_count}
      </span>
    </.link>

    <div class="flex-1" />

    <.budget_card
      :if={@nav.spend}
      id={nav_id(@closable, "budget-card")}
      spend={@nav.spend}
      budget_limit_cents={@nav.project && @nav.project.budget_limit_cents}
    />

    <.account_card
      :if={@current_scope && @current_scope.user}
      id={nav_id(@closable, "account-card")}
      user={@current_scope.user}
    />
    """
  end

  # The drawer renders a second copy of the sidebar; its ids carry an `m-`
  # prefix so both can be addressed.
  defp nav_id(true, name), do: "m-" <> name
  defp nav_id(false, name), do: name

  @doc """
  Signed-in identity, the theme switch, and the account actions. Rendered in
  the sidebar and on the welcome page — every authenticated surface needs a
  way out. Pass `theme_toggle={false}` where the surrounding shell already
  offers one; the row then spells the email out instead.
  """
  attr :id, :string, default: "account-card"
  attr :user, :map, required: true
  attr :theme_toggle, :boolean, default: true

  def account_card(assigns) do
    ~H"""
    <div id={@id} class="mt-2.5 flex items-center gap-2 border-t border-border pt-2.5">
      <span
        class="flex size-[26px] shrink-0 items-center justify-center rounded-full bg-surface2 font-mono text-[11px] font-semibold uppercase text-text2"
        title={@user.email}
      >
        {String.first(@user.email)}
      </span>
      <.theme_toggle :if={@theme_toggle} class="mr-auto" />
      <span :if={!@theme_toggle} class="min-w-0 flex-1 truncate text-[12.5px] text-text2">
        {@user.email}
      </span>
      <.link
        id={"#{@id}-settings"}
        navigate={~p"/users/settings"}
        class="inline-flex size-[26px] items-center justify-center rounded-lg text-text3 hover:bg-surface2 hover:text-text2"
        title="Your account"
      >
        <.icon name="hero-cog-6-tooth" class="size-4" />
      </.link>
      <.link
        id={"#{@id}-log-out"}
        href={~p"/users/log-out"}
        method="delete"
        class="inline-flex size-[26px] items-center justify-center rounded-lg text-text3 hover:bg-surface2 hover:text-text2"
        title="Log out"
      >
        <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
      </.link>
    </div>
    """
  end

  attr :nav, :map, required: true
  attr :current_scope, :any, default: nil

  # Item-for-item the same navigation as `sidebar_content/1`, collapsed to
  # glyphs: project · Dashboard · Board · Metrics · Settings · attention ·
  # account.
  defp sidebar_rail(assigns) do
    ~H"""
    <.link navigate={~p"/"} title="CodeLead">
      <.logo_glyph />
    </.link>
    <div class="h-1.5" />
    <.link
      :if={@nav.project && @nav.scope == :project}
      id="rail-project"
      navigate={~p"/projects/#{@nav.project.id}/board"}
      class="flex size-[26px] items-center justify-center rounded-[7px] bg-accent font-mono text-[11px] font-semibold uppercase text-surface"
      title={@nav.project.name}
    >
      {String.first(@nav.project.name)}
    </.link>
    <span
      :if={!(@nav.project && @nav.scope == :project)}
      id="rail-project"
      class="flex size-[26px] cursor-not-allowed items-center justify-center rounded-[7px] border border-dashed border-border font-mono text-[11px] font-semibold uppercase text-text3"
      aria-disabled="true"
      title={(@nav.project && @nav.project.name) || "No project"}
    >
      {(@nav.project && String.first(@nav.project.name)) || "—"}
    </span>
    <div class="h-1.5" />
    <.link
      id="rail-dashboard"
      navigate={~p"/"}
      class={rail_class(@nav.current == :dashboard)}
      title="Dashboard"
    >
      <.icon name="hero-squares-2x2" class="size-4" />
    </.link>
    <.link
      :if={@nav.project}
      id="rail-board"
      navigate={~p"/projects/#{@nav.project.id}/board"}
      class={rail_class(@nav.current == :board)}
      title="Board"
    >
      <.icon name="hero-view-columns" class="size-4" />
    </.link>
    <span
      :if={is_nil(@nav.project)}
      id="rail-board"
      class={rail_class(:disabled)}
      aria-disabled="true"
      title="Board — no project yet"
    >
      <.icon name="hero-view-columns" class="size-4" />
    </span>
    <span class={rail_class(:disabled)} aria-disabled="true" title="Metrics — coming soon">
      <.icon name="hero-chart-bar" class="size-4" />
    </span>
    <.link
      id="rail-settings"
      navigate={~p"/settings"}
      class={rail_class(@nav.current == :settings)}
      title="Settings"
    >
      <.icon name="hero-cog-6-tooth" class="size-4" />
    </.link>
    <div class="flex-1" />
    <span
      :if={@nav.project && @nav.attention_count > 0}
      id="rail-attention"
      class="flex size-[26px] items-center justify-center rounded-full bg-warn-soft font-mono text-[11px] font-semibold text-warn"
      title="Tasks needing attention"
    >
      {@nav.attention_count}
    </span>
    <.link
      :if={@current_scope && @current_scope.user}
      navigate={~p"/users/settings"}
      class="mt-2.5 flex size-[26px] items-center justify-center rounded-full bg-surface2 font-mono text-[11px] font-semibold uppercase text-text2"
      title={@current_scope.user.email}
    >
      {String.first(@current_scope.user.email)}
    </.link>
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

  attr :id, :string, required: true
  attr :nav, :map, required: true

  # Switching projects only makes sense from a project page, so on general
  # pages the box keeps its place — naming the project you came from — but
  # stops being a disclosure.
  defp project_switcher(%{nav: %{scope: :project, project: %{}}} = assigns) do
    ~H"""
    <details id={@id} class="relative">
      <summary class="flex cursor-pointer list-none items-center gap-2 rounded-[10px] border border-border bg-surface2 px-2.5 py-2 text-[13px] font-semibold text-text [&::-webkit-details-marker]:hidden">
        <span class="size-2 rounded-[3px] bg-accent" />
        <span class="truncate">{@nav.project.name}</span>
        <.icon name="hero-chevron-down" class="ml-auto size-3.5 shrink-0 text-text3" />
      </summary>
      <div class="absolute inset-x-0 top-full z-10 mt-1 overflow-hidden rounded-[10px] border border-border bg-surface shadow-lg">
        <.link
          :for={project <- @nav.projects}
          navigate={~p"/projects/#{project.id}/board"}
          class={[
            "flex items-center gap-2 px-2.5 py-2 text-[13px] hover:bg-surface2",
            project.id == @nav.project.id && "font-semibold text-text",
            project.id != @nav.project.id && "text-text2"
          ]}
        >
          <span class="size-2 rounded-[3px] bg-accent opacity-70" />
          <span class="truncate">{project.name}</span>
        </.link>
      </div>
    </details>
    """
  end

  defp project_switcher(assigns) do
    ~H"""
    <div
      id={@id}
      aria-disabled="true"
      title={
        (@nav.project && "#{@nav.project.name} — switch projects from the board") ||
          "No project yet"
      }
      class="flex cursor-not-allowed items-center gap-2 rounded-[10px] border border-border bg-surface2 px-2.5 py-2 text-[13px] font-semibold opacity-60"
    >
      <span class={["size-2 rounded-[3px]", (@nav.project && "bg-accent") || "bg-border"]} />
      <span class={["truncate", (@nav.project && "text-text") || "text-text3"]}>
        {(@nav.project && @nav.project.name) || "No project"}
      </span>
      <.icon name="hero-chevron-down" class="ml-auto size-3.5 shrink-0 text-text3" />
    </div>
    """
  end

  # `spend` is month-to-date (`Costs.project_spend_month/1`) because the
  # limit it is measured against runs on the calendar month too — the
  # headline names that month.
  attr :id, :string, required: true
  attr :spend, :map, required: true
  attr :budget_limit_cents, :integer, default: nil

  defp budget_card(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-1.5 rounded-xl bg-surface2 p-3">
      <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
        Budget · {Calendar.strftime(Date.utc_today(), "%B")}
      </span>
      <span class="font-mono text-[13px] font-semibold text-text">
        {CodeLeadWeb.Format.cents(@spend.cost_cents)}
        <span :if={@budget_limit_cents} class="font-normal text-text3">
          / {CodeLeadWeb.Format.cents(@budget_limit_cents)}
        </span>
      </span>
      <.meter value={@spend.cost_cents} max={@budget_limit_cents} />
    </div>
    """
  end

  defp nav_class(true),
    do:
      "flex items-center gap-2.5 rounded-[10px] bg-accent-soft px-2.5 py-2 text-[13.5px] font-semibold text-accent"

  defp nav_class(false),
    do:
      "flex items-center gap-2.5 rounded-[10px] px-2.5 py-2 text-[13.5px] font-medium text-text2 hover:bg-surface2 hover:text-text"

  defp nav_class(:disabled),
    do:
      "flex cursor-not-allowed items-center gap-2.5 rounded-[10px] px-2.5 py-2 text-[13.5px] font-medium text-text3"

  defp rail_class(true),
    do: "flex size-[38px] items-center justify-center rounded-[10px] bg-accent-soft text-accent"

  defp rail_class(false),
    do:
      "flex size-[38px] items-center justify-center rounded-[10px] text-text3 hover:bg-surface2 hover:text-text2"

  defp rail_class(:disabled),
    do:
      "flex size-[38px] cursor-not-allowed items-center justify-center rounded-[10px] text-text3"

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
  attr :class, :any, default: nil

  def theme_toggle(assigns) do
    ~H"""
    <div class={[
      "relative flex flex-row items-center rounded-full border border-border bg-surface2",
      @class
    ]}>
      <div class="absolute h-full w-1/3 rounded-full border border-border bg-surface transition-[left] left-0 [[data-theme-mode=light]_&]:left-1/3 [[data-theme-mode=dark]_&]:left-2/3" />

      <button
        class="z-10 flex w-1/3 cursor-pointer justify-center p-1.5 text-text2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="z-10 flex w-1/3 cursor-pointer justify-center p-1.5 text-text2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="z-10 flex w-1/3 cursor-pointer justify-center p-1.5 text-text2"
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

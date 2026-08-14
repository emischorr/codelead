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

  # Every navigation row is the same box in both widths: a label row when
  # expanded, the rail's 38px square when collapsed. Kept as one literal so the
  # `collapsed:` candidates stay greppable for Tailwind's source scanner.
  @nav_row "flex items-center gap-2.5 overflow-hidden whitespace-nowrap rounded-[10px] px-2.5 py-2 " <>
             "text-[13.5px] collapsed:size-[38px] collapsed:justify-center collapsed:gap-0 collapsed:p-0"

  @doc """
  Renders the app layout: project sidebar (expanded or collapsed to a glyph rail
  on desktop, overlay drawer on mobile) plus the main content area.

  The sidebar is identical on every authenticated page — it renders entirely
  from the `@nav` map that `CodeLeadWeb.NavContext` assigns, so pages never
  assemble the navigation themselves. Pages render their own header row inside
  the content area and open the mobile drawer with `<.sidebar_toggle />`.

  Width is the user's choice, remembered in `localStorage["cl:nav"]` and applied
  as CSS through the `collapsed` variant — the server never learns it. A page
  that needs a particular width passes `sidebar={:open}` or `sidebar={:closed}`,
  which wins over the preference and hides the toggle.

  ## Examples

      <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>

      <Layouts.app flash={@flash} nav={@nav} current_scope={@current_scope} sidebar={:closed}>
        <h1>Content that wants the width</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :nav, :map,
    required: true,
    doc: "the navigation state assigned by `CodeLeadWeb.NavContext`"

  attr :sidebar, :atom,
    default: :user,
    values: [:user, :open, :closed],
    doc: "`:user` follows the remembered preference; `:open`/`:closed` override it"

  attr :current_scope, :any, default: nil, doc: "the signed-in scope, when there is one"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!-- The shell owns the viewport height: `h-dvh` + `overflow-hidden` means
          the window never scrolls, so every page under this layout must put its
          content in a `min-h-0 flex-1 overflow-y-auto` pane of its own. --%>
    <div class="flex h-dvh overflow-hidden bg-bg">
      <%!-- The aside itself stays `overflow: visible` — the project switcher's
            flyout has to escape the 232px/64px column. The scroll region lives
            *inside* it instead, around the nav links (see `sidebar_content`). --%>
      <aside
        id="sidebar"
        data-sidebar={sidebar_mode(@sidebar)}
        class={[
          "hidden w-[232px] shrink-0 flex-col gap-1.5 border-r border-border bg-surface px-3.5 py-4 lg:flex",
          "transition-[width] duration-200 ease-out motion-reduce:transition-none",
          "collapsed:w-16 collapsed:items-center collapsed:gap-2 collapsed:px-2"
        ]}
      >
        <.sidebar_content
          nav={@nav}
          current_scope={@current_scope}
          collapsible={@sidebar == :user}
        />
      </aside>

      <%!-- The drawer is a sibling of the aside and carries neither state
            attribute, so no branch of the `collapsed` variant reaches it: it is
            always the expanded sidebar, whatever the desktop width is. --%>
      <div id="mobile-drawer" class="fixed inset-0 z-40 hidden lg:hidden">
        <div class="absolute inset-0 bg-black/45" phx-click={hide_drawer()} aria-hidden="true" />
        <div class="absolute inset-y-0 left-0 flex w-[300px] flex-col gap-1.5 border-r border-border bg-surface px-3.5 py-4 shadow-2xl">
          <.sidebar_content nav={@nav} current_scope={@current_scope} closable />
        </div>
      </div>

      <.project_store project={@nav.project} />

      <main class="flex min-w-0 flex-1 flex-col overflow-hidden">
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
        // A reconnect (e.g. the browser tab was backgrounded and the socket
        // dropped) joins a brand-new LiveView process, so the server forgets
        // the restored project even though this DOM node — and its
        // `this.restored` flag — survives the reconnect untouched. Without
        // resetting it here, `sync()` would see `this.restored` still true
        // and never re-push, leaving the project stuck at nil.
        disconnected() { this.restored = false },
        reconnected() { this.sync() },
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
  attr :collapsible, :boolean, default: false

  defp sidebar_content(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center gap-2.5 overflow-hidden px-1.5 pb-3 collapsed:flex-col collapsed:gap-1.5 collapsed:px-0 collapsed:pb-2">
      <.link navigate={~p"/"} class="flex items-center gap-2.5" title="CodeLead" aria-label="CodeLead">
        <.logo_glyph />
        <span class="whitespace-nowrap text-[15px] font-bold tracking-tight text-text collapsed:hidden">
          CodeLead
        </span>
      </.link>
      <%!-- The drawer closes, the desktop sidebar collapses. Never both, which
            is what keeps `#sidebar-collapse` a unique id for its hook. --%>
      <button
        :if={@closable}
        type="button"
        class="ml-auto inline-flex size-[30px] cursor-pointer items-center justify-center rounded-lg text-text3"
        phx-click={hide_drawer()}
        aria-label="Close navigation"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
      <.sidebar_collapse_button :if={!@closable && @collapsible} />
    </div>

    <.project_switcher id={nav_id(@closable, "project-switcher")} nav={@nav} />

    <div class="h-2.5 shrink-0 collapsed:h-1.5" />

    <%!-- The links are the only part of the sidebar allowed to scroll: it is a
          flex-1 region, so it doubles as the spring that pins the budget and
          account cards to the bottom of the viewport-height aside. --%>
    <div class="flex min-h-0 flex-1 flex-col gap-1.5 overflow-y-auto collapsed:items-center">
      <.link
        id={nav_id(@closable, "nav-dashboard")}
        navigate={~p"/"}
        class={nav_class(@nav.current == :dashboard)}
        title="Dashboard"
        aria-label="Dashboard"
      >
        <.icon name="hero-squares-2x2" class="size-4 shrink-0" />
        <span class="collapsed:hidden">Dashboard</span>
      </.link>
      <.link
        :if={@nav.project}
        id={nav_id(@closable, "nav-board")}
        navigate={~p"/projects/#{@nav.project.id}/board"}
        class={nav_class(@nav.current == :board)}
        title="Board"
        aria-label="Board"
      >
        <.icon name="hero-view-columns" class="size-4 shrink-0" />
        <span class="collapsed:hidden">Board</span>
      </.link>
      <span
        :if={is_nil(@nav.project)}
        id={nav_id(@closable, "nav-board")}
        class={nav_class(:disabled)}
        aria-disabled="true"
        title="Board — no project yet"
        aria-label="Board"
      >
        <.icon name="hero-view-columns" class="size-4 shrink-0" />
        <span class="collapsed:hidden">Board</span>
      </span>
      <span
        class={nav_class(:disabled)}
        aria-disabled="true"
        title="Metrics — coming soon"
        aria-label="Metrics"
      >
        <.icon name="hero-chart-bar" class="size-4 shrink-0" />
        <span class="collapsed:hidden">Metrics</span>
      </span>
      <.link
        id={nav_id(@closable, "nav-settings")}
        navigate={~p"/settings"}
        class={nav_class(@nav.current == :settings)}
        title="Settings"
        aria-label="Settings"
      >
        <.icon name="hero-cog-6-tooth" class="size-4 shrink-0" />
        <span class="collapsed:hidden">Settings</span>
      </.link>

      <div class="h-3.5 collapsed:h-2" />

      <.link
        :if={@nav.project && @nav.attention_count > 0}
        id={nav_id(@closable, "attention-pill")}
        navigate={~p"/projects/#{@nav.project.id}/board"}
        title="Tasks needing attention"
        aria-label="Tasks needing attention"
        class="flex items-center gap-2.5 overflow-hidden whitespace-nowrap rounded-[10px] border border-warn-border bg-warn-soft px-2.5 py-2 text-[13px] font-semibold text-warn collapsed:size-[38px] collapsed:justify-center collapsed:gap-0 collapsed:rounded-full collapsed:border-0 collapsed:bg-transparent collapsed:p-0"
      >
        <span class="size-[7px] shrink-0 animate-pulse rounded-full bg-warn collapsed:hidden" />
        <span class="collapsed:hidden">Needs attention</span>
        <span class="ml-auto rounded-[7px] bg-warn px-1.5 font-mono text-xs text-surface collapsed:ml-0 collapsed:flex collapsed:size-[26px] collapsed:items-center collapsed:justify-center collapsed:rounded-full collapsed:bg-warn-soft collapsed:px-0 collapsed:text-warn">
          {@nav.attention_count}
        </span>
      </.link>
    </div>

    <.rate_limit_card
      :if={@nav.rate_limit}
      id={nav_id(@closable, "rate-limit-card")}
      usage={@nav.rate_limit}
    />

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

  defp sidebar_mode(:user), do: "user"
  defp sidebar_mode(:open), do: "open"
  defp sidebar_mode(:closed), do: "closed"

  # Width is a client-side preference, so the button drives CSS rather than an
  # assign: a plain click listener (not `phx-click`, which needs a connected
  # socket) flips `localStorage["cl:nav"]` and `<html data-nav>`. `aria-expanded`
  # is set by the hook and re-set in `updated()`, because the aside lives inside
  # the LiveView-managed tree and morphdom would otherwise patch it back.
  defp sidebar_collapse_button(assigns) do
    ~H"""
    <button
      id="sidebar-collapse"
      type="button"
      phx-hook=".NavCollapse"
      aria-controls="sidebar"
      class="ml-auto inline-flex size-[30px] shrink-0 cursor-pointer items-center justify-center rounded-lg text-text3 hover:bg-surface2 hover:text-text2 collapsed:ml-0"
    >
      <.icon name="hero-chevron-double-left" class="size-4 collapsed:hidden" />
      <.icon name="hero-chevron-double-right" class="hidden size-4 collapsed:block" />
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NavCollapse">
      export default {
        mounted() {
          this.onClick = () => this.set(this.collapsed() ? "expanded" : "collapsed")
          this.onKey = (e) => {
            if (e.key === "b" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault()
              this.onClick()
            }
          }
          this.onStorage = (e) => {
            if (e.key === "cl:nav") { this.apply(e.newValue); this.sync() }
          }
          this.el.addEventListener("click", this.onClick)
          window.addEventListener("keydown", this.onKey)
          window.addEventListener("storage", this.onStorage)
          this.sync()
        },
        updated() { this.sync() },
        destroyed() {
          this.el.removeEventListener("click", this.onClick)
          window.removeEventListener("keydown", this.onKey)
          window.removeEventListener("storage", this.onStorage)
        },
        collapsed() { return document.documentElement.dataset.nav === "collapsed" },
        apply(value) {
          document.documentElement.dataset.nav = value === "collapsed" ? "collapsed" : "expanded"
        },
        set(value) {
          window.localStorage.setItem("cl:nav", value)
          this.apply(value)
          this.sync()
        },
        sync() {
          const open = !this.collapsed()
          this.el.setAttribute("aria-expanded", String(open))
          this.el.setAttribute("aria-label", open ? "Collapse sidebar" : "Expand sidebar")
        }
      }
    </script>
    """
  end

  @doc """
  Signed-in identity, the theme switch, and the account actions. Rendered in
  the sidebar and on the welcome page — every authenticated surface needs a
  way out. Pass `theme_toggle={false}` where the surrounding shell already
  offers one; the row then spells the email out instead.

  Collapsed it becomes the avatar over the log-out button. The theme switch is
  dropped: a three-segment control does not survive 48px, and theme is a
  set-and-forget preference reachable from every expanded page. The `collapsed:`
  classes are inert under `Layouts.auth`, which has no sidebar for the variant
  to match against.
  """
  attr :id, :string, default: "account-card"
  attr :user, :map, required: true
  attr :theme_toggle, :boolean, default: true

  def account_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="mt-2.5 flex shrink-0 items-center gap-2 border-t border-border pt-2.5 collapsed:mt-2 collapsed:flex-col collapsed:gap-1.5 collapsed:border-t-0 collapsed:pt-2"
    >
      <.link
        id={"#{@id}-avatar"}
        navigate={~p"/users/settings"}
        class="flex size-[26px] shrink-0 items-center justify-center rounded-full bg-surface2 font-mono text-[11px] font-semibold uppercase text-text2"
        title={@user.email}
        aria-label={"Your account (#{@user.email})"}
      >
        {String.first(@user.email)}
      </.link>
      <.theme_toggle :if={@theme_toggle} class="mr-auto collapsed:hidden" />
      <span
        :if={!@theme_toggle}
        class="min-w-0 flex-1 truncate text-[12.5px] text-text2 collapsed:hidden"
      >
        {@user.email}
      </span>
      <.link
        id={"#{@id}-settings"}
        navigate={~p"/users/settings"}
        class="inline-flex size-[26px] items-center justify-center rounded-lg text-text3 hover:bg-surface2 hover:text-text2 collapsed:hidden"
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
  # stops being a disclosure. Collapsed, the box becomes the project initial and
  # the panel re-anchors as a right-hand flyout: a 64px-wide list of truncated
  # project names would be useless.
  defp project_switcher(%{nav: %{scope: :project, project: %{}}} = assigns) do
    ~H"""
    <details id={@id} class="relative shrink-0">
      <summary
        title={@nav.project.name}
        class="flex cursor-pointer list-none items-center gap-2 overflow-hidden rounded-[10px] border border-border bg-surface2 px-2.5 py-2 text-[13px] font-semibold text-text [&::-webkit-details-marker]:hidden collapsed:size-[38px] collapsed:justify-center collapsed:gap-0 collapsed:overflow-visible collapsed:border-0 collapsed:bg-transparent collapsed:p-0"
      >
        <span class="size-2 shrink-0 rounded-[3px] bg-accent collapsed:hidden" />
        <span class="truncate collapsed:hidden">{@nav.project.name}</span>
        <span class="hidden size-[26px] items-center justify-center rounded-[7px] bg-accent font-mono text-[11px] font-semibold uppercase text-surface collapsed:flex">
          {String.first(@nav.project.name)}
        </span>
        <.icon name="hero-chevron-down" class="ml-auto size-3.5 shrink-0 text-text3 collapsed:hidden" />
      </summary>
      <div class="absolute inset-x-0 top-full z-20 mt-1 overflow-hidden rounded-[10px] border border-border bg-surface shadow-lg collapsed:inset-x-auto collapsed:left-full collapsed:top-0 collapsed:ml-2 collapsed:mt-0 collapsed:w-56">
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
      class="flex shrink-0 cursor-not-allowed items-center gap-2 overflow-hidden rounded-[10px] border border-border bg-surface2 px-2.5 py-2 text-[13px] font-semibold opacity-60 collapsed:size-[38px] collapsed:justify-center collapsed:gap-0 collapsed:border-0 collapsed:bg-transparent collapsed:p-0 collapsed:opacity-100"
    >
      <span class={[
        "size-2 shrink-0 rounded-[3px] collapsed:hidden",
        (@nav.project && "bg-accent") || "bg-border"
      ]} />
      <span class={["truncate collapsed:hidden", (@nav.project && "text-text") || "text-text3"]}>
        {(@nav.project && @nav.project.name) || "No project"}
      </span>
      <span class="hidden size-[26px] items-center justify-center rounded-[7px] border border-dashed border-border font-mono text-[11px] font-semibold uppercase text-text3 collapsed:flex">
        {(@nav.project && String.first(@nav.project.name)) || "—"}
      </span>
      <.icon name="hero-chevron-down" class="ml-auto size-3.5 shrink-0 text-text3 collapsed:hidden" />
    </div>
    """
  end

  # `usage` comes from `CodeLead.Agents.SubscriptionUsageCache` — an
  # undocumented, best-effort reading (see its moduledoc). A window that
  # failed to parse is simply `nil` and its row is omitted.
  attr :id, :string, required: true
  attr :usage, :map, required: true

  defp rate_limit_card(assigns) do
    ~H"""
    <div id={@id} class="flex shrink-0 flex-col gap-2.5 rounded-xl bg-surface2 p-3 collapsed:hidden">
      <span class="text-[11px] font-semibold uppercase tracking-wider text-text3">
        {@usage.provider_name} · Subscription
      </span>
      <.rate_limit_window label="5h window" window={@usage.five_hour} />
      <.rate_limit_window label="Weekly" window={@usage.seven_day} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :window, :map, default: nil

  defp rate_limit_window(assigns) do
    ~H"""
    <div :if={@window} class="flex flex-col gap-1">
      <div class="flex items-center justify-between font-mono text-[13px] font-semibold text-text">
        <span class="font-sans font-normal text-text3">{@label}</span>
        <span>{round(@window.utilization * 100)}%</span>
      </div>
      <.meter
        value={round(@window.utilization * 100)}
        max={100}
        tone={rate_limit_tone(@window.utilization)}
      />
    </div>
    """
  end

  defp rate_limit_tone(utilization) when utilization >= 0.9, do: :warn
  defp rate_limit_tone(_utilization), do: :accent

  # `spend` is month-to-date (`Costs.project_spend_month/1`) because the
  # limit it is measured against runs on the calendar month too — the
  # headline names that month.
  attr :id, :string, required: true
  attr :spend, :map, required: true
  attr :budget_limit_cents, :integer, default: nil

  defp budget_card(assigns) do
    ~H"""
    <div id={@id} class="flex shrink-0 flex-col gap-1.5 rounded-xl bg-surface2 p-3 collapsed:hidden">
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

  defp nav_class(true), do: [@nav_row, "bg-accent-soft font-semibold text-accent"]

  defp nav_class(false),
    do: [@nav_row, "font-medium text-text2 hover:bg-surface2 hover:text-text"]

  defp nav_class(:disabled), do: [@nav_row, "cursor-not-allowed font-medium text-text3"]

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

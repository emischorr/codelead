defmodule CodeLeadWeb.TaskLive.PreviewPane do
  @moduledoc """
  The live-preview surface of the Review tab: an iframe on the task's
  `/preview/:task_id/` proxy URL behind a slim toolbar. The frame is
  same-origin (the path proxy serves it from the app itself), so the
  toolbar drives navigation directly through `contentWindow` — no
  server round-trips.

  The toolbar owns its *own* history stack: an iframe shares the
  browser's joint session history, so `history.back()` would move the
  user's browser instead of the frame. All toolbar navigation goes
  through `location.replace`, which never touches the host history.
  """
  use CodeLeadWeb, :html

  attr :src, :string, required: true, doc: "the task's /preview/<id>/ URL"
  attr :task_id, :integer, required: true

  def preview_pane(assigns) do
    ~H"""
    <div
      id="preview-pane"
      phx-hook=".PreviewFrame"
      phx-update="ignore"
      data-base={"/preview/#{@task_id}"}
      class="flex min-h-0 flex-1 flex-col"
    >
      <div class="flex shrink-0 items-center gap-1 border-b border-border bg-surface px-3 py-1.5 sm:px-4">
        <.toolbar_button action="back" icon="hero-arrow-left" label="Back" />
        <.toolbar_button action="forward" icon="hero-arrow-right" label="Forward" />
        <.toolbar_button action="refresh" icon="hero-arrow-path" label="Refresh" />
        <form data-role="path-form" class="mx-2 min-w-0 flex-1">
          <input
            id="preview-path"
            data-role="path"
            type="text"
            value="/"
            spellcheck="false"
            autocomplete="off"
            autocapitalize="off"
            aria-label="Preview path"
            class="w-full rounded-[7px] border border-transparent bg-surface2 px-2.5 py-1 font-mono text-[11px] text-text2 focus:border-border focus:text-text focus:outline-none"
          />
        </form>
        <a
          id="preview-open"
          data-action="open"
          href={@src}
          target="_blank"
          rel="noopener"
          aria-label="Open preview in a new tab"
          title="Open in new tab"
          class="inline-flex size-7 items-center justify-center rounded-[9px] border border-border text-text2 hover:bg-surface2"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </a>
      </div>

      <iframe
        data-role="frame"
        src={@src}
        title="Task preview"
        class="min-h-0 w-full flex-1 border-0 bg-white"
      >
      </iframe>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PreviewFrame">
      // Same-origin frame: contentWindow is scriptable, but the
      // previewed app can navigate off-origin at any time, so every
      // *read* is guarded. Navigating the frame (location.replace) is
      // permitted even cross-origin. All behavior is client-side.
      //
      // The hook keeps its own history stack and only ever navigates
      // via location.replace — the browser's joint session history
      // never sees a toolbar action. Entries the hook could not read
      // (off-origin pages) are stored as null and skipped over.
      export default {
        mounted() {
          this.frame = this.el.querySelector("[data-role=frame]")
          this.pathInput = this.el.querySelector("[data-role=path]")
          this.open = this.el.querySelector("[data-action=open]")
          this.backButton = this.el.querySelector("#preview-back")
          this.forwardButton = this.el.querySelector("#preview-forward")
          this.base = this.el.dataset.base
          this.stack = []
          this.index = -1
          this.navigating = false

          this.el.querySelectorAll("button[data-action]").forEach((button) => {
            button.addEventListener("click", () => this.run(button.dataset.action))
          })

          this.el.querySelector("[data-role=path-form]").addEventListener("submit", (e) => {
            e.preventDefault()
            this.navigateTo(this.pathInput.value)
          })

          this.onLoad = () => this.loaded()
          this.frame.addEventListener("load", this.onLoad)
          this.updateButtons()
        },

        run(action) {
          if (action === "refresh") {
            try { this.frame.contentWindow.location.reload() } catch (_offOrigin) { }
          }
          if (action === "back") { this.travel(-1) }
          if (action === "forward") { this.travel(1) }
        },

        travel(dir) {
          const i = this.travelTarget(dir)
          if (i === null) return
          this.index = i
          this.navigating = true
          try { this.frame.contentWindow.location.replace(this.stack[i]) } catch (_e) { }
        },

        // Nearest known entry in the given direction; null markers
        // (external pages we could not read) cannot be traveled to.
        travelTarget(dir) {
          let i = this.index + dir
          while (i >= 0 && i < this.stack.length && this.stack[i] === null) i += dir
          return i >= 0 && i < this.stack.length ? i : null
        },

        loaded() {
          let href = null
          try { href = this.frame.contentWindow.location.href } catch (_offOrigin) { }

          if (this.navigating) {
            this.navigating = false
          } else if (href !== this.stack[this.index]) {
            this.push(href)
          }

          if (href) this.patchHistory()
          this.sync(href)
        },

        push(href) {
          this.stack.splice(this.index + 1)
          this.stack.push(href)
          this.index = this.stack.length - 1
        },

        // pushState becomes replaceState so SPA navigations inside the
        // preview (LiveView live-nav, Vite routers) stay out of the
        // host browser's history too; both feed the internal stack.
        // Window globals reset per document, so this re-applies after
        // every full navigation.
        patchHistory() {
          try {
            const win = this.frame.contentWindow
            if (win.__codeleadPreviewPatched) return
            win.__codeleadPreviewPatched = true
            const orig = win.history.replaceState.bind(win.history)
            const after = () => queueMicrotask(() => this.spaNavigated())
            win.history.pushState = (...args) => { orig(...args); after() }
            win.history.replaceState = (...args) => { orig(...args); after() }
          } catch (_offOrigin) { }
        },

        spaNavigated() {
          let href = null
          try { href = this.frame.contentWindow.location.href } catch (_offOrigin) { return }
          if (href !== this.stack[this.index]) this.push(href)
          this.sync(href)
        },

        navigateTo(raw) {
          const path = raw.trim()
          if (path === "") return
          const normalized = path.startsWith("/") ? path : "/" + path
          // No `navigating` flag: the resulting load pushes a stack
          // entry, exactly like a real address bar.
          try { this.frame.contentWindow.location.replace(this.base + normalized) } catch (_e) { }
          this.pathInput.blur()
        },

        sync(href) {
          if (href === null) {
            this.setPath("(external page)")
          } else {
            const url = new URL(href)
            const full = url.pathname + url.search
            const shown = full.startsWith(this.base)
              ? full.slice(this.base.length) || "/"
              : full
            this.setPath(shown)
            this.open.href = href
          }
          this.updateButtons()
        },

        // Never clobber the field while the user is typing in it.
        setPath(value) {
          if (document.activeElement !== this.pathInput) this.pathInput.value = value
        },

        updateButtons() {
          this.backButton.disabled = this.travelTarget(-1) === null
          this.forwardButton.disabled = this.travelTarget(1) === null
        },

        destroyed() {
          this.frame.removeEventListener("load", this.onLoad)
        }
      }
    </script>
    """
  end

  attr :action, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp toolbar_button(assigns) do
    ~H"""
    <button
      id={"preview-#{@action}"}
      type="button"
      data-action={@action}
      aria-label={@label}
      title={@label}
      class="inline-flex size-7 items-center justify-center rounded-[9px] border border-border text-text2 hover:bg-surface2 disabled:pointer-events-none disabled:opacity-40"
    >
      <.icon name={@icon} class="size-3.5" />
    </button>
    """
  end
end

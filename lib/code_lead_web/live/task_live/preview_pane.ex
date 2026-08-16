defmodule CodeLeadWeb.TaskLive.PreviewPane do
  @moduledoc """
  The live-preview surface of the Review tab: an iframe on the task's
  `/preview/:task_id/` proxy URL behind a slim toolbar. The frame is
  same-origin (the path proxy serves it from the app itself), so the
  toolbar drives navigation directly through `contentWindow` — no
  server round-trips.
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
        <span
          data-role="path"
          class="mx-2 min-w-0 flex-1 truncate rounded-[7px] bg-surface2 px-2.5 py-1 font-mono text-[11px] text-text2"
        >
          /
        </span>
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
      // Same-origin frame: contentWindow is scriptable, but any hard
      // navigation could in principle leave the origin, so every access
      // is guarded. All behavior is client-side.
      export default {
        mounted() {
          this.frame = this.el.querySelector("[data-role=frame]")
          this.path = this.el.querySelector("[data-role=path]")
          this.open = this.el.querySelector("[data-action=open]")
          this.base = this.el.dataset.base

          this.el.querySelectorAll("button[data-action]").forEach((button) => {
            button.addEventListener("click", () => this.run(button.dataset.action))
          })

          this.onLoad = () => this.syncPath()
          this.frame.addEventListener("load", this.onLoad)
        },

        run(action) {
          try {
            const win = this.frame.contentWindow
            if (action === "refresh") { win.location.reload() }
            if (action === "back") { win.history.back() }
            if (action === "forward") { win.history.forward() }
          } catch (_offOrigin) { }
        },

        syncPath() {
          try {
            const loc = this.frame.contentWindow.location
            const full = loc.pathname + loc.search
            const shown = full.startsWith(this.base)
              ? full.slice(this.base.length) || "/"
              : full
            this.path.textContent = shown
            this.open.href = loc.href
          } catch (_offOrigin) { }
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
      class="inline-flex size-7 items-center justify-center rounded-[9px] border border-border text-text2 hover:bg-surface2"
    >
      <.icon name={@icon} class="size-3.5" />
    </button>
    """
  end
end

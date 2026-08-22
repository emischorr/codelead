defmodule CodeLeadWeb.TaskLive.TerminalTab do
  @moduledoc """
  The Terminal tab: an xterm.js terminal into the task's execution
  context (host worktree, task folder, or task container), backed by
  `CodeLead.Terminal`. The session outlives the page — the hook
  reattaches by task id and repaints from scrollback.

  The caller resolves the context (`Terminal.context_path/1`) and the
  copy for its absence, so this component needs no knowledge of targets
  or task states.
  """
  use CodeLeadWeb, :html

  attr :task_id, :integer, required: true
  attr :path, :string, default: nil
  attr :empty_message, :string, required: true

  def terminal_tab(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div class="flex shrink-0 items-center gap-2 border-b border-border bg-surface px-4 py-2.5 sm:px-6">
        <span class={["size-[7px] rounded-full", (@path && "bg-ok") || "bg-text3"]} />
        <span class="font-mono text-[11px] text-text2">task-{@task_id}</span>
        <span class="ml-auto truncate font-mono text-[10.5px] text-text3">
          {@path || "no execution context provisioned"}
        </span>
      </div>

      <div
        :if={@path}
        id="terminal"
        phx-hook=".Terminal"
        phx-update="ignore"
        class="flex min-h-0 flex-1 flex-col bg-term-bg"
      >
        <div
          data-role="status"
          hidden
          class="shrink-0 items-center gap-3 border-b border-border/60 px-4 py-1.5 font-mono text-[10.5px] text-term-text/70 [&:not([hidden])]:flex"
        >
          <span data-role="status-text"></span>
          <button
            data-role="restart"
            hidden
            type="button"
            class="rounded-[7px] border border-border/60 px-2 py-0.5 text-term-text hover:bg-white/5"
          >
            Restart shell
          </button>
        </div>
        <div data-role="xterm" class="min-h-0 flex-1 px-2 py-1.5"></div>
      </div>

      <div :if={!@path} class="min-h-0 flex-1 bg-term-bg p-4 sm:p-5">
        <div class="font-mono text-[11.5px] leading-loose text-term-text">
          <p class="text-term-text/60">{@empty_message}</p>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Terminal">
      import { Terminal } from "@/vendor/xterm/xterm.js"
      import { FitAddon } from "@/vendor/xterm/addon-fit.js"

      // Keystrokes and output travel base64-encoded over the LiveView
      // socket — binary-safe through the JSON payloads.
      const toB64 = (str) => {
        let bin = ""
        new TextEncoder().encode(str).forEach((b) => { bin += String.fromCharCode(b) })
        return btoa(bin)
      }
      const fromB64 = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))

      export default {
        mounted() {
          this.statusBar = this.el.querySelector("[data-role=status]")
          this.statusText = this.el.querySelector("[data-role=status-text]")
          this.restart = this.el.querySelector("[data-role=restart]")

          this.term = new Terminal({
            convertEol: true,
            fontSize: 12.5,
            fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
            theme: { background: "#0d1117" }
          })
          this.fit = new FitAddon()
          this.term.loadAddon(this.fit)
          this.term.open(this.el.querySelector("[data-role=xterm]"))
          this.fit.fit()

          this.resizer = new ResizeObserver(() => this.fit.fit())
          this.resizer.observe(this.el)

          // xterm has already re-laid out by the time onResize fires; the
          // shell's pty is resized out-of-band, so debounce the round trip
          // rather than firing one per pixel of a window drag.
          this.term.onResize(({ cols, rows }) => {
            clearTimeout(this.resizeTimer)
            this.resizeTimer = setTimeout(
              () => this.pushEvent("terminal_resize", { cols, rows }),
              150
            )
          })

          this.term.onData((data) => this.pushEvent("terminal_input", { data: toB64(data) }))

          this.handleEvent("terminal:data", ({ data }) => this.term.write(fromB64(data)))
          this.handleEvent("terminal:exit", ({ status }) => {
            // A numeric status is the shell's own exit code; anything
            // else means the session was stopped for us (the execution
            // context went away), and has no code to report.
            const how = typeof status === "number" ? `exited with status ${status}` : "closed"
            this.term.write(`\r\n\x1b[2m[shell ${how}]\x1b[0m\r\n`)
            this.showStatus(`shell ${how}`, { restart: true })
          })

          this.restart.addEventListener("click", () => {
            this.term.reset()
            this.connect()
          })

          this.connect()
        },

        connect() {
          this.hideStatus()
          this.pushEvent(
            "terminal_ready",
            { cols: this.term.cols, rows: this.term.rows },
            (reply) => {
              if (reply.error) {
                this.showStatus(reply.error, { restart: true })
                return
              }
              if (reply.scrollback) { this.term.write(fromB64(reply.scrollback)) }
              if (reply.pty === false) {
                this.showStatus("plain-pipe mode — no prompt echo or line editing (no `script` binary found)")
              }
              this.term.focus()
            }
          )
        },

        showStatus(text, { restart } = {}) {
          this.statusText.textContent = text
          this.restart.hidden = !restart
          this.statusBar.hidden = false
        },

        hideStatus() {
          this.statusBar.hidden = true
          this.restart.hidden = true
        },

        destroyed() {
          clearTimeout(this.resizeTimer)
          this.resizer?.disconnect()
          this.term?.dispose()
        }
      }
    </script>
    """
  end
end

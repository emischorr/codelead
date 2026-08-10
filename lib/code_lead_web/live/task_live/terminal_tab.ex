defmodule CodeLeadWeb.TaskLive.TerminalTab do
  @moduledoc """
  The Terminal tab. A real PTY into the worktree is planned; for now
  this is a styled placeholder showing the execution context.
  """
  use CodeLeadWeb, :html

  attr :task, :map, required: true

  def terminal_tab(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div class="flex shrink-0 items-center gap-2 border-b border-border bg-surface px-4 py-2.5 sm:px-6">
        <span class={["size-[7px] rounded-full", (@task.worktree_path && "bg-ok") || "bg-text3"]} />
        <span class="font-mono text-[11px] text-text2">task-{@task.id}</span>
        <span class="ml-auto truncate font-mono text-[10.5px] text-text3">
          {@task.worktree_path || "no worktree provisioned"}
        </span>
      </div>
      <div class="min-h-0 flex-1 bg-term-bg p-4 sm:p-5">
        <div class="font-mono text-[11.5px] leading-loose text-term-text">
          <p :if={@task.worktree_path}>
            <span class="text-ok">task-{@task.id}</span> <span class="text-accent">❯</span>
            <span class="animate-pulse">▍</span>
          </p>
          <p class="mt-2 text-term-text/60">
            Interactive terminal coming soon — for now, inspect the worktree from your shell:
          </p>
          <p :if={@task.worktree_path} class="mt-1 select-all text-term-text">
            cd {@task.worktree_path}
          </p>
          <p :if={!@task.worktree_path} class="mt-1 text-term-text/60">
            A worktree is provisioned when a repo-targeted run starts.
          </p>
        </div>
      </div>
    </div>
    """
  end
end

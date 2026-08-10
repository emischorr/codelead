defmodule CodeLeadWeb.TaskLive.AgentTab do
  @moduledoc """
  The Agent tab: the executor's live event feed (tool calls, messages,
  questions, permission escalations, results) streamed over the task
  topic, seeded with the audit trail. The composer is disabled — the
  ACP driver doesn't support mid-run messages yet.
  """
  use CodeLeadWeb, :html

  attr :task, :map, required: true
  attr :events, :any, required: true, doc: "the :events LiveView stream"
  attr :current_message, :string, default: nil
  attr :task_spend, :map, required: true

  def agent_tab(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div class="flex shrink-0 items-center gap-2 border-b border-border bg-surface px-4 py-2.5 sm:px-6">
        <span class="truncate font-mono text-[11px] text-text3">
          {session_label(@task.acp_session_id)}
        </span>
        <span class="ml-auto shrink-0 font-mono text-[11px] text-text2">
          {Format.cost_tokens(@task_spend.cost_cents, @task_spend.tokens)}
        </span>
      </div>

      <div
        id="agent-events"
        phx-update="stream"
        class="mx-auto flex w-full max-w-3xl flex-col gap-2.5 p-4 sm:p-6"
      >
        <div class="hidden text-center text-[13px] text-text3 only:block" id="agent-events-empty">
          No agent activity yet — events appear here live during a run.
        </div>
        <.event_card :for={{id, event} <- @events} id={id} event={event} />
      </div>

      <div
        :if={@current_message}
        class="mx-auto w-full max-w-3xl px-4 pb-4 sm:px-6"
        id="agent-live-message"
      >
        <div class="flex flex-col gap-1.5 rounded-[11px] border border-accent/40 bg-surface p-3.5">
          <div class="flex items-center gap-2">
            <span class="rounded-[5px] bg-accent-soft px-1.5 py-0.5 text-[9.5px] font-bold tracking-wide text-accent">
              MSG
            </span>
            <span class="size-1.5 animate-pulse rounded-full bg-accent" />
          </div>
          <p class="whitespace-pre-wrap text-[13px] leading-relaxed text-text" phx-no-format>{@current_message}</p>
        </div>
      </div>

      <div class="sticky bottom-0 mt-auto border-t border-border bg-surface p-3.5">
        <div class="mx-auto flex max-w-3xl gap-2.5">
          <input
            type="text"
            placeholder="Message the agent…"
            disabled
            title="Mid-run messages aren't supported by the ACP driver yet"
            class="h-11 min-w-0 flex-1 cursor-not-allowed rounded-xl border border-border bg-bg px-3.5 text-[13px] text-text placeholder:text-text3 opacity-60"
          />
          <button
            type="button"
            disabled
            title="Mid-run messages aren't supported by the ACP driver yet"
            class="flex size-11 shrink-0 cursor-not-allowed items-center justify-center rounded-xl bg-accent text-white opacity-50"
            aria-label="Send (unavailable)"
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp session_label(nil), do: "no session yet"
  defp session_label(session_id), do: session_id

  attr :id, :string, required: true
  attr :event, :map, required: true

  defp event_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={["flex flex-col gap-1.5 rounded-[11px] border p-3.5", card_border(@event.kind)]}
    >
      <div class="flex items-center gap-2">
        <span class={[
          "rounded-[5px] px-1.5 py-0.5 text-[9.5px] font-bold tracking-wide",
          chip_class(@event.kind)
        ]}>
          {@event.label}
        </span>
        <span :if={@event.meta[:executor_name]} class="text-[10px] text-text3">
          {@event.meta[:executor_name]}
        </span>
        <span class="ml-auto font-mono text-[10px] text-text3">{Format.time(@event.at)}</span>
      </div>
      <p
        class={[
          "whitespace-pre-wrap break-words text-[13px] leading-relaxed",
          text_class(@event.kind)
        ]}
        phx-no-format
      >{@event.text}</p>
      <div :if={@event.kind == :permission && @event.meta[:ref]} class="mt-1 flex gap-2">
        <.button
          variant="primary"
          phx-click="answer_permission"
          phx-value-ref={@event.meta.ref}
          phx-value-granted="true"
          id={"#{@id}-grant"}
        >
          Allow
        </.button>
        <.button
          phx-click="answer_permission"
          phx-value-ref={@event.meta.ref}
          phx-value-granted="false"
          id={"#{@id}-deny"}
        >
          Deny
        </.button>
      </div>
    </div>
    """
  end

  defp card_border(:result_ok), do: "border-ok bg-surface"
  defp card_border(:result_error), do: "border-del-text/40 bg-surface"
  defp card_border(:question), do: "border-warn-border bg-warn-soft"
  defp card_border(:permission), do: "border-warn-border bg-warn-soft"
  defp card_border(_kind), do: "border-border bg-surface"

  defp chip_class(:tool), do: "bg-run-soft text-run"
  defp chip_class(:message), do: "bg-accent-soft text-accent"
  defp chip_class(:question), do: "bg-warn-soft text-warn"
  defp chip_class(:permission), do: "bg-warn text-surface"
  defp chip_class(:result_ok), do: "bg-ok-soft text-ok"
  defp chip_class(:result_error), do: "bg-del-bg text-del-text"
  defp chip_class(_kind), do: "bg-surface2 text-text2"

  defp text_class(:tool), do: "font-mono text-[11.5px] text-text2"
  defp text_class(:result_ok), do: "font-mono text-[11.5px] text-ok"
  defp text_class(:result_error), do: "font-mono text-[11.5px] text-del-text"
  defp text_class(:step), do: "text-text2"
  defp text_class(_kind), do: "text-text"
end

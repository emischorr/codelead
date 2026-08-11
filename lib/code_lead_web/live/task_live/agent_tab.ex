defmodule CodeLeadWeb.TaskLive.AgentTab do
  @moduledoc """
  The Agent tab: the executor's transcript (`CodeLead.AgentFeed`), folded
  into blocks so a burst of tool calls reads as one collapsed group
  instead of a card per status update. The message the agent is still
  writing renders in its own pane below the feed. The composer is
  disabled — the ACP driver doesn't support mid-run messages yet.
  """
  use CodeLeadWeb, :html

  attr :task, :map, required: true
  attr :blocks, :any, required: true, doc: "the :feed LiveView stream of folded blocks"
  attr :live_message, :map, default: nil
  attr :executing?, :boolean, required: true
  attr :all_runs?, :boolean, default: false

  attr :task_stat, :map,
    required: true,
    doc: "%{cost_cents:, tokens:, duration_ms:, cost_mode:} — live while a run executes"

  def agent_tab(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div class="flex shrink-0 items-center gap-2 border-b border-border bg-surface px-4 py-2.5 sm:px-6">
        <span class="truncate font-mono text-[11px] text-text3">
          {session_label(@task.acp_session_id)}
        </span>
        <span class="ml-auto shrink-0 font-mono text-[11px] text-text2">
          {Format.run_stat(
            @task_stat.cost_cents,
            @task_stat.tokens,
            @task_stat.duration_ms,
            @task_stat.cost_mode
          )}
        </span>
      </div>

      <div :if={not @all_runs?} class="mx-auto w-full max-w-3xl px-4 pt-4 sm:px-6">
        <button
          type="button"
          phx-click="show_earlier_runs"
          id="show-earlier-runs"
          class="text-[11px] text-text3 transition-colors hover:text-text2"
        >
          Show earlier runs
        </button>
      </div>

      <div
        id="agent-events"
        phx-update="stream"
        class="mx-auto flex w-full max-w-3xl flex-col gap-3 p-4 sm:p-6"
      >
        <div class="hidden text-center text-[13px] text-text3 only:block" id="agent-events-empty">
          No agent activity yet — events appear here live during a run.
        </div>
        <.feed_block
          :for={{id, block} <- @blocks}
          id={id}
          block={block}
          executing?={@executing?}
        />
      </div>

      <div
        :if={@live_message}
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
          <.markdown text={@live_message.text} class="text-[13px] leading-relaxed text-text" />
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
  attr :block, :map, required: true
  attr :executing?, :boolean, required: true

  defp feed_block(%{block: %{kind: :tools}} = assigns) do
    ~H"""
    <div id={@id} class="px-0.5">
      <button
        type="button"
        phx-click="toggle_block"
        phx-value-id={@block.id}
        id={"#{@id}-toggle"}
        class="-mx-1 flex w-[calc(100%+0.5rem)] items-center gap-2 rounded-lg px-1 py-1 text-left transition-colors hover:bg-surface2"
      >
        <.icon
          name={if @block.expanded?, do: "hero-chevron-down", else: "hero-chevron-right"}
          class="size-3.5 shrink-0 text-text3"
        />
        <span class="min-w-0 flex-1 truncate font-mono text-[11.5px] text-text2">
          {group_label(@block.rows)}
        </span>
        <span :if={pending?(@block.rows)} class="size-1.5 shrink-0 animate-pulse rounded-full bg-run" />
        <span class="shrink-0 font-mono text-[10px] text-text3">
          {Format.time(List.last(@block.rows).inserted_at)}
        </span>
      </button>
      <div :if={@block.expanded?} class="mt-1 flex flex-col gap-1 pl-5">
        <div :for={row <- @block.rows} class="flex items-start gap-2">
          <span class={["mt-1 size-1.5 shrink-0 rounded-full", status_dot(row.data["status"])]} />
          <.tool_line row={row} />
        </div>
      </div>
    </div>
    """
  end

  defp feed_block(%{block: %{kind: :message}} = assigns) do
    assigns = assign(assigns, :row, hd(assigns.block.rows))

    ~H"""
    <div id={@id} class="rounded-[11px] border border-border bg-surface p-3.5">
      <.markdown text={@row.text} class="break-words text-[13px] leading-relaxed text-text" />
    </div>
    """
  end

  defp feed_block(assigns) do
    assigns = assign(assigns, :row, hd(assigns.block.rows))

    ~H"""
    <div id={@id} class={["flex flex-col gap-1.5 rounded-[11px] border p-3.5", card_border(@row)]}>
      <div class="flex items-center gap-2">
        <span class={[
          "rounded-[5px] px-1.5 py-0.5 text-[9.5px] font-bold tracking-wide",
          chip_class(@row)
        ]}>
          {label(@row)}
        </span>
        <span class="ml-auto font-mono text-[10px] text-text3">{Format.time(@row.inserted_at)}</span>
      </div>
      <p
        class={["whitespace-pre-wrap break-words text-[13px] leading-relaxed", text_class(@row)]}
        phx-no-format
      >{notice_text(@row)}</p>
      <div :if={answerable?(@row, @executing?)} class="mt-1 flex gap-2">
        <.button
          variant="primary"
          phx-click="answer_permission"
          phx-value-ref={@row.external_id}
          phx-value-granted="true"
          id={"#{@id}-grant"}
        >
          Allow
        </.button>
        <.button
          phx-click="answer_permission"
          phx-value-ref={@row.external_id}
          phx-value-granted="false"
          id={"#{@id}-deny"}
        >
          Deny
        </.button>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true

  defp tool_line(assigns) do
    {label, detail} = tool_summary(assigns.row)
    assigns = assign(assigns, label: label, detail: detail)

    ~H"""
    <span
      class="min-w-0 flex-1 break-words font-mono text-[11.5px] leading-relaxed text-text2"
      phx-no-format
    ><span class="font-medium">{@label}</span><span :if={@detail} class="text-text3">: {@detail}</span></span>
    """
  end

  defp group_label([row]), do: row |> tool_summary() |> elem(0)
  defp group_label(rows), do: "#{length(rows)} tool calls"

  # `{label, detail}` — the label carries the weight, the detail trails
  # after a colon. A shell call titles itself with its own command, so the
  # description leads and the command is never rendered twice.
  defp tool_summary(%{data: %{"locations" => [path | _rest]}} = row), do: {tool_title(row), path}

  defp tool_summary(%{data: %{"input" => %{"description" => description, "command" => command}}})
       when is_binary(description) and is_binary(command),
       do: {description, command}

  defp tool_summary(%{data: %{"input" => %{"command" => command}}}) when is_binary(command),
    do: {command, nil}

  defp tool_summary(%{data: %{"input" => input}} = row)
       when is_map(input) and map_size(input) > 0,
       do: {tool_title(row), input |> Enum.sort() |> Enum.map_join(" · ", &elem(&1, 1))}

  # Rows recorded before the input was stored field by field carry the raw
  # JSON preview.
  defp tool_summary(%{data: %{"input" => input}} = row) when is_binary(input),
    do: {tool_title(row), input}

  defp tool_summary(row), do: {tool_title(row), nil}

  defp tool_title(%{text: text, data: data}), do: text || data["tool_kind"] || "tool call"

  defp pending?(rows),
    do: Enum.any?(rows, &(&1.data["status"] in [nil, "pending", "in_progress"]))

  defp status_dot("completed"), do: "bg-ok"
  defp status_dot("failed"), do: "bg-del-text"
  defp status_dot("in_progress"), do: "bg-run animate-pulse"
  defp status_dot(_status), do: "bg-text3"

  defp label(%{kind: :run_started}), do: "RUN"
  defp label(%{kind: :question}), do: "QUESTION"
  defp label(%{kind: :permission}), do: "PERMISSION"
  defp label(%{kind: :result}), do: "RESULT"
  defp label(%{kind: kind}), do: kind |> Atom.to_string() |> String.upcase()

  # A result carries no prose of its own on the ACP path — the outcome
  # and what it cost are the message.
  defp notice_text(%{kind: :result, text: text, data: data}) do
    [result_status(data), text] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp notice_text(%{text: text}), do: text

  defp result_status(%{"status" => status} = data) do
    label = if status == "ok", do: "success", else: status

    case Format.run_stat(data["cost_cents"], data["tokens"], data["duration_ms"]) do
      "—" -> label
      stat -> "#{label} · #{stat}"
    end
  end

  defp result_status(_data), do: nil

  defp answerable?(%{kind: :permission, external_id: ref, data: data}, executing?) do
    executing? and is_binary(ref) and is_nil(data["resolved"])
  end

  defp answerable?(_row, _executing?), do: false

  defp card_border(%{kind: :result, data: %{"status" => "ok"}}), do: "border-ok bg-surface"
  defp card_border(%{kind: :result}), do: "border-del-text/40 bg-surface"

  defp card_border(%{kind: kind}) when kind in [:question, :permission],
    do: "border-warn-border bg-warn-soft"

  defp card_border(_row), do: "border-border bg-surface"

  defp chip_class(%{kind: :question}), do: "bg-warn-soft text-warn"
  defp chip_class(%{kind: :permission}), do: "bg-warn text-surface"
  defp chip_class(%{kind: :result, data: %{"status" => "ok"}}), do: "bg-ok-soft text-ok"
  defp chip_class(%{kind: :result}), do: "bg-del-bg text-del-text"
  defp chip_class(_row), do: "bg-surface2 text-text2"

  defp text_class(%{kind: :result, data: %{"status" => "ok"}}),
    do: "font-mono text-[11.5px] text-ok"

  defp text_class(%{kind: :result}), do: "font-mono text-[11.5px] text-del-text"
  defp text_class(_row), do: "text-text"
end

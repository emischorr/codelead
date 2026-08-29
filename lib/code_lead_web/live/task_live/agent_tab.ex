defmodule CodeLeadWeb.TaskLive.AgentTab do
  @moduledoc """
  The Agent tab: the executor's transcript (`CodeLead.AgentFeed`), folded
  into blocks so a burst of tool calls reads as one collapsed group
  instead of a card per status update. The message the agent is still
  writing renders in its own pane below the feed.

  A question row is the exception to "the feed is a transcript": it
  renders the agent's own form — its choices, their descriptions, and a
  free-text box — and submitting it releases the blocked run. The
  composer beside it stays disabled; unprompted mid-run messages are a
  separate capability the ACP driver does not have.
  """
  use CodeLeadWeb, :html

  alias CodeLead.Workspace

  attr :task, :map, required: true
  attr :blocks, :any, required: true, doc: "the :feed LiveView stream of folded blocks"
  attr :live_message, :map, default: nil
  attr :executing?, :boolean, required: true
  attr :all_runs?, :boolean, default: false
  attr :can_operate?, :boolean, default: true

  attr :task_stat, :map,
    required: true,
    doc: "%{cost_cents:, tokens:, duration_ms:, cost_mode:} — live while a run executes"

  def agent_tab(assigns) do
    assigns = assign(assigns, :root, context_root(assigns.task))

    ~H"""
    <div class="flex h-full min-h-0 flex-col">
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

      <%!-- The transcript scrolls here, not in the page pane, so the composer
            below stays a sibling of the scrollport and docks for real. --%>
      <div id="agent-pane" class="min-h-0 flex-1 overflow-y-auto">
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
            <%= if @task.run_state == :dispatched do %>
              <div class="flex flex-col items-center gap-2 py-2">
                <.pulse_dot class="size-2 bg-run" />
                <span>{provisioning_label(@task.execution_env)}</span>
              </div>
            <% else %>
              No agent activity yet — events appear here live during a run.
            <% end %>
          </div>
          <.feed_block
            :for={{id, block} <- @blocks}
            id={id}
            block={block}
            executing?={@executing?}
            can_operate?={@can_operate?}
            root={@root}
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
      </div>

      <div class="shrink-0 border-t border-border bg-surface p-2.5 sm:p-3.5">
        <div class="mx-auto flex max-w-3xl gap-2.5">
          <input
            type="text"
            placeholder="Message the agent…"
            disabled
            title="Mid-run messages aren't supported by the ACP driver yet"
            class="h-10 min-w-0 flex-1 cursor-not-allowed rounded-xl border border-border bg-bg px-3.5 text-[13px] text-text placeholder:text-text3 opacity-60 sm:h-11"
          />
          <button
            type="button"
            disabled
            title="Mid-run messages aren't supported by the ACP driver yet"
            class="flex size-10 shrink-0 cursor-not-allowed items-center justify-center rounded-xl bg-accent text-white opacity-50 sm:size-11"
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

  defp provisioning_label(:container), do: "Provisioning the container environment…"
  defp provisioning_label(_execution_env), do: "Provisioning the workspace…"

  # Where the run works: a git worktree for a :repo task, the task folder
  # for a :folder one. Nil until a :repo task has been provisioned.
  defp context_root(%{target: :repo, worktree_path: path}), do: path
  defp context_root(%{target: :folder, id: id}), do: Workspace.task_folder(id)

  attr :id, :string, required: true
  attr :block, :map, required: true
  attr :executing?, :boolean, required: true
  attr :can_operate?, :boolean, default: true
  attr :root, :string, default: nil, doc: "the run's working directory, stripped from paths"

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
          {group_label(@block.rows, @root)}
        </span>
        <span :if={pending?(@block.rows)} class="size-1.5 shrink-0 animate-pulse rounded-full bg-run" />
        <span class="shrink-0 font-mono text-[10px] text-text3">
          {Format.time(List.last(@block.rows).inserted_at)}
        </span>
      </button>
      <div :if={@block.expanded?} class="mt-1 flex flex-col gap-1 pl-5">
        <div :for={row <- @block.rows} class="flex items-start gap-2">
          <span class={["mt-1 size-1.5 shrink-0 rounded-full", status_dot(row.data["status"])]} />
          <.tool_line row={row} root={@root} />
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

  # The request-changes feedback that became the rework prompt — styled
  # apart from the agent's own messages (accent border/chip) so the human
  # can tell at a glance which turn is theirs.
  defp feed_block(%{block: %{kind: :human_message}} = assigns) do
    assigns = assign(assigns, :row, hd(assigns.block.rows))

    ~H"""
    <div id={@id} class="rounded-[11px] border border-accent/40 bg-accent-soft p-3.5">
      <div class="mb-1.5 flex items-center gap-2">
        <span class="rounded-[5px] bg-accent px-1.5 py-0.5 text-[9.5px] font-bold tracking-wide text-white">
          REQUEST CHANGES
        </span>
        <span class="ml-auto shrink-0 font-mono text-[10px] text-text3">
          {Format.time(@row.inserted_at)}
        </span>
      </div>
      <p class="whitespace-pre-wrap break-words text-[13px] leading-relaxed text-text" phx-no-format>{@row.text}</p>
    </div>
    """
  end

  # A question is the one row a human is expected to act on, so it grows
  # a form instead of a pair of buttons.
  defp feed_block(%{block: %{rows: [%{kind: :question} | _rest]}} = assigns) do
    assigns = assign(assigns, :row, hd(assigns.block.rows))

    ~H"""
    <div id={@id} class={["flex flex-col gap-2.5 rounded-[11px] border p-3.5", card_border(@row)]}>
      <div class="flex items-center gap-2">
        <span class={[
          "rounded-[5px] px-1.5 py-0.5 text-[9.5px] font-bold tracking-wide",
          chip_class(@row)
        ]}>
          {label(@row)}
        </span>
        <span
          :if={@row.data["resolved"]}
          class="rounded-[5px] bg-surface2 px-1.5 py-0.5 text-[9.5px] font-bold tracking-wide text-text2"
        >
          {resolution_label(@row.data["resolved"])}
        </span>
        <span class="ml-auto font-mono text-[10px] text-text3">{Format.time(@row.inserted_at)}</span>
      </div>
      <p class="whitespace-pre-wrap break-words text-[13px] leading-relaxed text-text" phx-no-format>{@row.text}</p>
      <.question_form :if={answerable?(@row, @executing?) && @can_operate?} id={@id} row={@row} />
      <.question_answers :if={@row.data["resolved"]} row={@row} />
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
      <div :if={answerable?(@row, @executing?) && @can_operate?} class="mt-1 flex gap-2">
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

  attr :id, :string, required: true
  attr :row, :map, required: true

  # A plain form rather than `<.form>`: there is no changeset behind an
  # agent question, and a per-row form assign would have to survive every
  # stream reset for nothing. The ref rides in a hidden input because
  # `phx-value-*` does not survive a submit.
  defp question_form(assigns) do
    ~H"""
    <form id={"#{@id}-answer-form"} phx-submit="answer_question" class="flex flex-col gap-3">
      <input type="hidden" name="ref" value={@row.external_id} />
      <.question_field :for={field <- @row.data["fields"] || []} field={field} prefix={@id} />
      <div class="flex gap-2">
        <.button variant="primary" type="submit" id={"#{@id}-answer"} phx-disable-with="Sending…">
          Answer
        </.button>
        <.button
          type="button"
          phx-click="skip_question"
          phx-value-ref={@row.external_id}
          id={"#{@id}-skip"}
        >
          Skip
        </.button>
      </div>
    </form>
    """
  end

  attr :field, :map, required: true
  attr :prefix, :string, required: true

  defp question_field(%{field: %{"type" => type}} = assigns)
       when type in ["select", "multi_select"] do
    assigns = assign(assigns, :multi?, assigns.field["type"] == "multi_select")

    ~H"""
    <fieldset class="flex flex-col gap-1.5">
      <legend class="text-[12px] font-medium text-text2">{@field["label"]}</legend>
      <p :if={@field["description"]} class="text-[11.5px] text-text3">{@field["description"]}</p>
      <label
        :for={{option, index} <- Enum.with_index(@field["options"] || [])}
        class="flex cursor-pointer items-start gap-2 rounded-lg px-1.5 py-1 transition-colors hover:bg-surface2"
      >
        <input
          type={if(@multi?, do: "checkbox", else: "radio")}
          name={"answer[#{@field["key"]}]#{if(@multi?, do: "[]", else: "")}"}
          value={option["value"]}
          id={"#{@prefix}-#{@field["key"]}-#{index}"}
          required={not @multi? and @field["required"]}
          class="mt-0.5 size-3.5 shrink-0 border-border bg-surface text-accent accent-accent focus:ring-accent/40"
        />
        <span class="min-w-0">
          <span class="block text-[13px] leading-snug text-text">{option["label"]}</span>
          <span :if={option["description"]} class="block text-[11.5px] leading-snug text-text3">
            {option["description"]}
          </span>
        </span>
      </label>
    </fieldset>
    """
  end

  defp question_field(%{field: %{"type" => "boolean"}} = assigns) do
    ~H"""
    <.input
      type="checkbox"
      name={"answer[#{@field["key"]}]"}
      value="false"
      label={@field["label"]}
      id={"#{@prefix}-#{@field["key"]}"}
    />
    """
  end

  # Free text covers the "Other" box beside a choice and every generic
  # field the schema did not pin down.
  defp question_field(assigns) do
    ~H"""
    <.input
      type={input_type(@field["type"])}
      name={"answer[#{@field["key"]}]"}
      value=""
      label={@field["label"]}
      placeholder={@field["description"]}
      required={@field["required"]}
      id={"#{@prefix}-#{@field["key"]}"}
    />
    """
  end

  attr :row, :map, required: true

  defp question_answers(assigns) do
    assigns = assign(assigns, :pairs, answered_pairs(assigns.row))

    ~H"""
    <dl :if={@pairs != []} class="flex flex-col gap-1 border-t border-warn-border/40 pt-2.5">
      <div :for={{label, answer} <- @pairs} class="flex gap-2 text-[12px]">
        <dt class="shrink-0 font-medium text-text2">{label}</dt>
        <dd class="min-w-0 break-words text-text">{answer}</dd>
      </div>
    </dl>
    """
  end

  attr :row, :map, required: true
  attr :root, :string, default: nil

  defp tool_line(assigns) do
    {label, detail} = tool_summary(assigns.row, assigns.root)
    assigns = assign(assigns, label: label, detail: detail)

    ~H"""
    <span
      class="min-w-0 flex-1 break-words font-mono text-[11.5px] leading-relaxed text-text2"
      phx-no-format
    ><span class="font-medium">{@label}</span><span :if={@detail} class="text-text3">: {@detail}</span></span>
    """
  end

  defp group_label([row], root), do: row |> tool_summary(root) |> elem(0)
  defp group_label(rows, _root), do: "#{length(rows)} tool calls"

  # `{label, detail}` — the label carries the weight, the detail trails
  # after a colon. A shell call titles itself with its own command, so the
  # description leads and the command is never rendered twice.
  defp tool_summary(%{data: %{"locations" => [path | _rest]}} = row, root),
    do: {tool_title(row), display_path(path, root)}

  defp tool_summary(
         %{data: %{"input" => %{"description" => description, "command" => command}}},
         _root
       )
       when is_binary(description) and is_binary(command),
       do: {description, command}

  defp tool_summary(%{data: %{"input" => %{"command" => command}}}, _root)
       when is_binary(command),
       do: {command, nil}

  defp tool_summary(%{data: %{"input" => input}} = row, root)
       when is_map(input) and map_size(input) > 0,
       do:
         {tool_title(row),
          input |> Enum.sort() |> Enum.map_join(" · ", &display_path(elem(&1, 1), root))}

  # Rows recorded before the input was stored field by field carry the raw
  # JSON preview.
  defp tool_summary(%{data: %{"input" => input}} = row, root) when is_binary(input),
    do: {tool_title(row), display_path(input, root)}

  defp tool_summary(row, _root), do: {tool_title(row), nil}

  # A path inside the run's own directory reads better without the prefix
  # every row would repeat; one left absolute is the signal that the agent
  # reached outside the project.
  defp display_path("/" <> _rest = path, root), do: Format.project_path(path, root) || path
  defp display_path(text, _root), do: text

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

  defp answerable?(%{kind: kind, external_id: ref, data: data}, executing?)
       when kind in [:permission, :question] do
    executing? and is_binary(ref) and is_nil(data["resolved"])
  end

  defp answerable?(_row, _executing?), do: false

  defp input_type("number"), do: "number"
  defp input_type("integer"), do: "number"
  defp input_type(_type), do: "text"

  defp resolution_label("answered"), do: "Answered"
  defp resolution_label("skipped"), do: "Skipped"
  defp resolution_label("cancelled"), do: "Cancelled"
  defp resolution_label(_resolved), do: "Resolved"

  # Only the fields that made it onto the wire are shown — an "Other"
  # answer supersedes its question before the row is written, so a
  # superseded selection is simply absent.
  defp answered_pairs(%{data: data}) do
    answers = data["answers"] || %{}

    for field <- data["fields"] || [],
        answer = answers[field["key"]],
        not is_nil(answer),
        do: {field["label"], format_answer(answer)}
  end

  defp format_answer(answer) when is_list(answer), do: Enum.join(answer, ", ")
  defp format_answer(answer) when is_boolean(answer), do: if(answer, do: "Yes", else: "No")
  defp format_answer(answer), do: to_string(answer)

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

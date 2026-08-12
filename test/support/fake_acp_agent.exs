# A scripted ACP agent speaking newline-delimited JSON-RPC on stdio,
# used by driver tests so no real coding harness is needed. The
# scenario comes from argv:
#
#   elixir fake_acp_agent.exs happy        # chunks + tool_call + usage result
#   elixir fake_acp_agent.exs tool_updates # one tool call across three status updates
#   elixir fake_acp_agent.exs writes_file  # asks the client to write hello.txt
#   elixir fake_acp_agent.exs permission   # escalating permission request (outside path)
#   elixir fake_acp_agent.exs elicitation  # asks the human a form question, if the client allows it
#   elixir fake_acp_agent.exs terminal     # runs `echo hi` through the client terminal
#   elixir fake_acp_agent.exs crash        # exits mid-prompt without a response
#   elixir fake_acp_agent.exs resume       # advertises loadSession; succeeds session/load

defmodule FakeAcpAgent do
  def main([scenario]) do
    loop(%{scenario: scenario, session_counter: 0, capabilities: %{}})
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, _} -> :ok
      line -> state |> handle(JSON.decode!(line)) |> loop()
    end
  end

  # --- client → agent requests ---

  # The real harness gates which tools it offers on what the client
  # advertises, so scenarios need to see the capabilities too.
  defp handle(state, %{"method" => "initialize", "id" => id} = frame) do
    respond(id, %{
      protocolVersion: 1,
      agentCapabilities: %{loadSession: state.scenario == "resume"}
    })

    %{state | capabilities: get_in(frame, ["params", "clientCapabilities"]) || %{}}
  end

  defp handle(state, %{"method" => "session/new", "id" => id}) do
    respond(id, %{sessionId: "fake-sess-#{state.scenario}"})
    state
  end

  defp handle(state, %{"method" => "session/load", "id" => id}) do
    notify("session/update", %{
      sessionId: "resumed",
      update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "replayed"}}
    })

    respond(id, nil)
    state
  end

  defp handle(state, %{"method" => "session/prompt", "id" => id, "params" => params}) do
    session_id = params["sessionId"]
    prompt(state, id, session_id)
    state
  end

  defp handle(state, %{"method" => "session/cancel"}) do
    state
  end

  # --- responses to agent → client requests get correlated by pending ---

  defp handle(state, %{"id" => _id} = _response), do: state
  defp handle(state, _frame), do: state

  # --- scenarios ---

  defp prompt(%{scenario: "happy"}, id, session_id) do
    chunk(session_id, "Working on it. ")

    notify("session/update", %{
      sessionId: session_id,
      update: %{
        sessionUpdate: "tool_call",
        toolCallId: "tc-1",
        title: "Read README",
        kind: "read",
        status: "completed"
      }
    })

    chunk(session_id, "Done.")

    # Money arrives mid-run as a cumulative session total, tokens only
    # at the end — and both in ACP's camelCase spelling.
    notify("session/update", %{
      sessionId: session_id,
      update: %{
        sessionUpdate: "usage_update",
        used: 340,
        size: 200_000,
        cost: %{amount: 0.42, currency: "USD"}
      }
    })

    respond(id, %{
      stopReason: "end_turn",
      usage: %{
        totalTokens: 340,
        inputTokens: 100,
        outputTokens: 40,
        cachedReadTokens: 180,
        cachedWriteTokens: 20
      }
    })
  end

  # A harness that spells usage the Anthropic/OpenAI way and reports no
  # money — the fallback path in `extract_usage/1`.
  defp prompt(%{scenario: "snake_usage"}, id, session_id) do
    chunk(session_id, "Done.")

    respond(id, %{
      stopReason: "end_turn",
      usage: %{input_tokens: 100, output_tokens: 40}
    })
  end

  # One logical tool call announced across three updates, the way a real
  # harness does it: only the first carries a title.
  defp prompt(%{scenario: "tool_updates"}, id, session_id) do
    tool_update(session_id, %{
      sessionUpdate: "tool_call",
      toolCallId: "tc-1",
      title: "Write lib/foo.ex",
      kind: "edit",
      status: "pending",
      locations: [%{path: "lib/foo.ex"}],
      rawInput: %{path: "lib/foo.ex", timeout: 120_000}
    })

    tool_update(session_id, %{
      sessionUpdate: "tool_call_update",
      toolCallId: "tc-1",
      status: "in_progress"
    })

    tool_update(session_id, %{
      sessionUpdate: "tool_call_update",
      toolCallId: "tc-1",
      status: "completed"
    })

    respond(id, %{stopReason: "end_turn", usage: %{input_tokens: 5, output_tokens: 5}})
  end

  defp prompt(%{scenario: "writes_file"}, id, session_id) do
    request(50, "fs/write_text_file", %{
      sessionId: session_id,
      path: Path.join(File.cwd!(), "hello.txt"),
      content: "hello from the fake agent\n"
    })

    await_response(50)
    chunk(session_id, "File written.")
    respond(id, %{stopReason: "end_turn", usage: %{input_tokens: 10, output_tokens: 5}})
  end

  defp prompt(%{scenario: "permission"}, id, session_id) do
    request(60, "session/request_permission", %{
      sessionId: session_id,
      toolCall: %{
        toolCallId: "tc-esc",
        title: "Delete /etc/passwd",
        kind: "delete",
        locations: [%{path: "/etc/passwd"}]
      },
      options: [
        %{optionId: "allow", name: "Allow", kind: "allow_once"},
        %{optionId: "reject", name: "Reject", kind: "reject_once"}
      ]
    })

    outcome = await_response(60)

    chunk(session_id, "decision: #{inspect(outcome)}")
    respond(id, %{stopReason: "end_turn", usage: %{input_tokens: 5, output_tokens: 5}})
  end

  # Mirrors the real adapter's gate: the ask-the-human tool only exists
  # when the client advertised form elicitation, so without it the agent
  # can only say so in prose — which is the bug this scenario guards.
  defp prompt(%{scenario: "elicitation", capabilities: capabilities}, id, session_id) do
    if get_in(capabilities, ["elicitation", "form"]) do
      tool_update(session_id, %{
        sessionUpdate: "tool_call",
        toolCallId: "tc-ask",
        title: "AskUserQuestion",
        kind: "think",
        status: "pending"
      })

      request(80, "elicitation/create", %{
        mode: "form",
        sessionId: session_id,
        toolCallId: "tc-ask",
        message: "Which approach should I take?",
        requestedSchema: %{
          type: "object",
          properties: %{
            question_0: %{
              type: "string",
              title: "Approach",
              oneOf: [
                %{
                  const: "Refactor first",
                  title: "Refactor first",
                  description: "Clean up, then build"
                },
                %{const: "Ship it", title: "Ship it"}
              ]
            },
            question_0_custom: %{
              type: "string",
              title: "Other",
              description: "Type your own answer instead of choosing an option above (optional).",
              _meta: %{
                "_askUserQuestionCustomAnswer" => %{
                  questionId: "question_0",
                  isCustomAnswer: true
                }
              }
            },
            question_1: %{
              type: "array",
              title: "Areas",
              description: "Which areas?",
              items: %{anyOf: [%{const: "api", title: "API"}, %{const: "ui", title: "UI"}]}
            }
          }
        }
      })

      case await_response(80) do
        # A cancelled elicitation aborts the tool call, and with it the
        # turn — the client has already hung up, so say nothing more.
        %{"action" => "cancel"} -> System.halt(0)
        answer -> chunk(session_id, "answered: #{JSON.encode!(answer)}")
      end
    else
      chunk(session_id, "no elicitation support")
    end

    respond(id, %{stopReason: "end_turn", usage: %{input_tokens: 5, output_tokens: 5}})
  end

  defp prompt(%{scenario: "terminal"}, id, session_id) do
    request(70, "terminal/create", %{
      sessionId: session_id,
      command: "sh",
      args: ["-c", "printf terminal-says-hi"]
    })

    %{"terminalId" => terminal_id} = await_response(70)

    request(71, "terminal/wait_for_exit", %{sessionId: session_id, terminalId: terminal_id})
    _exit_status = await_response(71)

    request(72, "terminal/output", %{sessionId: session_id, terminalId: terminal_id})
    %{"output" => output} = await_response(72)

    chunk(session_id, "terminal output: #{output}")
    respond(id, %{stopReason: "end_turn", usage: %{input_tokens: 5, output_tokens: 5}})
  end

  defp prompt(%{scenario: "crash"}, _id, session_id) do
    chunk(session_id, "about to crash")
    System.halt(3)
  end

  defp prompt(%{scenario: "resume"}, id, session_id) do
    chunk(session_id, "continuing where we left off")
    respond(id, %{stopReason: "end_turn", usage: %{input_tokens: 20, output_tokens: 10}})
  end

  # --- plumbing ---

  defp chunk(session_id, text) do
    notify("session/update", %{
      sessionId: session_id,
      update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: text}}
    })
  end

  defp tool_update(session_id, update) do
    notify("session/update", %{sessionId: session_id, update: update})
  end

  defp respond(id, result) do
    emit(%{jsonrpc: "2.0", id: id, result: result})
  end

  defp notify(method, params) do
    emit(%{jsonrpc: "2.0", method: method, params: params})
  end

  defp request(id, method, params) do
    emit(%{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  defp await_response(id) do
    case IO.read(:stdio, :line) do
      :eof ->
        System.halt(4)

      line ->
        case JSON.decode!(line) do
          %{"id" => ^id, "result" => result} -> result
          %{"id" => ^id, "error" => error} -> {:error, error}
          _other -> await_response(id)
        end
    end
  end

  defp emit(map) do
    IO.write(:stdio, [JSON.encode!(map), ?\n])
  end
end

FakeAcpAgent.main(System.argv())

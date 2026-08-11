defmodule CodeLead.AgentDriver.LlmApi do
  @moduledoc """
  Single-completion driver: one request to the agent's provider
  (Anthropic API, OpenAI, or Ollama) via Req. Used for reviews, short
  content, and the planning assistant. No streaming — the full
  completion arrives as one `{:message_chunk, text}` followed by the
  `{:result, ...}`.
  """

  @behaviour CodeLead.AgentDriver

  alias CodeLead.Agents
  alias CodeLead.Agents.Agent

  @receive_timeout 120_000
  @max_tokens 8192

  # Nothing to launch — the provider is reached over HTTP, and a bad
  # credential only shows up in the response.
  @impl CodeLead.AgentDriver
  def preflight(%Agent{}), do: :ok

  @impl CodeLead.AgentDriver
  def start_run(_task, %Agent{} = agent, _context, prompt) do
    provider = Agents.get_provider!(agent.provider_id)
    caller = self()

    Task.Supervisor.start_child(CodeLead.TaskSupervisor, fn ->
      handle = self()

      case complete(provider.kind, provider.config, agent, messages(prompt)) do
        {:ok, content, usage} ->
          send(caller, {:agent_event, handle, {:message_chunk, content}})

          send(
            caller,
            {:agent_event, handle,
             {:result, %{status: :ok, content: content, usage: usage, session_id: nil}}}
          )

        {:error, reason} ->
          send(
            caller,
            {:agent_event, handle,
             {:result, %{status: :error, content: inspect(reason), usage: nil, session_id: nil}}}
          )
      end
    end)
  end

  @impl CodeLead.AgentDriver
  def send_message(_handle, _message), do: {:error, :not_supported}

  @impl CodeLead.AgentDriver
  def cancel(handle) when is_pid(handle) do
    Task.Supervisor.terminate_child(CodeLead.TaskSupervisor, handle)
    :ok
  end

  @doc """
  One blocking completion call — the driver internals, exposed for
  callers that want a synchronous exchange (planning chat).
  """
  @spec complete(atom(), map(), Agent.t(), [map()]) ::
          {:ok, String.t(), CodeLead.AgentDriver.usage()} | {:error, term()}
  def complete(:anthropic_api, config, agent, messages) do
    body = %{
      model: agent.model_variant,
      max_tokens: @max_tokens,
      system: agent.system_prompt || "",
      messages: messages
    }

    request(
      url: "https://api.anthropic.com/v1/messages",
      headers: [
        {"x-api-key", config["api_key"]},
        {"anthropic-version", "2023-06-01"}
      ],
      json: body
    )
    |> parse_response(&parse_anthropic/1)
  end

  def complete(:openai, config, agent, messages) do
    system =
      if agent.system_prompt, do: [%{role: :system, content: agent.system_prompt}], else: []

    body = %{model: agent.model_variant, messages: system ++ messages}

    request(
      url: "https://api.openai.com/v1/chat/completions",
      auth: {:bearer, config["api_key"]},
      json: body
    )
    |> parse_response(&parse_openai/1)
  end

  def complete(:ollama, config, agent, messages) do
    system =
      if agent.system_prompt, do: [%{role: :system, content: agent.system_prompt}], else: []

    body = %{model: agent.model_variant, messages: system ++ messages, stream: false}

    request(
      url: "#{config["endpoint"]}/api/chat",
      json: body
    )
    |> parse_response(&parse_ollama/1)
  end

  def complete(kind, _config, _agent, _messages), do: {:error, {:unsupported_provider, kind}}

  defp messages(prompt) when is_binary(prompt), do: [%{role: :user, content: prompt}]
  defp messages(prompt) when is_list(prompt), do: prompt

  defp request(opts) do
    opts =
      Keyword.merge(
        [method: :post, receive_timeout: @receive_timeout],
        opts ++ Application.get_env(:code_lead, :llm_api_req_options, [])
      )

    Req.request(opts)
  end

  defp parse_response({:ok, %Req.Response{status: 200, body: body}}, parser), do: parser.(body)

  defp parse_response({:ok, %Req.Response{status: status, body: body}}, _parser),
    do: {:error, {:http_error, status, body}}

  defp parse_response({:error, exception}, _parser), do: {:error, exception}

  defp parse_anthropic(%{"content" => content, "usage" => usage}) do
    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])

    {:ok, text,
     usage(usage["input_tokens"], usage["output_tokens"],
       cached_read: usage["cache_read_input_tokens"],
       cached_write: usage["cache_creation_input_tokens"]
     )}
  end

  defp parse_anthropic(body), do: {:error, {:unexpected_response, body}}

  defp parse_openai(%{"choices" => [%{"message" => %{"content" => text}} | _], "usage" => usage}) do
    {:ok, text, usage(usage["prompt_tokens"], usage["completion_tokens"])}
  end

  defp parse_openai(body), do: {:error, {:unexpected_response, body}}

  defp parse_ollama(%{"message" => %{"content" => text}} = body) do
    {:ok, text, usage(body["prompt_eval_count"], body["eval_count"])}
  end

  defp parse_ollama(body), do: {:error, {:unexpected_response, body}}

  defp usage(prompt_tokens, completion_tokens, opts \\ []) do
    prompt_tokens = prompt_tokens || 0
    completion_tokens = completion_tokens || 0
    cached_read = opts[:cached_read] || 0
    cached_write = opts[:cached_write] || 0

    %{
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      cached_read_tokens: cached_read,
      cached_write_tokens: cached_write,
      reasoning_tokens: 0,
      total_tokens: prompt_tokens + completion_tokens + cached_read + cached_write,
      cost_cents: nil
    }
  end
end

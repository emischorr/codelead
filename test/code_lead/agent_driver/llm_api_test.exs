defmodule CodeLead.AgentDriver.LlmApiTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures

  alias CodeLead.AgentDriver.LlmApi

  defp stub_response(fun) do
    Req.Test.stub(CodeLead.LlmApiStub, fun)
  end

  defp await_events(handle, acc \\ []) do
    receive do
      {:agent_event, ^handle, {:result, result}} ->
        {Enum.reverse(acc), result}

      {:agent_event, ^handle, event} ->
        await_events(handle, [event | acc])
    after
      5_000 -> flunk("no result event; got #{inspect(Enum.reverse(acc))}")
    end
  end

  describe "anthropic_api" do
    test "returns content and usage from a messages response" do
      provider = provider_fixture(%{kind: :anthropic_api, config: %{"api_key" => "sk-x"}})

      agent =
        agent_fixture(%{
          provider_id: provider.id,
          driver: :llm_api,
          model_variant: "claude-sonnet-5",
          system_prompt: "Be terse."
        })

      stub_response(fn conn ->
        assert ["sk-x"] = Plug.Conn.get_req_header(conn, "x-api-key")
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "claude-sonnet-5"
        assert decoded["system"] == "Be terse."
        assert [%{"role" => "user", "content" => "Say hi"}] = decoded["messages"]

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "Hi there"}],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })
      end)

      {:ok, handle} = LlmApi.start_run(nil, agent, nil, "Say hi")
      {events, result} = await_events(handle)

      assert [{:message_chunk, "Hi there"}] = events
      assert result.status == :ok
      assert result.content == "Hi there"
      assert result.usage.prompt_tokens == 10
      assert result.usage.completion_tokens == 5
      assert result.usage.total_tokens == 15
      assert result.session_id == nil
    end
  end

  describe "openai" do
    test "returns content and usage from a chat completion" do
      provider = provider_fixture(%{kind: :openai, config: %{"api_key" => "sk-oai"}})

      agent =
        agent_fixture(%{provider_id: provider.id, driver: :llm_api, model_variant: "gpt-5"})

      stub_response(fn conn ->
        assert ["Bearer sk-oai"] = Plug.Conn.get_req_header(conn, "authorization")

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}],
          "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3, "total_tokens" => 10}
        })
      end)

      {:ok, handle} = LlmApi.start_run(nil, agent, nil, "Say hi")
      {_events, result} = await_events(handle)

      assert result.status == :ok
      assert result.content == "Hello"
      assert result.usage.total_tokens == 10
    end
  end

  describe "ollama" do
    test "uses the configured endpoint and parses eval counts" do
      provider =
        provider_fixture(%{kind: :ollama, config: %{"endpoint" => "http://ollama.local:11434"}})

      agent =
        agent_fixture(%{provider_id: provider.id, driver: :llm_api, model_variant: "llama3.1"})

      stub_response(fn conn ->
        assert conn.host == "ollama.local"
        assert conn.request_path == "/api/chat"

        Req.Test.json(conn, %{
          "message" => %{"role" => "assistant", "content" => "Moin"},
          "prompt_eval_count" => 4,
          "eval_count" => 2
        })
      end)

      {:ok, handle} = LlmApi.start_run(nil, agent, nil, "Say hi")
      {_events, result} = await_events(handle)

      assert result.status == :ok
      assert result.content == "Moin"
      assert result.usage.total_tokens == 6
    end
  end

  describe "errors" do
    test "http errors produce an error result, not a crash" do
      provider = provider_fixture(%{kind: :anthropic_api, config: %{"api_key" => "sk-x"}})
      agent = agent_fixture(%{provider_id: provider.id, driver: :llm_api})

      stub_response(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, ~s({"error": "rate limited"}))
      end)

      {:ok, handle} = LlmApi.start_run(nil, agent, nil, "Say hi")
      {[], result} = await_events(handle)

      assert result.status == :error
      assert result.content =~ "429"
    end
  end

  describe "message history" do
    test "a message list is passed through for multi-turn chats" do
      provider = provider_fixture(%{kind: :anthropic_api, config: %{"api_key" => "sk-x"}})
      agent = agent_fixture(%{provider_id: provider.id, driver: :llm_api})

      stub_response(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert [
                 %{"role" => "user", "content" => "One"},
                 %{"role" => "assistant", "content" => "Two"},
                 %{"role" => "user", "content" => "Three"}
               ] = Jason.decode!(body)["messages"]

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "Four"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      messages = [
        %{role: :user, content: "One"},
        %{role: :assistant, content: "Two"},
        %{role: :user, content: "Three"}
      ]

      {:ok, handle} = LlmApi.start_run(nil, agent, nil, messages)
      {_events, result} = await_events(handle)
      assert result.content == "Four"
    end
  end
end

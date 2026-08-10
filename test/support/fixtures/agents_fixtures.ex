defmodule CodeLead.AgentsFixtures do
  @moduledoc """
  Test fixtures for the Agents context.
  """

  alias CodeLead.Agents

  def provider_fixture(attrs \\ %{}) do
    {:ok, provider} =
      attrs
      |> Enum.into(%{
        name: "provider-#{System.unique_integer([:positive])}",
        kind: :anthropic_api,
        config: %{"api_key" => "sk-test"}
      })
      |> Agents.create_provider()

    provider
  end

  def agent_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    provider_id = attrs[:provider_id] || provider_fixture().id

    {:ok, agent} =
      attrs
      |> Map.put_new(:name, "Agent #{System.unique_integer([:positive])}")
      |> Map.put_new(:scope, :org)
      |> Map.put_new(:roles, [:execute])
      |> Map.put_new(:work_type, :code)
      |> Map.put_new(:driver, :llm_api)
      |> Map.put(:provider_id, provider_id)
      |> Agents.create_agent()

    agent
  end
end

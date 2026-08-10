defmodule CodeLead.AccountsFixtures do
  @moduledoc """
  Test fixtures for the Accounts context.
  """

  alias CodeLead.Accounts

  @doc """
  Ensures the organization singleton exists and returns it.
  """
  def organization_fixture(attrs \\ %{}) do
    {:ok, organization} =
      attrs
      |> Enum.into(%{name: "Test Org"})
      |> Accounts.ensure_organization()

    organization
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: "user#{System.unique_integer([:positive])}@example.com"})
      |> Accounts.create_user()

    user
  end
end

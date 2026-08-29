defmodule CodeLead.AccountsFixtures do
  @moduledoc """
  Test fixtures for the Accounts context.
  """

  import Ecto.Query

  alias CodeLead.Accounts
  alias CodeLead.Accounts.Scope

  @doc """
  Ensures the organization singleton exists and returns it.

  Defaults to a *set up* instance so tests reach the app instead of being
  redirected to the setup wizard by `CodeLeadWeb.SetupGate`.
  """
  def organization_fixture(attrs \\ %{}) do
    {:ok, organization} =
      attrs
      |> Enum.into(%{name: "Test Org", settings: %{"setup_done" => true}})
      |> Accounts.ensure_organization()

    organization
  end

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def unique_username, do: "user#{System.unique_integer([:positive])}"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: unique_username(),
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    {role, attrs} = attrs |> Map.new() |> Map.pop(:role)
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    if role, do: CodeLead.Repo.update!(Ecto.Changeset.change(user, role: role)), else: user
  end

  def admin_fixture(attrs \\ %{}), do: user_fixture(Map.put(Map.new(attrs), :role, :admin))

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  @doc """
  Makes the user a member of the project with the given role and returns the
  membership. Rebuild the scope afterwards (`user_scope_fixture/1`) — an
  existing scope does not see new rows.
  """
  def membership_fixture(project, user, role \\ :maintainer) do
    CodeLead.Repo.insert!(%CodeLead.Accounts.ProjectMembership{
      project_id: project.id,
      user_id: user.id,
      role: role
    })
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    CodeLead.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    CodeLead.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def generate_user_invite_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "invite")
    CodeLead.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    CodeLead.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end

defmodule CodeLead.Accounts do
  @moduledoc """
  The organization singleton, its users, and the authentication flows
  (registration, sessions, magic links, password/email changes).

  The instance-level `setup_done` flag lives in `organizations.settings` and
  gates the first-run wizard — see `CodeLeadWeb.SetupGate`.
  """

  import Ecto.Query

  alias CodeLead.Accounts.Organization
  alias CodeLead.Accounts.Policy
  alias CodeLead.Accounts.ProjectMembership
  alias CodeLead.Accounts.Scope
  alias CodeLead.Accounts.User
  alias CodeLead.Accounts.UserNotifier
  alias CodeLead.Accounts.UserToken
  alias CodeLead.Mailer
  alias CodeLead.Repo

  ## Organization

  @doc """
  Fetches the organization singleton. Raises if the instance has not
  been set up yet.
  """
  @spec get_organization!() :: Organization.t()
  def get_organization! do
    Repo.one!(Organization)
  end

  @doc """
  Creates the organization if it does not exist yet, otherwise returns
  the existing one. Used by the seeds and the setup wizard.
  """
  @spec ensure_organization(map()) :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def ensure_organization(attrs) do
    case Repo.one(Organization) do
      nil -> %Organization{} |> Organization.changeset(attrs) |> Repo.insert()
      organization -> {:ok, organization}
    end
  end

  @doc """
  Updates organization settings or budget limits. System-level — used by the
  setup wizard and `complete_setup/0`, which run inside their own trust
  boundary. Browser-facing edits go through `update_organization/2`.
  """
  @spec update_organization(map()) :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def update_organization(attrs) do
    get_organization!()
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the admin-editable organization details (name, budget limits and
  the default project budget limits). Never touches `settings`.
  """
  @spec update_organization(Scope.t() | nil, map()) ::
          {:ok, Organization.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def update_organization(scope, attrs) do
    with :ok <- Policy.authorize(scope, :manage_organization) do
      get_organization!()
      |> Organization.details_changeset(attrs)
      |> Repo.update()
    end
  end

  ## Setup

  @doc """
  Whether the first-run wizard has been completed. Never raises — it is read
  on every browser request, including on an empty database.
  """
  @spec setup_done?() :: boolean()
  def setup_done? do
    case Repo.one(from o in Organization, select: o.settings) do
      nil -> false
      settings -> Map.get(settings, "setup_done") == true
    end
  end

  @doc """
  Marks the first-run wizard as completed.
  """
  @spec complete_setup() :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def complete_setup do
    organization = get_organization!()
    update_organization(%{settings: Map.put(organization.settings, "setup_done", true)})
  end

  @doc """
  Registers the instance admin from the setup wizard: the first user, with a
  password and already confirmed — a self-hosted first run has no mail
  transport, and the wizard itself is the trust boundary.

  Refuses once any user exists; further users are invited from Settings.
  """
  @spec register_admin(map()) ::
          {:ok, User.t()} | {:error, :already_registered | Ecto.Changeset.t()}
  def register_admin(attrs) do
    if any_users?() do
      {:error, :already_registered}
    else
      %User{role: :admin}
      |> User.changeset(attrs)
      |> User.password_changeset(attrs)
      |> User.confirm_changeset()
      |> Repo.insert()
    end
  end

  @doc """
  Changeset for the wizard's admin form. Skips the uniqueness query and
  password hashing so it is cheap enough for live validation.
  """
  @spec change_admin_registration(map()) :: Ecto.Changeset.t()
  def change_admin_registration(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs, validate_unique: false)
    |> User.password_changeset(attrs, hash_password: false)
  end

  ## Users

  @spec list_users() :: [User.t()]
  def list_users do
    Repo.all(from u in User, order_by: u.username)
  end

  @spec get_user!(pos_integer()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @spec get_user(pos_integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Whether the instance has any user at all. Used by the setup wizard.
  """
  @spec any_users?() :: boolean()
  def any_users?, do: Repo.exists?(User)

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  @spec get_user_by_username(String.t()) :: User.t() | nil
  def get_user_by_username(username) when is_binary(username),
    do: Repo.get_by(User, username: username)

  @doc """
  Gets a user by username and password, or `nil` when either does not match.
  """
  @spec get_user_by_username_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = Repo.get_by(User, username: username)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Creates a user. `role` is stamped on the struct rather than cast, so it can
  never be set from form params.

  A `password` in the attrs sets it directly and confirms the account —
  `login_user_by_magic_link/1` refuses an unconfirmed user that has a password.
  Without one the user is left unconfirmed and gains access by magic link.
  """
  @spec create_user(Scope.t() | nil, map()) ::
          {:ok, User.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_user(scope, attrs) do
    with :ok <- Policy.authorize(scope, :manage_users) do
      %User{role: attrs[:role] || attrs["role"] || :member}
      |> User.changeset(attrs)
      |> put_initial_password(attrs[:password] || attrs["password"], attrs)
      |> Repo.insert()
    end
  end

  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Changeset for the user form. Pass `with_password: true` to also validate an
  initial password without hashing it, for live validation.
  """
  @spec change_user(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_user(user, attrs \\ %{}, opts \\ []) do
    changeset = User.changeset(user, attrs)

    if Keyword.get(opts, :with_password, false) do
      User.password_changeset(changeset, attrs, hash_password: false)
    else
      changeset
    end
  end

  @doc """
  Deletes a user. Refuses to delete the last one — with registration closed,
  an instance with no users cannot be recovered through the browser — and the
  last admin, since instance administration would become unreachable.
  """
  @spec delete_user(Scope.t() | nil, User.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :last_user | :last_admin}
  def delete_user(scope, %User{} = user) do
    with :ok <- Policy.authorize(scope, :manage_users) do
      cond do
        Repo.aggregate(User, :count) <= 1 -> {:error, :last_user}
        user.role == :admin and admin_count() <= 1 -> {:error, :last_admin}
        true -> Repo.delete(user)
      end
    end
  end

  @doc """
  Changes a user's instance role. Refuses to demote the last admin.
  """
  @spec update_user_role(Scope.t() | nil, User.t(), :admin | :member) ::
          {:ok, User.t()} | {:error, :unauthorized | :last_admin}
  def update_user_role(scope, %User{} = user, role) when role in [:admin, :member] do
    with :ok <- Policy.authorize(scope, :manage_users) do
      if user.role == :admin and role != :admin and admin_count() <= 1 do
        {:error, :last_admin}
      else
        user
        |> Ecto.Changeset.change(role: role)
        |> Repo.update()
        |> tap_scope_change(user.id)
      end
    end
  end

  defp admin_count do
    Repo.aggregate(from(u in User, where: u.role == :admin), :count)
  end

  defp put_initial_password(changeset, blank, _attrs) when blank in [nil, ""], do: changeset

  defp put_initial_password(changeset, _password, attrs) do
    changeset
    |> User.password_changeset(attrs)
    |> User.confirm_changeset()
  end

  ## Project memberships

  @doc """
  The user's project roles as `%{project_id => role}`. Loaded once into the
  `Scope` per request/mount; admins skip it entirely.
  """
  @spec membership_map(pos_integer()) :: %{pos_integer() => ProjectMembership.role()}
  def membership_map(user_id) do
    Repo.all(
      from m in ProjectMembership,
        where: m.user_id == ^user_id,
        select: {m.project_id, m.role}
    )
    |> Map.new()
  end

  @spec list_project_members(pos_integer()) :: [ProjectMembership.t()]
  def list_project_members(project_id) do
    Repo.all(
      from m in ProjectMembership,
        join: u in assoc(m, :user),
        where: m.project_id == ^project_id,
        order_by: u.username,
        preload: [user: u]
    )
  end

  @spec get_project_membership!(pos_integer()) :: ProjectMembership.t()
  def get_project_membership!(id), do: ProjectMembership |> Repo.get!(id) |> Repo.preload(:user)

  @doc """
  Adds a user to a project. Open sessions of the user pick the new access up
  via the `{:scope_changed, user_id}` broadcast.
  """
  @spec add_project_member(Scope.t() | nil, pos_integer(), pos_integer(), atom()) ::
          {:ok, ProjectMembership.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def add_project_member(scope, project_id, user_id, role) do
    with :ok <- Policy.authorize(scope, :manage_project, project_id) do
      %ProjectMembership{project_id: project_id, user_id: user_id}
      |> ProjectMembership.changeset(%{role: role})
      |> Repo.insert()
      |> preload_member_user()
      |> tap_scope_change(user_id)
    end
  end

  @spec update_project_member_role(Scope.t() | nil, ProjectMembership.t(), atom()) ::
          {:ok, ProjectMembership.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def update_project_member_role(scope, %ProjectMembership{} = membership, role) do
    with :ok <- Policy.authorize(scope, :manage_project, membership.project_id) do
      membership
      |> ProjectMembership.changeset(%{role: role})
      |> Repo.update()
      |> preload_member_user()
      |> tap_scope_change(membership.user_id)
    end
  end

  @spec remove_project_member(Scope.t() | nil, ProjectMembership.t()) ::
          {:ok, ProjectMembership.t()} | {:error, :unauthorized}
  def remove_project_member(scope, %ProjectMembership{} = membership) do
    with :ok <- Policy.authorize(scope, :manage_project, membership.project_id) do
      membership
      |> Repo.delete()
      |> tap_scope_change(membership.user_id)
    end
  end

  @doc """
  The users a task on this project can be assigned to: its members plus all
  admins (who bypass membership).
  """
  @spec list_assignable_users(pos_integer()) :: [User.t()]
  def list_assignable_users(project_id) do
    Repo.all(
      from u in User,
        left_join: m in ProjectMembership,
        on: m.user_id == u.id and m.project_id == ^project_id,
        where: u.role == :admin or not is_nil(m.id),
        order_by: u.username
    )
  end

  @doc """
  Subscribes to the user's scope-change topic. `{:scope_changed, user_id}`
  fires when their instance role or any project membership changes.
  """
  @spec subscribe_user(pos_integer()) :: :ok | {:error, term()}
  def subscribe_user(user_id) do
    Phoenix.PubSub.subscribe(CodeLead.PubSub, user_topic(user_id))
  end

  @spec user_topic(pos_integer()) :: String.t()
  def user_topic(user_id), do: "user:#{user_id}"

  @doc """
  Tells the user's open sessions their scope changed. Fired by every
  membership and role write here; `CodeLead.Projects.delete_project/2` calls
  it for the members its cascade removes.
  """
  @spec notify_scope_changed(pos_integer()) :: :ok
  def notify_scope_changed(user_id) do
    Phoenix.PubSub.broadcast(CodeLead.PubSub, user_topic(user_id), {:scope_changed, user_id})
    :ok
  end

  defp preload_member_user({:ok, membership}), do: {:ok, Repo.preload(membership, :user)}
  defp preload_member_user(other), do: other

  defp tap_scope_change({:ok, _} = result, user_id) do
    notify_scope_changed(user_id)
    result
  end

  defp tap_scope_change(other, _user_id), do: other

  ## User registration

  @doc """
  Registers a user with no password. Test-fixture only — the app has no
  self-signup route. Leaves the account unconfirmed; it gains access via a
  magic link once it has an email.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `CodeLead.Accounts.User.email_changeset/3` for a list of supported options.
  """
  @spec change_user_email(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `CodeLead.Accounts.User.password_changeset/3` for a list of supported options.
  """
  @spec change_user_password(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.
  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.

  Returns `{:error, :mail_disabled}` on an instance with no mail transport —
  the check comes before the token is minted, so a hand-crafted request can't
  leave an unusable token behind.
  """
  @spec deliver_login_instructions(User.t(), (String.t() -> String.t())) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    if Mailer.enabled?() do
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")
      Repo.insert!(user_token)
      UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
    else
      {:error, :mail_disabled}
    end
  end

  @doc """
  Delivers an admin-issued invite. The token uses the longer-lived "invite"
  context rather than the login page's short-lived magic link.
  """
  @spec deliver_invite_instructions(User.t(), (String.t() -> String.t())) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_invite_instructions(%User{} = user, invite_url_fun)
      when is_function(invite_url_fun, 1) do
    if Mailer.enabled?() do
      {encoded_token, user_token} = UserToken.build_email_token(user, "invite")
      Repo.insert!(user_token)
      UserNotifier.deliver_invite_instructions(user, invite_url_fun.(encoded_token))
    else
      {:error, :mail_disabled}
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end

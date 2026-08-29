defmodule CodeLead.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `CodeLead.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user.

  Besides the user it carries the instance role and the user's project
  memberships (`%{project_id => role}`), loaded once per request/mount so
  `CodeLead.Accounts.Policy` can answer authorization questions without
  further queries. Admins never consult the map — `project_role/2`
  short-circuits to `:maintainer` for them — so it stays empty for admins.
  """

  alias CodeLead.Accounts
  alias CodeLead.Accounts.User

  defstruct user: nil, role: nil, memberships: %{}

  @type t :: %__MODULE__{
          user: User.t() | nil,
          role: :admin | :member | nil,
          memberships: %{optional(pos_integer()) => Accounts.ProjectMembership.role()}
        }

  @doc """
  Creates a scope for the given user, loading their project memberships.

  Returns nil if no user is given.
  """
  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{role: :admin} = user) do
    %__MODULE__{user: user, role: :admin}
  end

  def for_user(%User{} = user) do
    %__MODULE__{user: user, role: user.role, memberships: Accounts.membership_map(user.id)}
  end

  def for_user(nil), do: nil

  @doc """
  Rebuilds the scope from the database, or nil when the user is gone.
  """
  @spec refresh(t()) :: t() | nil
  def refresh(%__MODULE__{user: %User{id: id}}) do
    id |> Accounts.get_user() |> for_user()
  end

  @spec admin?(t() | nil) :: boolean()
  def admin?(%__MODULE__{role: :admin}), do: true
  def admin?(_scope), do: false

  @doc """
  The caller's role on a project; admins are `:maintainer` everywhere.
  """
  @spec project_role(t() | nil, pos_integer()) :: Accounts.ProjectMembership.role() | nil
  def project_role(%__MODULE__{role: :admin}, _project_id), do: :maintainer

  def project_role(%__MODULE__{memberships: memberships}, project_id) do
    Map.get(memberships, project_id)
  end

  def project_role(nil, _project_id), do: nil

  @doc """
  The ids of the projects the caller is a member of. Callers must check
  `admin?/1` first — an admin's list is empty because admins see everything.
  """
  @spec project_ids(t()) :: [pos_integer()]
  def project_ids(%__MODULE__{memberships: memberships}), do: Map.keys(memberships)

  @doc """
  The ids of the projects the caller maintains, or nil for admins (all of
  them) — the filter shape `Agents.list_agents_for_settings/1` takes.
  """
  @spec maintained_project_ids(t()) :: [pos_integer()] | nil
  def maintained_project_ids(%__MODULE__{role: :admin}), do: nil

  def maintained_project_ids(%__MODULE__{memberships: memberships}) do
    for {id, :maintainer} <- memberships, do: id
  end
end

defmodule CodeLead.Accounts.Policy do
  @moduledoc """
  The single authorization seam. Every permission question in the app is one
  of the flat actions below, answered from the `Scope` — the counterpart of
  `@gated_features` in `CodeLead.License`.

  Two layers: instance-wide actions require the `:admin` role; project-keyed
  actions compare the caller's project role against a required minimum
  through an ordered rank map (`reporter < member < maintainer`), so a new
  role slots in without touching the checks. Admins act as `:maintainer` on
  every project (see `Scope.project_role/2`).

  Contexts enforce with `authorize/3` at the boundary; the UI hides what the
  context would refuse with `can?/3` — never the other way around.
  """

  alias CodeLead.Accounts.Scope
  alias CodeLead.Accounts.User
  alias CodeLead.Projects.Project
  alias CodeLead.Tasks.Task

  @role_rank %{reporter: 0, member: 1, maintainer: 2}

  @admin_actions [
    :manage_users,
    :manage_providers,
    :manage_organization,
    :manage_org_agents,
    :manage_license,
    :set_project_budget
  ]

  # Task-subject actions where a reporter's rights depend on ownership and
  # column; these must receive the full %Task{}.
  @own_task_actions [:edit_task, :delete_task, :run_planning]

  @type action ::
          :manage_users
          | :manage_providers
          | :manage_organization
          | :manage_org_agents
          | :manage_license
          | :set_project_budget
          | :create_project
          | :view_project
          | :create_task
          | :edit_task
          | :delete_task
          | :run_planning
          | :operate_task
          | :manage_project
          | :delete_project

  @doc """
  Whether the scope may perform the action on the subject.

  Project-keyed actions accept a `%Project{}`, a `%Task{}`, or a bare
  project id as subject — except `:edit_task`, `:delete_task` and
  `:run_planning`, which need the full `%Task{}` for the reporter
  own-task-in-planning rule.
  """
  @spec can?(Scope.t() | nil, action(), term()) :: boolean()
  def can?(scope, action, subject \\ nil)

  def can?(nil, _action, _subject), do: false
  def can?(%Scope{user: nil}, _action, _subject), do: false

  def can?(%Scope{} = scope, action, _subject) when action in @admin_actions do
    Scope.admin?(scope)
  end

  def can?(%Scope{user: %User{}}, :create_project, _subject), do: true

  def can?(%Scope{} = scope, action, %Task{} = task) when action in @own_task_actions do
    case Scope.project_role(scope, task.project_id) do
      nil -> false
      :reporter -> own_task?(scope, task) and task.state == :planning
      role -> at_least?(role, :member)
    end
  end

  def can?(%Scope{} = scope, :view_project, subject), do: has_role?(scope, subject, :reporter)
  def can?(%Scope{} = scope, :create_task, subject), do: has_role?(scope, subject, :reporter)
  def can?(%Scope{} = scope, :operate_task, subject), do: has_role?(scope, subject, :member)
  def can?(%Scope{} = scope, :manage_project, subject), do: has_role?(scope, subject, :maintainer)
  def can?(%Scope{} = scope, :delete_project, subject), do: has_role?(scope, subject, :maintainer)

  @doc """
  `can?/3` as an `:ok`/`{:error, :unauthorized}` for `with` chains at
  context boundaries.
  """
  @spec authorize(Scope.t() | nil, action(), term()) :: :ok | {:error, :unauthorized}
  def authorize(scope, action, subject \\ nil) do
    if can?(scope, action, subject), do: :ok, else: {:error, :unauthorized}
  end

  defp has_role?(scope, subject, required) do
    case Scope.project_role(scope, project_id_of(subject)) do
      nil -> false
      role -> at_least?(role, required)
    end
  end

  defp at_least?(role, required), do: @role_rank[role] >= @role_rank[required]

  defp project_id_of(%Project{id: id}), do: id
  defp project_id_of(%Task{project_id: id}), do: id
  defp project_id_of(id) when is_integer(id), do: id

  defp own_task?(%Scope{user: %User{id: user_id}}, %Task{created_by_id: user_id})
       when not is_nil(user_id),
       do: true

  defp own_task?(_scope, _task), do: false
end

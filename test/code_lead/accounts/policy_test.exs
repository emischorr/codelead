defmodule CodeLead.Accounts.PolicyTest do
  use ExUnit.Case, async: true

  alias CodeLead.Accounts.Policy
  alias CodeLead.Accounts.Scope
  alias CodeLead.Accounts.User
  alias CodeLead.Projects.Project
  alias CodeLead.Tasks.Task

  @project_id 10
  @other_project_id 99

  defp scope(:none), do: nil
  defp scope(:userless), do: %Scope{}
  defp scope(:admin), do: %Scope{user: %User{id: 1, role: :admin}, role: :admin}

  defp scope(:non_member),
    do: %Scope{user: %User{id: 2, role: :member}, role: :member, memberships: %{}}

  defp scope(project_role),
    do: %Scope{
      user: %User{id: 3, role: :member},
      role: :member,
      memberships: %{@project_id => project_role}
    }

  defp task(attrs \\ []) do
    struct!(%Task{project_id: @project_id, state: :planning}, attrs)
  end

  describe "admin actions" do
    @admin_actions [
      :manage_users,
      :manage_providers,
      :manage_organization,
      :manage_org_agents,
      :manage_license,
      :set_project_budget
    ]

    test "only admins pass" do
      for action <- @admin_actions do
        assert Policy.can?(scope(:admin), action)

        for who <- [:none, :userless, :non_member, :reporter, :member, :maintainer] do
          refute Policy.can?(scope(who), action), "#{who} must not #{action}"
        end
      end
    end
  end

  describe "create_project" do
    test "any signed-in user may, nobody else" do
      assert Policy.can?(scope(:admin), :create_project)
      assert Policy.can?(scope(:non_member), :create_project)
      refute Policy.can?(scope(:none), :create_project)
      refute Policy.can?(scope(:userless), :create_project)
    end
  end

  describe "project-threshold actions" do
    # {action, minimum role that passes}
    @thresholds [
      view_project: :reporter,
      create_task: :reporter,
      operate_task: :member,
      manage_project: :maintainer,
      delete_project: :maintainer
    ]
    @ranked [reporter: 0, member: 1, maintainer: 2]

    test "role >= required passes, below refuses, non-members and nil refuse" do
      for {action, required} <- @thresholds do
        for {role, rank} <- @ranked do
          expected = rank >= @ranked[required]

          assert Policy.can?(scope(role), action, @project_id) == expected,
                 "#{role} on #{action} expected #{expected}"
        end

        assert Policy.can?(scope(:admin), action, @project_id)
        refute Policy.can?(scope(:non_member), action, @project_id)
        refute Policy.can?(scope(:maintainer), action, @other_project_id)
        refute Policy.can?(scope(:none), action, @project_id)
        refute Policy.can?(scope(:userless), action, @project_id)
      end
    end

    test "subject may be a project struct, task struct, or bare id" do
      assert Policy.can?(scope(:member), :operate_task, @project_id)
      assert Policy.can?(scope(:member), :operate_task, %Project{id: @project_id})
      assert Policy.can?(scope(:member), :operate_task, task())
      refute Policy.can?(scope(:member), :operate_task, %Project{id: @other_project_id})
    end
  end

  describe "own-task actions (edit_task/delete_task/run_planning)" do
    @own_actions [:edit_task, :delete_task, :run_planning]

    test "member and above act on any task in any state" do
      for action <- @own_actions, who <- [:member, :maintainer, :admin] do
        assert Policy.can?(scope(who), action, task(created_by_id: 999, state: :review))
      end
    end

    test "reporter acts only on their own task while it is in planning" do
      reporter = scope(:reporter)
      own_planning = task(created_by_id: reporter.user.id)

      for action <- @own_actions do
        assert Policy.can?(reporter, action, own_planning)

        refute Policy.can?(
                 reporter,
                 action,
                 task(created_by_id: reporter.user.id, state: :running)
               )

        refute Policy.can?(reporter, action, task(created_by_id: 999))
        refute Policy.can?(reporter, action, task(created_by_id: nil)), "nil creator is never own"
      end
    end

    test "non-members, nil and userless scopes refuse" do
      for action <- @own_actions, who <- [:non_member, :none, :userless] do
        refute Policy.can?(scope(who), action, task())
      end
    end
  end

  describe "authorize/3" do
    test "mirrors can?/3 as ok or unauthorized" do
      assert Policy.authorize(scope(:admin), :manage_users) == :ok
      assert Policy.authorize(scope(:member), :manage_users) == {:error, :unauthorized}
      assert Policy.authorize(scope(:member), :operate_task, @project_id) == :ok

      assert Policy.authorize(scope(:reporter), :operate_task, @project_id) ==
               {:error, :unauthorized}
    end
  end
end

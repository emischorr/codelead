defmodule CodeLead.Accounts.MembershipsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AccountsFixtures
  import CodeLead.ProjectsFixtures

  alias CodeLead.Accounts

  setup do
    project = project_fixture()
    maintainer = user_fixture()
    membership_fixture(project, maintainer, :maintainer)
    %{project: project, scope: user_scope_fixture(maintainer)}
  end

  describe "add_project_member/4" do
    test "a maintainer adds a member and their sessions are told", %{
      project: project,
      scope: scope
    } do
      user = user_fixture()
      Accounts.subscribe_user(user.id)

      assert {:ok, membership} = Accounts.add_project_member(scope, project.id, user.id, :member)
      assert membership.role == :member
      assert Accounts.membership_map(user.id) == %{project.id => :member}
      assert_receive {:scope_changed, user_id}
      assert user_id == user.id
    end

    test "a duplicate membership is a changeset error", %{project: project, scope: scope} do
      user = user_fixture()
      {:ok, _} = Accounts.add_project_member(scope, project.id, user.id, :member)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.add_project_member(scope, project.id, user.id, :reporter)
    end

    test "refuses a member of the project", %{project: project, scope: scope} do
      user = user_fixture()
      {:ok, _} = Accounts.add_project_member(scope, project.id, user.id, :member)
      member_scope = user_scope_fixture(user)

      assert {:error, :unauthorized} =
               Accounts.add_project_member(member_scope, project.id, user_fixture().id, :member)
    end

    test "an admin needs no membership", %{project: project} do
      admin_scope = user_scope_fixture(admin_fixture())
      user = user_fixture()

      assert {:ok, _} = Accounts.add_project_member(admin_scope, project.id, user.id, :reporter)
    end
  end

  describe "update_project_member_role/3 and remove_project_member/2" do
    test "role changes and removals notify the affected user", %{
      project: project,
      scope: scope
    } do
      user = user_fixture()
      {:ok, membership} = Accounts.add_project_member(scope, project.id, user.id, :reporter)
      Accounts.subscribe_user(user.id)

      assert {:ok, updated} = Accounts.update_project_member_role(scope, membership, :member)
      assert updated.role == :member
      assert_receive {:scope_changed, _}

      assert {:ok, _} = Accounts.remove_project_member(scope, updated)
      assert Accounts.membership_map(user.id) == %{}
      assert_receive {:scope_changed, _}
    end

    test "refuses non-maintainers", %{project: project, scope: scope} do
      user = user_fixture()
      {:ok, membership} = Accounts.add_project_member(scope, project.id, user.id, :member)
      member_scope = user_scope_fixture(user)

      assert {:error, :unauthorized} =
               Accounts.update_project_member_role(member_scope, membership, :maintainer)

      assert {:error, :unauthorized} = Accounts.remove_project_member(member_scope, membership)
    end
  end

  describe "list_project_members/1 and list_assignable_users/1" do
    test "members are listed with users, assignables include admins", %{
      project: project,
      scope: scope
    } do
      admin = admin_fixture()
      reporter = user_fixture()
      {:ok, _} = Accounts.add_project_member(scope, project.id, reporter.id, :reporter)

      members = Accounts.list_project_members(project.id)

      assert Enum.map(members, & &1.user.id) |> Enum.sort() ==
               Enum.sort([scope.user.id, reporter.id])

      assignable_ids = project.id |> Accounts.list_assignable_users() |> Enum.map(& &1.id)
      assert admin.id in assignable_ids
      assert reporter.id in assignable_ids
      assert scope.user.id in assignable_ids
      refute user_fixture().id in assignable_ids
    end
  end

  describe "cascades" do
    test "deleting the user removes their memberships", %{project: project, scope: scope} do
      user = user_fixture()
      {:ok, _} = Accounts.add_project_member(scope, project.id, user.id, :member)

      admin_scope = user_scope_fixture(admin_fixture())
      {:ok, _} = Accounts.delete_user(admin_scope, user)

      assert Accounts.list_project_members(project.id) |> Enum.map(& &1.user_id) ==
               [scope.user.id]
    end
  end
end

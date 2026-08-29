defmodule CodeLead.Accounts.ScopeTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AccountsFixtures
  import CodeLead.ProjectsFixtures

  alias CodeLead.Accounts.Scope

  describe "for_user/1" do
    test "nil stays nil" do
      assert Scope.for_user(nil) == nil
    end

    test "loads role and the membership map for members" do
      user = user_fixture()
      project = project_fixture()
      other = project_fixture(%{name: "other"})
      membership_fixture(project, user, :reporter)
      membership_fixture(other, user, :member)

      scope = Scope.for_user(user)

      assert scope.role == :member
      assert scope.memberships == %{project.id => :reporter, other.id => :member}
      assert Enum.sort(Scope.project_ids(scope)) == Enum.sort([project.id, other.id])
    end

    test "admins skip the membership query and act as maintainer everywhere" do
      admin = admin_fixture()
      project = project_fixture()

      scope = Scope.for_user(admin)

      assert Scope.admin?(scope)
      assert scope.memberships == %{}
      assert Scope.project_role(scope, project.id) == :maintainer
    end
  end

  describe "project_role/2" do
    test "returns the membership role or nil" do
      user = user_fixture()
      project = project_fixture()
      membership_fixture(project, user, :member)
      scope = Scope.for_user(user)

      assert Scope.project_role(scope, project.id) == :member
      assert Scope.project_role(scope, project.id + 1) == nil
      assert Scope.project_role(nil, project.id) == nil
    end
  end

  describe "refresh/1" do
    test "picks up membership and role changes" do
      user = user_fixture()
      project = project_fixture()
      scope = Scope.for_user(user)
      assert Scope.project_role(scope, project.id) == nil

      membership_fixture(project, user, :maintainer)
      refreshed = Scope.refresh(scope)

      assert Scope.project_role(refreshed, project.id) == :maintainer
    end

    test "returns nil when the user is gone" do
      user = user_fixture()
      scope = Scope.for_user(user)
      Repo.delete!(user)

      assert Scope.refresh(scope) == nil
    end
  end
end

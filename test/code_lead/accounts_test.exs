defmodule CodeLead.AccountsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AccountsFixtures

  alias CodeLead.Accounts
  alias CodeLead.Accounts.Organization
  alias CodeLead.Accounts.User

  describe "organization singleton" do
    test "ensure_organization/1 creates it once and returns it afterwards" do
      assert {:ok, %Organization{} = org} = Accounts.ensure_organization(%{name: "Acme"})
      assert org.name == "Acme"
      assert {:ok, %Organization{id: same_id}} = Accounts.ensure_organization(%{name: "Other"})
      assert same_id == org.id
    end

    test "a second organization row is rejected by the database" do
      organization_fixture()

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Organization{name: "Second"})
      end
    end

    test "update_organization/1 changes settings and budgets" do
      organization_fixture()

      assert {:ok, org} =
               Accounts.update_organization(%{
                 settings: %{"setup_done" => true},
                 budget_limit_cents: 5000
               })

      assert org.settings["setup_done"] == true
      assert org.budget_limit_cents == 5000
    end

    test "negative budgets are rejected" do
      organization_fixture()
      assert {:error, changeset} = Accounts.update_organization(%{budget_limit_cents: -1})
      assert %{budget_limit_cents: _} = errors_on(changeset)
    end
  end

  describe "users" do
    test "create_user/1 with valid email" do
      assert {:ok, %User{role: :member}} = Accounts.create_user(%{email: "a@b.de"})
    end

    test "create_user/1 rejects malformed email" do
      assert {:error, changeset} = Accounts.create_user(%{email: "not an email"})
      assert %{email: _} = errors_on(changeset)
    end

    test "emails are unique" do
      user = user_fixture()
      assert {:error, changeset} = Accounts.create_user(%{email: user.email})
      assert %{email: _} = errors_on(changeset)
    end

    test "get_user_by_email/1 finds the user" do
      user = user_fixture()
      assert Accounts.get_user_by_email(user.email).id == user.id
      assert Accounts.get_user_by_email("missing@example.com") == nil
    end
  end
end

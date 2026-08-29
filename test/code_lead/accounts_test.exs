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

  describe "setup flag" do
    test "setup_done?/0 is false without an organization" do
      refute Accounts.setup_done?()
    end

    test "setup_done?/0 is false while the flag is unset" do
      organization_fixture(%{settings: %{}})
      refute Accounts.setup_done?()
    end

    test "complete_setup/0 flips the flag without dropping other settings" do
      organization_fixture(%{settings: %{"max_concurrent_runs" => 4}})

      assert {:ok, org} = Accounts.complete_setup()
      assert org.settings["setup_done"] == true
      assert org.settings["max_concurrent_runs"] == 4
      assert Accounts.setup_done?()
    end
  end

  describe "register_admin/1" do
    test "creates a confirmed admin with a password and no email" do
      assert {:ok, user} =
               Accounts.register_admin(%{
                 username: "admin",
                 password: "a-very-long-password"
               })

      assert user.role == :admin
      assert %DateTime{} = user.confirmed_at
      refute user.email
      assert Accounts.get_user_by_username_and_password("admin", "a-very-long-password")
    end

    test "rejects a short password" do
      assert {:error, changeset} =
               Accounts.register_admin(%{username: "admin", password: "short"})

      assert %{password: _} = errors_on(changeset)
    end

    test "rejects a missing username" do
      assert {:error, changeset} =
               Accounts.register_admin(%{password: "a-very-long-password"})

      assert %{username: _} = errors_on(changeset)
    end

    test "refuses once any user exists" do
      user_fixture()

      assert {:error, :already_registered} =
               Accounts.register_admin(%{
                 username: "admin",
                 password: "a-very-long-password"
               })
    end
  end

  describe "users" do
    setup do
      %{scope: user_scope_fixture(admin_fixture())}
    end

    test "create_user/2 with just a username", %{scope: scope} do
      assert {:ok, %User{role: :member} = user} = Accounts.create_user(scope, %{username: "abe"})
      refute user.email
    end

    test "create_user/2 requires a username", %{scope: scope} do
      assert {:error, changeset} = Accounts.create_user(scope, %{email: "a@b.de"})
      assert %{username: _} = errors_on(changeset)
    end

    test "create_user/2 refuses a non-admin caller" do
      member_scope = user_scope_fixture(user_fixture())

      assert {:error, :unauthorized} = Accounts.create_user(member_scope, %{username: "abe"})
      assert {:error, :unauthorized} = Accounts.create_user(nil, %{username: "abe"})
    end

    test "create_user/2 rejects malformed email", %{scope: scope} do
      assert {:error, changeset} =
               Accounts.create_user(scope, %{username: "abe", email: "not an email"})

      assert %{email: _} = errors_on(changeset)
    end

    test "create_user/2 accepts a blank email as no email at all", %{scope: scope} do
      assert {:ok, user} = Accounts.create_user(scope, %{username: "abe", email: ""})
      assert is_nil(user.email)
    end

    test "usernames are unique", %{scope: scope} do
      user = user_fixture()
      assert {:error, changeset} = Accounts.create_user(scope, %{username: user.username})
      assert %{username: _} = errors_on(changeset)
    end

    test "emails are unique when present", %{scope: scope} do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.create_user(scope, %{username: "another", email: user.email})

      assert %{email: _} = errors_on(changeset)
    end

    test "two users can both have no email", %{scope: scope} do
      assert {:ok, _} = Accounts.create_user(scope, %{username: "abe"})
      assert {:ok, _} = Accounts.create_user(scope, %{username: "bea"})
    end

    test "get_user_by_email/1 finds the user" do
      user = user_fixture()
      assert Accounts.get_user_by_email(user.email).id == user.id
      assert Accounts.get_user_by_email("missing@example.com") == nil
    end

    test "get_user_by_username/1 finds the user" do
      user = user_fixture()
      assert Accounts.get_user_by_username(user.username).id == user.id
      assert Accounts.get_user_by_username("missing") == nil
    end

    test "create_user/2 with a password sets the hash and confirms the account", %{scope: scope} do
      assert {:ok, user} =
               Accounts.create_user(scope, %{username: "abe", password: "hello world!123"})

      assert user.confirmed_at
      assert User.valid_password?(user, "hello world!123")
    end

    # `login_user_by_magic_link/1` raises for an unconfirmed user that has a
    # password, so the confirm on the password path is load-bearing.
    test "create_user/2 with a password still allows a later magic-link login", %{scope: scope} do
      {:ok, user} =
        Accounts.create_user(scope, %{
          username: "abe",
          email: "pw@b.de",
          password: "hello world!123"
        })

      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      assert {:ok, {logged_in, _tokens}} = Accounts.login_user_by_magic_link(token)
      assert logged_in.id == user.id
    end

    test "create_user/2 without a password leaves the invite path open", %{scope: scope} do
      assert {:ok, user} = Accounts.create_user(scope, %{username: "abe", email: "invite@b.de"})

      refute user.hashed_password
      refute user.confirmed_at
    end

    test "create_user/2 rejects a password under 12 characters", %{scope: scope} do
      assert {:error, changeset} =
               Accounts.create_user(scope, %{username: "abe", password: "short"})

      assert %{password: _} = errors_on(changeset)
    end

    test "change_user/3 only validates the password when asked to" do
      refute Map.has_key?(errors_on(Accounts.change_user(%User{}, %{})), :password)

      assert %{password: _} =
               errors_on(Accounts.change_user(%User{}, %{}, with_password: true))
    end

    test "delete_user/2 removes the user when another one remains", %{scope: scope} do
      doomed = user_fixture()

      assert {:ok, _user} = Accounts.delete_user(scope, doomed)
      refute Accounts.get_user_by_email(doomed.email)
    end

    test "delete_user/2 refuses the last user", %{scope: scope} do
      assert {:error, :last_user} = Accounts.delete_user(scope, scope.user)
      assert Accounts.get_user_by_email(scope.user.email)
    end

    test "delete_user/2 refuses the last admin", %{scope: scope} do
      _member = user_fixture()

      assert {:error, :last_admin} = Accounts.delete_user(scope, scope.user)
      assert Accounts.get_user_by_email(scope.user.email)
    end

    test "delete_user/2 refuses a non-admin caller", %{scope: scope} do
      member = user_fixture()
      member_scope = user_scope_fixture(member)

      assert {:error, :unauthorized} = Accounts.delete_user(member_scope, scope.user)
    end
  end

  describe "update_user_role/3" do
    setup do
      %{scope: user_scope_fixture(admin_fixture())}
    end

    test "promotes and demotes when another admin remains", %{scope: scope} do
      member = user_fixture()

      assert {:ok, %User{role: :admin} = promoted} =
               Accounts.update_user_role(scope, member, :admin)

      assert {:ok, %User{role: :member}} = Accounts.update_user_role(scope, promoted, :member)
    end

    test "refuses to demote the last admin", %{scope: scope} do
      assert {:error, :last_admin} = Accounts.update_user_role(scope, scope.user, :member)
      assert Accounts.get_user!(scope.user.id).role == :admin
    end

    test "keeping an admin an admin is not a demotion", %{scope: scope} do
      assert {:ok, %User{role: :admin}} = Accounts.update_user_role(scope, scope.user, :admin)
    end

    test "refuses a non-admin caller", %{scope: scope} do
      member = user_fixture()
      member_scope = user_scope_fixture(member)

      assert {:error, :unauthorized} = Accounts.update_user_role(member_scope, member, :admin)
      assert Accounts.get_user!(scope.user.id).role == :admin
    end

    test "broadcasts a scope change to the affected user", %{scope: scope} do
      member = user_fixture()
      Accounts.subscribe_user(member.id)

      {:ok, _} = Accounts.update_user_role(scope, member, :admin)

      assert_receive {:scope_changed, user_id}
      assert user_id == member.id
    end
  end

  import CodeLead.AccountsFixtures
  alias CodeLead.Accounts.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_username_and_password/2" do
    test "does not return the user if the username does not exist" do
      refute Accounts.get_user_by_username_and_password("unknown", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_username_and_password(user.username, "invalid")
    end

    test "returns the user if the username and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_username_and_password(user.username, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires username to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{username: ["can't be blank"]} = errors_on(changeset)
    end

    test "does not require an email" do
      {:ok, user} = Accounts.register_user(%{username: unique_username()})
      refute user.email
    end

    test "validates email when given" do
      {:error, changeset} =
        Accounts.register_user(%{username: unique_username(), email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.register_user(%{username: unique_username(), email: too_long})

      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{username: unique_username(), email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} =
        Accounts.register_user(%{username: unique_username(), email: String.upcase(email)})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "validates username uniqueness" do
      %{username: username} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{username: username})
      assert "has already been taken" in errors_on(changeset).username
    end

    test "registers users without password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_username_and_password(user.username, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token, hashed_token: hashed_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end

    # The invite context is verified by the same query against a much longer
    # window; a login token must not inherit it.
    test "does not return user for a login token past 15 minutes", %{
      token: token,
      hashed_token: hashed_token
    } do
      offset_user_token(hashed_token, -20, :minute)
      refute Accounts.get_user_by_magic_link_token(token)
    end

    test "returns user for an invite token within 72 hours" do
      user = unconfirmed_user_fixture()
      {token, hashed_token} = generate_user_invite_token(user)
      offset_user_token(hashed_token, -71, :hour)

      assert invited_user = Accounts.get_user_by_magic_link_token(token)
      assert invited_user.id == user.id
    end

    test "does not return user for an invite token past 72 hours" do
      user = unconfirmed_user_fixture()
      {token, hashed_token} = generate_user_invite_token(user)
      offset_user_token(hashed_token, -73, :hour)

      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "confirms user through an invite token" do
      user = unconfirmed_user_fixture()
      {encoded_token, hashed_token} = generate_user_invite_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "deliver_invite_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends an invite token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_invite_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "invite"
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end
end

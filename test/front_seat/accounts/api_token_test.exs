defmodule FrontSeat.Accounts.ApiTokenTest do
  use FrontSeat.DataCase, async: true

  import FrontSeat.AccountsFixtures

  alias FrontSeat.Accounts
  alias FrontSeat.Accounts.ApiToken
  alias FrontSeat.Accounts.Scope
  alias FrontSeat.Repo

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user)}
  end

  describe "create_api_token/2" do
    test "returns a prefixed plaintext once and stores only its hash", %{scope: scope} do
      assert {:ok, "fs_pat_" <> _ = plaintext, token} =
               Accounts.create_api_token(scope, %{"name" => "claude-code laptop"})

      stored = Repo.get!(ApiToken, token.id)
      assert stored.name == "claude-code laptop"
      assert stored.token_hash == :crypto.hash(:sha256, plaintext)
      refute stored.token_hash == plaintext

      # The plaintext appears in no column of the row.
      row = Repo.query!("SELECT * FROM api_tokens WHERE id = $1", [token.id])
      refute Enum.any?(hd(row.rows), &(&1 == plaintext))
    end

    test "requires a name", %{scope: scope} do
      assert {:error, changeset} = Accounts.create_api_token(scope, %{"name" => "  "})
      assert "can't be blank" in errors_on(changeset).name
      assert Repo.aggregate(ApiToken, :count) == 0
    end

    test "sets an expiry from a day count", %{scope: scope} do
      {:ok, _plaintext, token} =
        Accounts.create_api_token(scope, %{"name" => "ci", "expires_in_days" => "30"})

      assert_in_delta DateTime.diff(token.expires_at, DateTime.utc_now(), :day), 30, 1
    end

    test "rejects an expiry outside the offered choices or in the past", %{scope: scope} do
      assert {:error, changeset} =
               Accounts.create_api_token(scope, %{"name" => "x", "expires_in_days" => "3"})

      assert errors_on(changeset).expires_in_days

      past = DateTime.add(DateTime.utc_now(:second), -60)

      assert {:error, changeset} =
               Accounts.create_api_token(scope, %{"name" => "x", "expires_at" => past})

      assert "must be in the future" in errors_on(changeset).expires_at
    end

    test "without an expiry the token never expires", %{scope: scope} do
      {:ok, _plaintext, token} = Accounts.create_api_token(scope, %{"name" => "forever"})
      assert token.expires_at == nil
    end
  end

  describe "fetch_api_token/1" do
    test "resolves a valid token to its user", %{user: user} do
      {plaintext, token} = api_token_fixture(user)
      assert {:ok, fetched_user, fetched_token} = Accounts.fetch_api_token(plaintext)
      assert fetched_user.id == user.id
      assert fetched_token.id == token.id
    end

    test "refuses malformed, unknown and expired tokens", %{user: user} do
      {plaintext, _token} = api_token_fixture(user)
      {expired, _token} = api_token_fixture(user, expires_at: past())

      assert Accounts.fetch_api_token("not-a-token") == :error
      assert Accounts.fetch_api_token("fs_pat_") == :error
      assert Accounts.fetch_api_token(plaintext <> "x") == :error
      assert Accounts.fetch_api_token(expired) == :error
    end

    test "a not-yet-expired token still works", %{user: user} do
      {plaintext, _token} = api_token_fixture(user, expires_at: future())
      assert {:ok, _user, _token} = Accounts.fetch_api_token(plaintext)
    end
  end

  describe "list_api_tokens/1 and delete_api_token/2" do
    test "users only see and revoke their own tokens", %{user: user, scope: scope} do
      other = user_fixture()
      {_plaintext, own} = api_token_fixture(user)
      {other_plaintext, others} = api_token_fixture(other)

      assert [%{id: id}] = Accounts.list_api_tokens(scope)
      assert id == own.id

      assert Accounts.delete_api_token(scope, others.id) == {:error, :not_found}
      assert {:ok, _user, _token} = Accounts.fetch_api_token(other_plaintext)
    end

    test "revoking takes effect immediately", %{user: user, scope: scope} do
      {plaintext, token} = api_token_fixture(user)
      assert :ok = Accounts.delete_api_token(scope, token.id)
      assert Accounts.fetch_api_token(plaintext) == :error
      assert Accounts.list_api_tokens(scope) == []
    end

    test "expired tokens stay listed so they can be removed", %{user: user, scope: scope} do
      {_plaintext, token} = api_token_fixture(user, expires_at: past())
      assert [%{id: id}] = Accounts.list_api_tokens(scope)
      assert id == token.id
    end
  end

  describe "lifecycle" do
    test "deleting the user deletes their tokens", %{user: user} do
      {plaintext, token} = api_token_fixture(user)
      Repo.delete!(user)

      refute Repo.get(ApiToken, token.id)
      assert Accounts.fetch_api_token(plaintext) == :error
    end

    test "a password change does not revoke tokens", %{user: user} do
      {plaintext, _token} = api_token_fixture(user)

      {:ok, {_user, _expired}} =
        Accounts.update_user_password(user, %{password: "a brand new password"})

      assert {:ok, _user, _token} = Accounts.fetch_api_token(plaintext)
    end
  end

  describe "touch_api_token/1" do
    test "stamps last_used_at, then holds off writing within the window", %{user: user} do
      {_plaintext, token} = api_token_fixture(user)

      :ok = Accounts.touch_api_token(token)
      first = Repo.get!(ApiToken, token.id).last_used_at
      assert first

      recent = DateTime.add(DateTime.utc_now(:second), -60)
      Repo.update!(Ecto.Changeset.change(token, last_used_at: recent))
      :ok = Accounts.touch_api_token(token)
      assert Repo.get!(ApiToken, token.id).last_used_at == recent

      stale = DateTime.add(DateTime.utc_now(:second), -600)
      Repo.update!(Ecto.Changeset.change(token, last_used_at: stale))
      :ok = Accounts.touch_api_token(token)
      assert DateTime.after?(Repo.get!(ApiToken, token.id).last_used_at, stale)
    end
  end

  defp past, do: DateTime.add(DateTime.utc_now(:second), -3600)
  defp future, do: DateTime.add(DateTime.utc_now(:second), 3600)
end

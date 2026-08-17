defmodule CodeLead.AccountsMailDisabledTest do
  @moduledoc """
  The authoritative half of the mail switch: hiding the buttons is cosmetic, so
  the delivery functions refuse before minting a token. A hand-crafted request
  must not leave an unusable `users_tokens` row behind.
  """

  # Toggles application env, which is VM-global.
  use CodeLead.DataCase, async: false

  import CodeLead.AccountsFixtures
  import CodeLead.MailHelpers

  alias CodeLead.Accounts
  alias CodeLead.Accounts.UserToken

  setup do
    user = unconfirmed_user_fixture()
    disable_mail!()
    %{user: user}
  end

  test "deliver_login_instructions/2 refuses and mints no token", %{user: user} do
    assert {:error, :mail_disabled} =
             Accounts.deliver_login_instructions(user, &"http://localhost/#{&1}")

    assert Repo.get_by(UserToken, user_id: user.id, context: "login") == nil
  end

  test "deliver_invite_instructions/2 refuses and mints no token", %{user: user} do
    assert {:error, :mail_disabled} =
             Accounts.deliver_invite_instructions(user, &"http://localhost/#{&1}")

    assert Repo.get_by(UserToken, user_id: user.id, context: "invite") == nil
  end
end

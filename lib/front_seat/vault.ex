defmodule FrontSeat.Vault do
  @moduledoc """
  Cloak vault for all encrypted-at-rest data (provider credentials,
  project env store). Ciphers are configured in `config/runtime.exs`
  from the instance `ENCRYPTION_KEY`.
  """

  use Cloak.Vault, otp_app: :front_seat
end

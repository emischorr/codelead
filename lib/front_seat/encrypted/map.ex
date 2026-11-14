defmodule FrontSeat.Encrypted.Map do
  @moduledoc """
  Ecto type for encrypted-at-rest map fields (e.g. provider config).
  """

  use Cloak.Ecto.Map, vault: FrontSeat.Vault
end

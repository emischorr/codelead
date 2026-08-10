defmodule CodeLead.Encrypted.Map do
  @moduledoc """
  Ecto type for encrypted-at-rest map fields (e.g. provider config).
  """

  use Cloak.Ecto.Map, vault: CodeLead.Vault
end

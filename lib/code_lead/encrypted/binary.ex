defmodule CodeLead.Encrypted.Binary do
  @moduledoc """
  Ecto type for encrypted-at-rest string fields (e.g. project env values).
  """

  use Cloak.Ecto.Binary, vault: CodeLead.Vault
end

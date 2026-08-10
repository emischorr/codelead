defmodule CodeLead.Repo do
  use Ecto.Repo,
    otp_app: :code_lead,
    adapter: Ecto.Adapters.Postgres
end

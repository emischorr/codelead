defmodule FrontSeat.Repo do
  use Ecto.Repo,
    otp_app: :front_seat,
    adapter: Ecto.Adapters.Postgres
end

# Seeds the organization singleton and an admin user. Idempotent —
# safe to run repeatedly (mix ecto.setup / ecto.reset run it).
#
#     mix run priv/repo/seeds.exs

alias CodeLead.Accounts

{:ok, organization} =
  Accounts.ensure_organization(%{
    name: "CodeLead",
    settings: %{"setup_done" => true}
  })

admin =
  case Accounts.get_user_by_email("admin@example.com") do
    nil ->
      {:ok, user} = Accounts.create_user(%{email: "admin@example.com", role: :admin})
      user

    user ->
      user
  end

IO.puts(
  "Seeded organization ##{organization.id} (#{organization.name}), admin ##{admin.id} (#{admin.email})"
)

defmodule CodeLeadWeb.SetupController do
  @moduledoc """
  The one step of the setup wizard that cannot live in the LiveView: creating
  the admin has to write a session, so `SetupLive` validates the form and then
  lets the browser POST it here.
  """

  use CodeLeadWeb, :controller

  alias CodeLead.Accounts
  alias CodeLeadWeb.UserAuth

  @default_organization_name "CodeLead"

  def create_admin(conn, %{"user" => user_params} = params) do
    organization_name = organization_name(params)

    # The wizard owns the organization name until setup completes, so a retry
    # after a rejected password still applies the name the user typed.
    with {:ok, _created} <- Accounts.ensure_organization(%{name: organization_name}),
         {:ok, _renamed} <- Accounts.update_organization(%{name: organization_name}),
         {:ok, user} <- Accounts.register_admin(user_params) do
      conn
      |> put_session(:user_return_to, ~p"/setup")
      |> UserAuth.log_in_user(user)
    else
      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: ~p"/setup")
    end
  end

  defp organization_name(params) do
    case params |> get_in(["organization", "name"]) |> to_string() |> String.trim() do
      "" -> @default_organization_name
      name -> name
    end
  end

  defp error_message(:already_registered), do: "An admin already exists on this instance."

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&CodeLeadWeb.CoreComponents.translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end
end

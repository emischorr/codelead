defmodule CodeLead.Accounts do
  @moduledoc """
  The organization singleton and its users.
  """

  import Ecto.Query

  alias CodeLead.Accounts.Organization
  alias CodeLead.Accounts.User
  alias CodeLead.Repo

  @doc """
  Fetches the organization singleton. Raises if the instance has not
  been seeded yet.
  """
  @spec get_organization!() :: Organization.t()
  def get_organization! do
    Repo.one!(Organization)
  end

  @doc """
  Creates the organization if it does not exist yet, otherwise returns
  the existing one. Used by seeds and the future setup wizard.
  """
  @spec ensure_organization(map()) :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def ensure_organization(attrs) do
    case Repo.one(Organization) do
      nil -> %Organization{} |> Organization.changeset(attrs) |> Repo.insert()
      organization -> {:ok, organization}
    end
  end

  @doc """
  Updates organization settings or budget limits.
  """
  @spec update_organization(map()) :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def update_organization(attrs) do
    get_organization!()
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  @spec list_users() :: [User.t()]
  def list_users do
    Repo.all(from u in User, order_by: u.email)
  end

  @spec get_user!(pos_integer()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email), do: Repo.get_by(User, email: email)

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end
end

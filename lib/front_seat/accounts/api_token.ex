defmodule FrontSeat.Accounts.ApiToken do
  @moduledoc """
  A personal access token: a bearer credential that authenticates `/api`
  requests as its owning user, with that user's full `Scope` (ADR-0017).

  Only a SHA-256 hash of the token is stored. The plaintext, prefixed
  `fs_pat_` so secret scanners and `grep` recognize it, exists only in the
  return value of `build/0` and is shown to the user exactly once.

  Deliberately a table of its own rather than a `users_tokens` context:
  that table's rows are wiped wholesale on every password change and
  magic-link login, which must not revoke API credentials.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @prefix "fs_pat_"
  @rand_size 32
  @name_max 80
  @expiry_days [7, 30, 90, 365]

  @type t :: %__MODULE__{}

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :expires_in_days, :integer, virtual: true
    belongs_to :user, FrontSeat.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The prefix every plaintext token starts with."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  Mints a fresh token: the plaintext to hand to the user once, and the
  hash to store.
  """
  @spec build() :: {String.t(), binary()}
  def build do
    plaintext =
      @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@rand_size), padding: false)

    {plaintext, hash(plaintext)}
  end

  @doc """
  The stored form of a plaintext token, or `:error` when it does not carry
  the prefix — such a string was never issued here.
  """
  @spec hash_plaintext(String.t()) :: {:ok, binary()} | :error
  def hash_plaintext(@prefix <> rest = plaintext) when byte_size(rest) > 0,
    do: {:ok, hash(plaintext)}

  def hash_plaintext(_plaintext), do: :error

  @doc "The expiry choices the creation form offers, in days."
  @spec expiry_days() :: [pos_integer()]
  def expiry_days, do: @expiry_days

  @doc """
  Changeset for creating a token. `user_id` and `token_hash` are set by
  the context, never cast. Expiry comes either as an absolute
  `expires_at` or as `expires_in_days` (one of `expiry_days/0`), which
  wins; neither means the token never expires.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :expires_at, :expires_in_days])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @name_max)
    |> validate_inclusion(:expires_in_days, @expiry_days)
    |> put_expiry_from_days()
    |> validate_future(:expires_at)
    |> unique_constraint(:token_hash)
  end

  defp put_expiry_from_days(%{valid?: true} = changeset) do
    case get_change(changeset, :expires_in_days) do
      nil ->
        changeset

      days ->
        expires_at = DateTime.utc_now(:second) |> DateTime.add(days, :day)
        put_change(changeset, :expires_at, expires_at)
    end
  end

  defp put_expiry_from_days(changeset), do: changeset

  defp validate_future(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if DateTime.after?(value, DateTime.utc_now()),
        do: [],
        else: [{field, "must be in the future"}]
    end)
  end

  defp hash(plaintext), do: :crypto.hash(:sha256, plaintext)
end

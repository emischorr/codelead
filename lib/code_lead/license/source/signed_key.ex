defmodule CodeLead.License.Source.SignedKey do
  @moduledoc """
  Offline Ed25519 license keys. No network, ever.

  A key is two unpadded base64url parts joined by a dot:

      b64url(payload) <> "." <> b64url(signature)

  where `payload` is JSON. Every field is optional except `tier`:

      {"tier": "business", "org": "Sibling Corp",
       "features": ["agent_marketplace"],
       "limits": {"max_concurrent_runs": 50},
       "expires_at": "2027-08-13"}

  The signature is verified over the **exact decoded payload bytes**,
  before the JSON is parsed. Re-encoding the parsed map and verifying
  that instead would make validity depend on key order and whitespace —
  the same canonicalization trap JWT has.

  Only after verification do strings become atoms, via
  `String.to_existing_atom/1` with the failure rescued: a signed key is
  trusted input, but dropping names this build does not know keeps a
  newer key usable against an older release and keeps the atom table
  bounded.

  `mint/2` lives here rather than in the Mix task so the round trip is
  testable in-process. It is inert without the private key, which never
  enters this repo.
  """

  @behaviour CodeLead.License.Source

  alias CodeLead.License
  alias CodeLead.License.Entitlements

  require Logger

  # The public half of the instance signing pair. Public by nature —
  # committing it is the point. The private half is held by the vendor.
  @public_key Base.decode64!("3kL6AD4JA3UwgbLyRNB4YemuXDk69qIquGmgkUSa88U=")

  @impl CodeLead.License.Source
  def resolve(token), do: resolve(token, @public_key)

  @doc false
  # Arity-2 so tests can verify against an ephemeral pair. Not exposed
  # through config: an operator-supplied public key would let anyone mint
  # their own grants.
  @spec resolve(term(), binary()) ::
          {:ok, Entitlements.t()} | {:error, CodeLead.License.Source.error()}
  def resolve(token, public_key) when is_binary(token) and is_binary(public_key) do
    with [payload_b64, signature_b64] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, signature} <- Base.url_decode64(signature_b64, padding: false),
         :ok <- verify(payload, signature, public_key),
         {:ok, claims} when is_map(claims) <- Jason.decode(payload),
         :ok <- check_expiry(claims["expires_at"]) do
      {:ok, to_entitlements(claims)}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :malformed}
    end
  end

  def resolve(_token, _public_key), do: {:error, :malformed}

  @doc """
  Signs a claims map into a license key. Dev/vendor side only.
  """
  @spec mint(map(), binary()) :: String.t()
  def mint(claims, private_key) when is_map(claims) and is_binary(private_key) do
    payload =
      claims
      |> Map.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
      |> Jason.encode!()

    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

    encode64(payload) <> "." <> encode64(signature)
  end

  # A public key of the wrong size is a broken build, not a forged key —
  # worth its own reason so the log says something actionable. It would
  # otherwise raise rather than return false.
  defp verify(_payload, _signature, public_key) when byte_size(public_key) != 32,
    do: {:error, :no_public_key}

  defp verify(payload, signature, public_key) do
    if :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
      :ok
    else
      {:error, :bad_signature}
    end
  rescue
    ErlangError -> {:error, :bad_signature}
  end

  defp check_expiry(nil), do: :ok

  defp check_expiry(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, expiry} ->
        if Date.after?(Date.utc_today(), expiry), do: {:error, :expired}, else: :ok

      {:error, _reason} ->
        {:error, :malformed}
    end
  end

  defp check_expiry(_other), do: {:error, :malformed}

  defp to_entitlements(claims) do
    warn_unknown(claims)

    tier = safe_atom(claims["tier"]) || :community

    %{features: features, limits: limits} =
      License.merge_grant(
        tier,
        safe_atoms(claims["features"]),
        atomize_limits(claims["limits"])
      )

    %Entitlements{
      tier: tier,
      org: string_or_nil(claims["org"]),
      features: features,
      limits: limits,
      expires_at: string_or_nil(claims["expires_at"])
    }
  end

  # Dropping names this build does not know is the intended behaviour, but
  # silently is not: a key minted for `business` on an instance that has
  # never heard of that tier would otherwise just report itself as
  # community with no explanation.
  defp warn_unknown(claims) do
    unknown =
      unknown_names(List.wrap(claims["tier"])) ++
        unknown_names(claims["features"]) ++
        unknown_names(claims["limits"] |> maybe_keys())

    case unknown do
      [] -> :ok
      names -> Logger.warning("License names things this build does not know: #{inspect(names)}")
    end
  end

  defp unknown_names(list) when is_list(list),
    do: Enum.filter(list, &(is_binary(&1) and safe_atom(&1) == nil))

  defp unknown_names(_other), do: []

  defp maybe_keys(map) when is_map(map), do: Map.keys(map)
  defp maybe_keys(_other), do: []

  defp safe_atoms(list) when is_list(list),
    do: Enum.flat_map(list, fn name -> List.wrap(safe_atom(name)) end)

  defp safe_atoms(_other), do: []

  defp atomize_limits(map) when is_map(map) do
    for {key, value} <- map, atom = safe_atom(key), atom != nil, into: %{}, do: {atom, value}
  end

  defp atomize_limits(_other), do: %{}

  # Names this build has never compiled are dropped rather than created.
  defp safe_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp safe_atom(_other), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_other), do: nil

  defp encode64(binary), do: Base.url_encode64(binary, padding: false)
end

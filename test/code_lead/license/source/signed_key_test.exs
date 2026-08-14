defmodule CodeLead.License.Source.SignedKeyTest do
  use ExUnit.Case, async: true

  # The forward-compat cases below deliberately name things this build does
  # not know, which warns.
  @moduletag :capture_log

  alias CodeLead.License.Entitlements
  alias CodeLead.License.Source.SignedKey

  # Feature, tier and limit names have to already exist as atoms before a
  # key naming them can resolve — that is the forward-compat rule under
  # test below. Nothing special is needed to arrange that here: every name
  # these tests expect to survive (`:cost_dashboard`, `:sso`,
  # `:agent_marketplace`, `:pro`, `:business`, `:max_concurrent_runs`,
  # `:seats`) appears as a literal in an assertion, which is what brings it
  # into existence when this module compiles. The names expected to be
  # dropped appear only as strings.

  setup do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    %{public_key: public_key, private_key: private_key}
  end

  describe "resolve/2 with a valid key" do
    test "carries tier, org, features and limits", %{
      public_key: public_key,
      private_key: private_key
    } do
      token =
        SignedKey.mint(
          %{
            "tier" => "business",
            "org" => "Sibling Corp",
            "features" => ["agent_marketplace"],
            "limits" => %{"max_concurrent_runs" => 50}
          },
          private_key
        )

      assert {:ok, entitlements} = SignedKey.resolve(token, public_key)

      assert %Entitlements{
               tier: :business,
               org: "Sibling Corp",
               features: [:agent_marketplace],
               limits: %{max_concurrent_runs: 50}
             } = entitlements
    end

    test "a bare key resolves to its tier and nothing else", %{
      public_key: public_key,
      private_key: private_key
    } do
      token = SignedKey.mint(%{"tier" => "pro"}, private_key)

      assert {:ok, %Entitlements{tier: :pro, org: nil, features: [], limits: %{}}} =
               SignedKey.resolve(token, public_key)
    end

    test "two keys resolve to different grants", %{
      public_key: public_key,
      private_key: private_key
    } do
      modest =
        SignedKey.mint(
          %{"tier" => "pro", "features" => ["cost_dashboard"], "limits" => %{"seats" => 5}},
          private_key
        )

      generous =
        SignedKey.mint(
          %{
            "tier" => "business",
            "features" => ["cost_dashboard", "sso"],
            "limits" => %{"seats" => 50}
          },
          private_key
        )

      assert {:ok, %Entitlements{features: [:cost_dashboard], limits: %{seats: 5}}} =
               SignedKey.resolve(modest, public_key)

      assert {:ok, %Entitlements{features: [:cost_dashboard, :sso], limits: %{seats: 50}}} =
               SignedKey.resolve(generous, public_key)
    end
  end

  describe "resolve/2 rejects tampering" do
    test "a swapped payload fails the signature", %{
      public_key: public_key,
      private_key: private_key
    } do
      [_payload, signature] =
        %{"tier" => "pro"}
        |> SignedKey.mint(private_key)
        |> String.split(".", parts: 2)

      forged =
        Base.url_encode64(Jason.encode!(%{"tier" => "business"}), padding: false) <>
          "." <> signature

      assert {:error, :bad_signature} = SignedKey.resolve(forged, public_key)
    end

    test "a mangled signature fails", %{public_key: public_key, private_key: private_key} do
      [payload, signature] =
        %{"tier" => "pro"}
        |> SignedKey.mint(private_key)
        |> String.split(".", parts: 2)

      mangled = payload <> "." <> flip_first_char(signature)

      assert {:error, :bad_signature} = SignedKey.resolve(mangled, public_key)
    end

    test "another pair's key does not verify", %{private_key: private_key} do
      {other_public_key, _other_private_key} = :crypto.generate_key(:eddsa, :ed25519)
      token = SignedKey.mint(%{"tier" => "business"}, private_key)

      assert {:error, :bad_signature} = SignedKey.resolve(token, other_public_key)
    end

    test "a public key of the wrong size reports itself rather than raising", %{
      private_key: private_key
    } do
      token = SignedKey.mint(%{"tier" => "pro"}, private_key)

      assert {:error, :no_public_key} = SignedKey.resolve(token, <<1, 2, 3>>)
    end
  end

  describe "resolve/2 expiry" do
    test "a past date expires", %{public_key: public_key, private_key: private_key} do
      token = expiring_key(Date.add(Date.utc_today(), -1), private_key)

      assert {:error, :expired} = SignedKey.resolve(token, public_key)
    end

    test "today is still valid", %{public_key: public_key, private_key: private_key} do
      token = expiring_key(Date.utc_today(), private_key)

      assert {:ok, %Entitlements{}} = SignedKey.resolve(token, public_key)
    end

    test "a future date is valid and is carried through", %{
      public_key: public_key,
      private_key: private_key
    } do
      expiry = Date.add(Date.utc_today(), 365)
      expected = Date.to_iso8601(expiry)

      assert {:ok, %Entitlements{expires_at: ^expected}} =
               SignedKey.resolve(expiring_key(expiry, private_key), public_key)
    end

    test "an unparseable date is malformed, not perpetual", %{
      public_key: public_key,
      private_key: private_key
    } do
      token = SignedKey.mint(%{"tier" => "pro", "expires_at" => "someday"}, private_key)

      assert {:error, :malformed} = SignedKey.resolve(token, public_key)
    end
  end

  describe "resolve/2 malformed input" do
    test "junk in, error out — never a raise", %{public_key: public_key} do
      for token <- ["", "no-dot-here", "not base64!.also not base64!", "a.b.c"] do
        assert {:error, :malformed} = SignedKey.resolve(token, public_key)
      end
    end

    test "non-binary input", %{public_key: public_key} do
      assert {:error, :malformed} = SignedKey.resolve(nil, public_key)
      assert {:error, :malformed} = SignedKey.resolve(%{tier: :business}, public_key)
    end

    test "a correctly signed payload that is not JSON", %{
      public_key: public_key,
      private_key: private_key
    } do
      assert {:error, :malformed} =
               SignedKey.resolve(sign("this is not json", private_key), public_key)
    end

    test "a correctly signed payload that is JSON but not an object", %{
      public_key: public_key,
      private_key: private_key
    } do
      assert {:error, :malformed} = SignedKey.resolve(sign("[1, 2, 3]", private_key), public_key)
    end
  end

  describe "resolve/2 forward compatibility" do
    test "features this build does not know are dropped, known ones survive", %{
      public_key: public_key,
      private_key: private_key
    } do
      token =
        SignedKey.mint(
          %{"tier" => "pro", "features" => ["sso", "warp_drive_from_a_later_release"]},
          private_key
        )

      assert {:ok, %Entitlements{features: [:sso]}} = SignedKey.resolve(token, public_key)
    end

    test "limits this build does not know are dropped", %{
      public_key: public_key,
      private_key: private_key
    } do
      token =
        SignedKey.mint(
          %{"tier" => "pro", "limits" => %{"seats" => 9, "quantum_cores_from_later" => 4}},
          private_key
        )

      assert {:ok, %Entitlements{limits: %{seats: 9}}} = SignedKey.resolve(token, public_key)
    end

    test "an unrecognised tier name falls back to community, keeping explicit grants", %{
      public_key: public_key,
      private_key: private_key
    } do
      token =
        SignedKey.mint(
          %{"tier" => "platinum_from_a_later_release", "features" => ["sso"]},
          private_key
        )

      assert {:ok, %Entitlements{tier: :community, features: [:sso]}} =
               SignedKey.resolve(token, public_key)
    end

    test "a known tier with no baseline keeps its label and grants only what the key says", %{
      public_key: public_key,
      private_key: private_key
    } do
      # `:pro` exists as an atom but `tier_baseline/1` has no clause for it
      # yet, so it grants nothing on its own.
      token = SignedKey.mint(%{"tier" => "pro", "features" => ["sso"]}, private_key)

      assert {:ok, %Entitlements{tier: :pro, features: [:sso]}} =
               SignedKey.resolve(token, public_key)
    end
  end

  describe "resolve/1" do
    test "uses the compiled-in public key, so a foreign key does not verify" do
      {_public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      assert {:error, :bad_signature} =
               SignedKey.resolve(SignedKey.mint(%{"tier" => "business"}, private_key))
    end
  end

  describe "mint/2" do
    test "omits empty fields rather than minting nulls", %{
      public_key: public_key,
      private_key: private_key
    } do
      token =
        SignedKey.mint(
          %{
            "tier" => "pro",
            "org" => nil,
            "features" => [],
            "limits" => %{},
            "expires_at" => nil
          },
          private_key
        )

      assert {:ok, %Entitlements{org: nil, expires_at: nil}} =
               SignedKey.resolve(token, public_key)

      assert payload(token) == %{"tier" => "pro"}
    end
  end

  defp expiring_key(date, private_key) do
    SignedKey.mint(%{"tier" => "pro", "expires_at" => Date.to_iso8601(date)}, private_key)
  end

  defp sign(payload, private_key) do
    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

    Base.url_encode64(payload, padding: false) <>
      "." <> Base.url_encode64(signature, padding: false)
  end

  defp payload(token) do
    [payload, _signature] = String.split(token, ".", parts: 2)

    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp flip_first_char(<<first::binary-size(1), rest::binary>>) do
    replacement = if first == "A", do: "B", else: "A"
    replacement <> rest
  end
end

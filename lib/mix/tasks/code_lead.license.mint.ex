defmodule Mix.Tasks.CodeLead.License.Mint do
  @shortdoc "Mints a signed license key (vendor side; needs LICENSE_SIGNING_KEY)"

  @moduledoc """
  Signs a license payload and prints the resulting key.

  Vendor-side only — it needs the private half of the instance signing
  pair, which is not in this repo. Supply it base64-encoded in
  `LICENSE_SIGNING_KEY`.

      LICENSE_SIGNING_KEY=... mix code_lead.license.mint \\
        --org "Sibling Corp" --tier business --expires 2027-08-13

      LICENSE_SIGNING_KEY=... mix code_lead.license.mint \\
        --org "Custom Deal" --tier pro \\
        --features container_execution_env --limits max_concurrent_runs=50

      LICENSE_SIGNING_KEY=... mix code_lead.license.mint \\
        --org "Enrico Mischorr" --tier owner

  The operator then sets the printed key as `LICENSE_KEY` on their
  instance.

  ## Options

    * `--tier`     — tier label; defaults to `commercial`. Resolves through
      `CodeLead.License.tier_baseline/1`, so a tier this build does not
      define grants only what `--features`/`--limits` add. `owner` grants
      every gated feature, including ones added after minting.
    * `--org`      — display name, carried as metadata. Not enforced.
    * `--features` — comma-separated feature atoms, granted on top of the
      tier baseline.
    * `--limits`   — comma-separated `key=value` pairs.
    * `--limit`    — a single `key=value`, repeatable. Same effect as
      `--limits`; use whichever reads better. Both override the tier
      baseline, and integer-looking values are minted as integers.
    * `--expires`  — ISO 8601 date (`YYYY-MM-DD`). Omit for a perpetual key.
      An expired key degrades the instance to community, it does not stop it.

  Reading the private key straight from the environment is the one
  sanctioned exception to CODING_GUIDE's "no `System.get_env/1` outside
  config files" rule: this is a vendor tool and must not depend on, or
  boot, the application it signs keys for.
  """

  use Mix.Task

  alias CodeLead.License.Source.SignedKey

  @switches [
    org: :string,
    tier: :string,
    features: :string,
    limit: :keep,
    limits: :string,
    expires: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    private_key =
      "LICENSE_SIGNING_KEY"
      |> System.fetch_env!()
      |> Base.decode64!()

    claims = %{
      "tier" => opts[:tier] || "commercial",
      "org" => opts[:org],
      "features" => String.split(opts[:features] || "", ",", trim: true),
      "limits" => parse_limits(opts),
      "expires_at" => opts[:expires]
    }

    Mix.shell().info(SignedKey.mint(claims, private_key))
  end

  # `--limit k=v` repeated and `--limits k=v,k=v` are the same thing said
  # two ways; a key may use either or both.
  defp parse_limits(opts) do
    (Keyword.get_values(opts, :limit) ++ String.split(opts[:limits] || "", ",", trim: true))
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {key, parse_value(value)}
        [key] -> Mix.raise("--limit #{key} is missing a value; expected key=value")
      end
    end)
  end

  defp parse_value(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _not_an_integer -> value
    end
  end
end

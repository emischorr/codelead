# Licensing (last updated: 2026-08-14)

CodeLead is [Elastic License 2.0](../LICENSE.txt). ELv2 grants broad use with
two limitations that matter here: you may not offer CodeLead to third parties
as a hosted or managed service, and you may not circumvent the license key
functionality. This note describes that key functionality — `CodeLead.License`.

**Today it gates nothing.** No feature is declared paid, so every instance runs
as `:community` with everything enabled. That is the intended state, not an
unfinished one. What exists is the *seam*: one central place that decides
entitlement, so making a feature paid later is a data change rather than a hunt
through the app for places to add a check.

## Modules

| Module | Role |
|---|---|
| `CodeLead.License` | The seam: `@gated_features`, tier baselines, the policy, the boot loader |
| `CodeLead.License.Entitlements` | The resolved grant — tier, org, features, limits, expiry |
| `CodeLead.License.Source` | Behaviour: license material in, entitlements out |
| `CodeLead.License.Source.SignedKey` | The one implementation — offline Ed25519 |

Entitlements are **instance-scoped**, matching the singleton `organization`:
one deployment is one org, so a grant governs the whole instance. They are
resolved once at boot in `CodeLead.Application.start/2` and cached in
`:persistent_term`, so reads are a term lookup with no GenServer in the path.

## The key

`LICENSE_KEY` holds a signed token, read in `config/runtime.exs` like every
other environment variable. Absent means community. There is no key-entry UI
and no database column — the signed key is the only source of truth.

The token is two unpadded base64url parts joined by a dot,
`b64url(payload).b64url(signature)`, where the payload is JSON:

```json
{"tier": "business", "org": "Sibling Corp",
 "features": ["agent_marketplace"],
 "limits": {"max_concurrent_runs": 50},
 "expires_at": "2027-08-13"}
```

Every field is optional except `tier`. `org` and `expires_at` are metadata;
seats are not enforced.

Verification is **offline** — Ed25519 against a public key compiled into the
release. A self-hosted instance must keep working without reaching a vendor
server, which rules out online activation, phone-home, and remote revocation.
The signature is checked against the exact decoded payload bytes *before* the
JSON is parsed; re-encoding a parsed map and verifying that would make validity
depend on key order and whitespace.

## Tiers are a baseline plus per-key extras

A grant is not community-versus-everything. `CodeLead.License.tier_baseline/1`
maps a tier to what it grants, and the resolved entitlement is that baseline
**overlaid with the key's own explicit grants**:

- `features` — the union of baseline and key
- `limits` — merged, with the key's value winning

Two consequences worth having in mind:

- Editing `tier_baseline/1` changes what a tier means for **every key already
  issued** against it, on next boot. No reissue, no migration.
- A one-off deal needs no new tier — mint a `pro` key carrying an extra
  feature or a raised limit.

An unknown tier grants nothing of its own, so a key minted against a newer
release degrades rather than erroring.

## Failure is always downward

Missing key, bad signature, expired, malformed, unparseable date, wrong-sized
public key — every one of them resolves to `:community` and logs a warning
naming only the reason. A lapsed commercial key must degrade a self-hosted
instance to free, never brick it. Boot does not fail on a bad key, and the key
value is never logged.

## Unknown names are dropped

Names in a key become atoms with `String.to_existing_atom/1`, with the failure
rescued. A key minted against a newer build can therefore name features this
build has never heard of without raising or growing the atom table — the
unknowns are simply dropped.

While `@gated_features` is empty this has a corollary that surprises people:
**no feature atom exists in the compiled application, so every feature named in
a key is dropped**. A `business` key resolves as `:community` with no features.
That is consistent rather than broken — a feature name only means anything once
it is listed in `@gated_features`, and listing it is exactly what brings its
atom into existence. `SignedKey` logs the dropped names so the reason is
visible rather than mysterious.

## How to add a gated feature

1. **Declare it.** Add the atom to `@gated_features` in `lib/code_lead/license.ex`.
   Until it appears there it is free, and its atom does not exist.
2. **Check it where it matters.** Call `CodeLead.License.feature_enabled?/1` at
   the call site **and** in the authoritative server-side action. Hiding a link
   is cosmetic; the `handle_event` / controller check is what actually gates,
   and it is what gives ELv2's key clause something to protect.
3. **Grant it.** Add it to a tier baseline for everyone on that tier, or list
   it in a key's `features` for one customer, or both.

Call sites do not change when a feature later moves between tiers — only
`tier_baseline/1` and the minted keys do.

```elixir
# cosmetic
<.link :if={CodeLead.License.feature_enabled?(:cost_dashboard)} navigate={~p"/costs"}>
  Cost dashboard
</.link>

# authoritative
def handle_event("open_cost_dashboard", _params, socket) do
  if CodeLead.License.feature_enabled?(:cost_dashboard) do
    {:noreply, push_navigate(socket, to: ~p"/costs")}
  else
    {:noreply, put_flash(socket, :error, "Requires a commercial license")}
  end
end
```

## Limits

`CodeLead.License.limit/2` takes the caller's own default, so an ungated call
site keeps its current behaviour with no coupling to this module.

The worked example, **not built**: `CodeLead.Scheduler.Gates.CapacityGate`
reads `Application.fetch_env!(:code_lead, :max_concurrent_runs)`. Were a tier
to raise that cap, the change is one line —
`CodeLead.License.limit(:max_concurrent_runs, org_default)` — with no scheduler
logic touched. The concurrency cap is not a licensed feature today.

## Minting (vendor side)

`mix code_lead.license.mint` signs a payload with the private half of the
instance signing pair, supplied base64-encoded in `LICENSE_SIGNING_KEY`. The
private key is not in this repo and must not enter it or CI.

```bash
LICENSE_SIGNING_KEY=… mix code_lead.license.mint \
  --org "Sibling Corp" --tier business --expires 2027-08-13

LICENSE_SIGNING_KEY=… mix code_lead.license.mint \
  --org "Custom Deal" --tier pro \
  --features agent_marketplace --limit max_concurrent_runs=50
```

The operator sets the printed token as `LICENSE_KEY`.

Rotating the signing pair means shipping a new public key in a release and
reissuing every outstanding key, so it is not a routine operation. Since
verification is offline there is no revocation channel — `expires_at` is the
only expiry mechanism.

## Deliberately not built

No billing or payment integration, no online activation or phone-home, no
revocation server, no key-entry UI, no seat enforcement, no per-user or
per-project entitlements, and no paid features. Adding any of them is additive;
none of them changes the shape above.

## Testing

The policy must not be weakenable at runtime, so — unlike `Executor` and
`Scheduler` — there is no config switch and no `impl/0` resolver on `Source`.
Tests reach the moving parts through pure extra-arity functions instead:
`License.policy_allows?/3` takes a gated set, and `SignedKey.resolve/2` takes a
public key, so a test signs with an ephemeral pair. Neither is a production
code path.

`test/code_lead/license_test.exs` is `async: false` because `:persistent_term`
is VM-global.

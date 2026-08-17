# Licensing (last updated: 2026-08-15)

CodeLead is [Elastic License 2.0](../LICENSE.txt). ELv2 grants broad use with
two limitations that matter here: you may not offer CodeLead to third parties
as a hosted or managed service, and you may not circumvent the license key
functionality. This note describes that key functionality — `CodeLead.License`.

**Almost everything is free.** A community instance — one with no `LICENSE_KEY`
at all — runs the board, the runtime, the agents, the reviews and the whole
web UI with nothing withheld. `@gated_features` names the exceptions, and it is
short:

| Feature | What it gates |
|---|---|
| `:container_execution_env` | Running a task in a sibling container — `tasks.execution_env == :container`. See [ADR-0004](adr/0004-container-executor-iteration-two.md) and the section below. |

The value of the seam is that this table is the *only* place the decision
lives: making a feature paid is a data change plus two call sites, not a hunt
through the app.

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
{"tier": "business", "org": "Some Corp",
 "features": ["container_execution_env"],
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

### The `:owner` tier

`:owner` is the maintainer's own tier and the one exception to "a baseline is a
fixed list": its baseline *is* `@gated_features`, resolved at compile time. Gate
a new feature and every owner instance picks it up on the next boot, with no key
reissued — which is the point, since the maintainer's key would otherwise need
rotating every time something becomes paid.

It grants **features only**. `limit/2` still hands an owner instance the
caller's own default, because there is no generic way to express "every cap
raised" — the limit names aren't enumerable the way the gated set is. An owner
key that needs a raised cap carries it explicitly via `--limits`.

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

This is why listing a feature in `@gated_features` is what brings its atom into
existence: a name no build has compiled cannot be granted, and a feature nobody
gates does not need granting. A key naming `sso` against a build that has never
declared `:sso` resolves without it — and `SignedKey` logs the dropped names, so
the reason is visible rather than mysterious.

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

## The worked example: container execution

`:container_execution_env` is the first — and so far only — gated feature, and
it is worth reading as the pattern for the next one. It is checked in three
places, in descending order of authority:

1. **The start guard.** `CodeLead.Tasks`'s private `check_execution_env/1` is a
   single chokepoint already reached by both `startable/2` (which the board and
   task page use to enable the Start button) and `check_stage_entry(task,
   :execute)` (which every transition into an execute stage passes through). One
   clause therefore covers Planning→Running *and* the Review→Running re-run
   edge. Unlicensed, it returns `{:error, :unlicensed_execution_env}`, which
   `CodeLeadWeb.FlashMessages.transition_error/1` renders both as the flash and
   as the disabled Start button's hint.
2. **The changeset.** `Tasks.create_task/2` and the Planning branch of
   `Tasks.update_task/2` refuse to *store* `execution_env: :container`, which
   closes the console path documented in [console-api.md](console-api.md) as
   much as the form. The check keys on `get_change/2`, not `get_field/2`, on
   purpose: a task already stored as `:container` — minted before the gate, or
   on an instance whose key has lapsed — must stay editable. Renaming it is not
   the licensed act; running it is, and step 1 blocks that.
3. **The select.** The task page's Execution dropdown renders the Container
   option `disabled` rather than dropping it. Filtering it out would make a task
   already set to `:container` render with Local selected and misreport its own
   state.

Note what is *not* gated: the repository's execution-environment select in
project settings. Enabling devcontainer execution is a repository property,
not the execution feature, so an operator can prepare repositories before
buying a key.

A community instance therefore keeps every container-targeted task it already
has — visible, editable, refusing to start with a message that says why.

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
  --org "Some Corp" --tier business --expires 2027-08-13

LICENSE_SIGNING_KEY=… mix code_lead.license.mint \
  --org "Custom Deal" --tier pro \
  --features container_execution_env --limits max_concurrent_runs=50

# The maintainer's own instance — no --features needed, the baseline
# carries the whole gated set and keeps carrying it as it grows.
LICENSE_SIGNING_KEY=… mix code_lead.license.mint \
  --org "Enrico Mischorr" --tier owner
```

`--limits k=v,k=v` and a repeated `--limit k=v` are the same thing said two
ways; use whichever reads better.

The operator sets the printed token as `LICENSE_KEY`.

Rotating the signing pair means shipping a new public key in a release and
reissuing every outstanding key, so it is not a routine operation. Since
verification is offline there is no revocation channel — `expires_at` is the
only expiry mechanism.

## Deliberately not built

No billing or payment integration, no online activation or phone-home, no
revocation server, no key-entry UI, no seat enforcement, and no per-user or
per-project entitlements. Adding any of them is additive; none of them changes
the shape above.

## Testing

The policy must not be weakenable at runtime, so — unlike `Executor` and
`Scheduler` — there is no config switch and no `impl/0` resolver on `Source`.
Tests reach the moving parts through pure extra-arity functions instead:
`License.policy_allows?/3` takes a gated set, and `SignedKey.resolve/2` takes a
public key, so a test signs with an ephemeral pair. Neither is a production
code path.

Because there is no config switch, the suite grants itself entitlements the same
way production does — by writing them. `test/test_helper.exs` installs an
`:owner` grant once, via `CodeLead.LicenseHelpers.grant_owner!/0`, so that the
ordinary container tests exercise the real path rather than being refused
everywhere. A test that asserts the *gate* calls `grant_community!/0` in its own
`setup` and restores the owner grant on exit; because `:persistent_term` is
VM-global, such a module must be `async: false`. `license_test.exs`,
`tasks_license_test.exs` and `task_live_license_test.exs` are the three that do.

## Running a licensed instance locally

Container execution is licensed, so a dev instance with no `LICENSE_KEY` will
refuse to start container tasks — exactly as a community deployment does. This
is deliberate; there is no dev-only override, because a config switch that
weakened the policy would be a bypass rather than a feature. Mint yourself an
`owner` key and put it in `.envrc`:

```bash
export LICENSE_KEY=$(LICENSE_SIGNING_KEY=… mix code_lead.license.mint \
  --org "Your Name" --tier owner)
```

Boot then logs `License: owner (Your Name)`.

`test/code_lead/license_test.exs` is `async: false` because `:persistent_term`
is VM-global.

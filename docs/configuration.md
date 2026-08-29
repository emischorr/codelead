# Configuration (last updated: 2026-08-19)

All environment variables are read in `config/runtime.exs` and accessed in
application code via `Application.get_env(:code_lead, ...)` — never
`System.get_env/1` outside of config files (see CODING_GUIDE.md).

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ENCRYPTION_KEY` | fixed dev/test key; **required in prod** | Base64-encoded 32-byte key for `CodeLead.Vault` (Cloak AES-GCM). Encrypts provider credentials and project env store entries marked secret (the default — an entry can opt out per-value). Generate: `32 \|> :crypto.strong_rand_bytes() \|> Base.encode64()`, or `openssl rand -base64 32`. Anything that does not decode to exactly 32 bytes fails at boot. |
| `WORKSPACE_ROOT` | `<repo>/workspace` (dev/prod) | Root for CodeLead-managed working state: base clones, per-task git worktrees, task folders. Gitignored. **Container execution requires it to be host-coincident** — when the app itself runs in a container, the host directory must be bind-mounted at the identical path (the deployed stack's `DATA_ROOT` bind), because the devcontainer CLI's bind sources are resolved by the host daemon (ADR-0009, [deployment.md](deployment.md#the-data-directory)). **Ignored in `:test`** — the test suite wipes its workspace root before running, and an agent's `mix test` inside a task worktree inherits the instance's env, so honoring this var in test once wiped a deployed instance's workspace. |
| `TEST_WORKSPACE_ROOT` | `<repo>/tmp/test_workspace` | Test-env-only workspace root override (for CI). Must resolve to a path inside the checkout — `test_helper.exs` refuses to wipe anything outside it. |
| `MAX_CONCURRENT_RUNS` | `3` | Cap on simultaneously executing task runs; excess stays queued. |
| `LICENSE_KEY` | — | Signed license key for the instance. Optional everywhere including prod — absent means the community tier, which grants everything except container execution (tasks whose Execution is set to Container). Verified offline at boot; anything unusable (bad signature, expired, malformed) logs a warning and falls back to community rather than failing the boot. See [`licensing.md`](licensing.md). |
| `DATABASE_URL` | **required in prod** | `ecto://USER:PASS@HOST/DATABASE`. |
| `SECRET_KEY_BASE` | **required in prod** | Signs and encrypts cookies. `mix phx.gen.secret` or `openssl rand -base64 48`. |
| `PHX_HOST` | `example.com` | The canonical hostname — the one in generated links. Feeds the endpoint's `:url` **and** is always allowed by the origin check (host only, any scheme/port). If the address bar shows a host that is neither this nor in `ALLOWED_HOSTS`, the page renders but LiveView never connects. |
| `ALLOWED_HOSTS` | — | Comma-separated extra addresses the app may be reached at, on top of `PHX_HOST` — so one instance can answer both a LAN IP over http and a domain behind a TLS proxy. A bare host (`192.168.1.50`, `*.example.com`) matches any scheme and port; a full origin (`http://192.168.1.50:4000`) must match exactly; `*` disables the origin check entirely. |
| `SCHEME` | `http` | Scheme for generated absolute URLs (login links, invites, email-change confirmations). Set to `https` when a proxy terminates TLS in front. |
| `PORT` | `4000` | The port the endpoint binds to. Nothing else — it does not appear in generated URLs. |
| `URL_PORT` | `443` when `SCHEME` is `https`, else `80` | The port in generated absolute URLs. Independent of `PORT`, so an instance can listen on 4000 and still emit `https://host` behind a proxy. Set it only when the app is reached directly on a non-standard port (then it equals the *published* port, which need not be `PORT`). |
| `POOL_SIZE` | `10` | Database connection pool size. |
| `ECTO_IPV6` | — | `true`/`1` to add `:inet6` to the database socket options. |
| `DNS_CLUSTER_QUERY` | — | DNS query for node clustering; unused in a single-node deployment. |
| `SMTP_HOST` | — | **The mail switch.** Unset means no transport, and every email surface is hidden (see *Mail* below). Set it to an SMTP relay's hostname to configure `Swoosh.Adapters.SMTP` and turn those surfaces on. |
| `SMTP_PORT` | `587` | Relay port. `465` usually implies `SMTP_SSL=true`. |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | — | Relay credentials. Leave both unset for an unauthenticated relay (auth is only attempted when a username is given). |
| `SMTP_TLS` | `if_available` | STARTTLS policy: `always`, `never`, or `if_available`. The peer certificate is verified against the system CA store whenever TLS is used. |
| `SMTP_SSL` | `false` | `true`/`1` for implicit TLS (the connection is TLS from the start, rather than upgrading via STARTTLS). |
| `MAIL_FROM` | `codelead@$PHX_HOST` | Sender address. Most relays reject a sender they don't recognise, so set this to an address the relay accepts. |
| `MAIL_FROM_NAME` | `CodeLead` | Display name on the sender. |
| `WORKSPACE_VOLUME` | — | **Legacy** (pre-ADR-0009 stacks): name of the docker volume holding `/data`. A volume's data has no stable host path, so devcontainer execution cannot work under it — when set, container-selecting tasks refuse to start with guidance. Migrate to the `DATA_ROOT` bind. |
| `WORKSPACE_VOLUME_MOUNT` | `/data` | Legacy companion to `WORKSPACE_VOLUME`/`HOST_DATA_ROOT`: where that source was mounted inside sibling containers. |
| `HOST_DATA_ROOT` | — | **Legacy** escape hatch (ADR-0003): host path of a `/data` bind. Non-coincident, so container tasks refuse under it too — mount the same host path at the identical container path instead and it becomes unnecessary. |
| `CONTAINER_USER` | `1000:1000` in the image, unset in dev | `uid:gid` the one-shot **harness build** container runs as, matching the owner of the workspace volume. Task containers no longer use it — their user (like their resource caps via `runArgs`/`hostRequirements`) comes from the repo's devcontainer config (ADR-0009). |
| `DEVCONTAINER_CLI` | `devcontainer` | The devcontainer CLI executable provisioning task environments. Baked into the published image; on a dev machine install it with `npm i -g @devcontainers/cli`. |
| `HARNESS_VERSION` | `0.66.0`, pinned in `config/runtime.exs` in sync with the image's `CLAUDE_ACP_VERSION` build arg | Version directory the compiled harness binary is staged under (`<WORKSPACE_ROOT>/harness/<version>/`). |
| `HARNESS_SOURCE` | — | Air-gapped escape hatch: a directory of pre-staged harness runtime dirs, one per libc flavor (`<flavor>/` with `claude-agent-acp`, `bun`, `node_modules/`), copied at boot. Normally unset — the harness runtime is staged lazily in-docker on the first container run needing the flavor (ADR-0005/0007). |
| `PREVIEW_PUBLISH_IP` | auto | Host interface a container task's declared `preview_port` is published on — by a per-task relay sidecar (`codelead-preview-<task_id>`, ephemeral host port), not by the task container itself. Unset, it is auto-detected (`CodeLead.PreviewGateway.Address`): loopback when the BEAM runs on the docker host (dev), the docker bridge gateway when the app itself runs in a container (the deployed stack). Set it only for setups the detection cannot cover — custom bridge networks, a remote daemon, Docker Desktop. Never a public interface — browsers only ever reach previews through the authenticated `/preview/:task_id/` proxy (ADR-0008). |
| `PREVIEW_UPSTREAM_HOST` | auto | Address the in-app preview proxy dials for container-task upstreams (the host port comes from `docker port` on the relay). Auto-detected the same way as `PREVIEW_PUBLISH_IP` and matches it in practice; override both together or neither. Local-task previews always dial loopback and need neither variable. |
| `PREVIEW_RELAY_IMAGE` | `alpine/socat` | Image the preview relay sidecar runs. Pulled on the first container-task preview; override for mirrored/air-gapped registries — any image whose entrypoint is `socat` works. |
| `PREVIEW_IDLE_MINUTES` | `30` | How long a one-click preview server keeps running with nobody on the Review tab before it stops itself. |
| `PREVIEW_START_TIMEOUT_SECONDS` | `120` | How long a started preview command gets to answer on the preview port before the session gives up and surfaces its log tail. |
| `TERMINAL_IDLE_MINUTES` | `15` | How long a viewer-less Terminal session keeps its shell alive before stopping it. |
| `MAINTENANCE_IMAGE` | `alpine:3.20` | Image `CodeLead.Workspace.Remover` uses to delete root-owned leftovers of container runs (a short-lived `docker run … rm -rf` over the mounted socket). Any image with a POSIX `rm` works; override for mirrored/air-gapped registries. Installs without docker never use it — blocked deletions surface for manual cleanup instead. |
| `PREVIEW_DOMAIN` | — | Unset (the convention), previews are served at `/preview/<task_id>/` on the app's own origin with zero configuration. Set to a wildcard-DNS'd domain (e.g. `preview.example.com`) to switch the **whole instance** to per-task subdomain previews at `task-<id>.$PREVIEW_DOMAIN` — for apps that break under path-prefix hosting. See [Subdomain previews](#subdomain-previews-preview_domain). |

**Production serves plain HTTP.** `force_ssl` is commented out in
`config/prod.exs` — no redirect, no HSTS — because TLS termination belongs to
whatever proxy the operator already runs. The
`PHX_HOST`/`SCHEME`/`URL_PORT`/`ALLOWED_HOSTS` combinations for direct,
proxied, and simultaneous access are in
[`deployment.md`](deployment.md#urls-phx_host-scheme-url_port-allowed_hosts).

Local dev secrets live in `.envrc` (gitignored, direnv). Deployment secrets go
in a `.env` made from `deployment/.env.example`; `.env` is gitignored, the
template is not.

## Application config keys

- `:workspace_root` — see above.
- `:max_concurrent_runs` — see above.
- `CodeLead.Vault` — Cloak cipher config (set from `ENCRYPTION_KEY`).
- `CodeLead.License` — `key:` only, set from `LICENSE_KEY`. Resolved once in
  `CodeLead.Application.start/2` and cached in `:persistent_term`; nothing
  re-reads it at runtime. There is deliberately no config key for the gated
  feature list or the verification public key — a runtime switch for either
  would be a bypass, which is also why there is no dev-only way to enable
  container execution without a key. See [`licensing.md`](licensing.md).
- `:harnesses` — launch argv per ACP harness, e.g.
  `%{claude_code: ["claude-code-acp"], codex: ["codex", "acp"]}`. See
  *Harness prerequisites* below.
- `:model_prices` — **fallback** pricing per model, in cents per
  million tokens:
  `%{"claude-sonnet-5" => %{input_cents_per_mtok: 300, output_cents_per_mtok: 1500}}`,
  keyed on the agent's `model_variant`. Only consulted when the backend
  reported no money of its own — ACP harnesses normally do, and their
  figure wins. An unlisted model prices at 0, and the table has no cache
  rates, so a derived figure understates cache-heavy runs. Token counts
  are unaffected either way. See
  [`cost-tracking.md`](cost-tracking.md).
- `Oban` — queues: `rollups` (nightly cost rollups) and `dispatch`
  (wake-ups for scheduled runs). Test uses `testing: :manual`; drain
  with `Oban.drain_queue/1` (pass `with_scheduled: true` to fire a
  scheduled run's wake-up early).
- `:git_access_check` — `{module, function}` the first-run wizard calls
  to verify a forge token, default `{CodeLead.Git, :check_access}`. Test
  points it at `CodeLead.GitHelpers` so the suite stays off the network.
- `:docker_cli` — argv prefix for every docker invocation the container
  executor makes, default `["docker"]`. Tests swap it for
  `test/support/fake_docker.sh` the same way `:harnesses` swaps in the
  fake ACP agent. The CLI honours `DOCKER_HOST` as usual.
- `:preview_gateway` — the `CodeLead.PreviewGateway` implementation.
  Default `PathProxy`; `config/runtime.exs` flips it to `SubdomainProxy`
  when `PREVIEW_DOMAIN` is set. Exactly one gateway is active at a time.
  Tests swap it directly (the test env ignores a dev shell's
  `PREVIEW_DOMAIN`, like `WORKSPACE_ROOT`).
- `:preview_domain` / `:preview_url` — the subdomain gateway's domain
  and the scheme/port stamped into generated preview URLs, both derived
  from `PREVIEW_DOMAIN`/`SCHEME`/`URL_PORT` in `config/runtime.exs`.
- `:preview_publish_ip` / `:preview_upstream_host` — see the env vars
  above.
- `:terminal_shell` — the shell the Terminal tab spawns, default `"sh"`.
- `:terminal_idle_ms` — from `TERMINAL_IDLE_MINUTES`; how long a
  viewer-less terminal session keeps its shell alive, default 15 minutes.
- `:terminal_command` — test-only whole-argv override for local
  terminal spawns (`test/support/fake_shell.sh`), mirroring
  `:docker_cli`.
- `:adopt_previews_at_boot` — whether boot re-attaches sessions to
  container previews that outlived an ungraceful exit, default `true`;
  `false` in the test env, where a boot-time query races the sandbox.
- `:mail_enabled` / `:mail_from` — see *Mail* below.

## Mail

Email is **opt-in and off by default**. `CodeLead.Mailer.enabled?/0` reads
`:mail_enabled`, which is `false` in `config/config.exs`, `true` in dev and
test, and set to `true` in `config/runtime.exs` only when `SMTP_HOST` is
present. Everything else about mail hangs off that one predicate.

The switch is a dedicated key rather than a look at the configured adapter,
because the adapter cannot answer the question: dev wants mail *on* with
Swoosh's `Local` adapter, and a production build inherits that same adapter
with nothing behind it. Sniffing the adapter is what used to make a deployed
instance advertise a magic-link form and a `/dev/mailbox` link that 404s.

**With mail off**, the surfaces that need a transport are hidden rather than
left to fail silently:

- `/users/log-in` renders only the username/password form — no magic-link
  form, no mailbox notice.
- `/settings/users` offers no "Send a magic-link invite" option and no
  *Resend invite* button.
- `Accounts.deliver_login_instructions/2` and `deliver_invite_instructions/2`
  return `{:error, :mail_disabled}` **before** minting a token, so a crafted
  request can't leave an unusable `users_tokens` row behind. This is the
  authoritative half of the check, mirroring the
  [`licensing.md`](licensing.md) discipline: hiding a control is cosmetic.

Not covered: `/users/settings/email` still accepts an email change and
reports that a confirmation link was sent. With no transport that link never
arrives and the address never changes.

**With mail on**, `SMTP_*` configures `Swoosh.Adapters.SMTP` (via `gen_smtp`)
— the only adapter wired up. To smoke-test a relay without sending real mail,
run a local catcher (`python3 -m aiosmtpd -n -l localhost:1025`) and point
`SMTP_HOST=localhost SMTP_PORT=1025 SMTP_TLS=never` at it.

In development, mail is on with the `Local` adapter and sent mail is
browsable at `/dev/mailbox`. `CodeLead.Mailer.local_mailbox?/0` gates the
links to it on *both* that adapter and the dev routes being compiled in, so
it never points at a route that doesn't exist.

### Preview base path

Out of the box — no configuration at all — the live preview serves the
task's dev server under `/preview/<task_id>/` on the app's own origin,
through whatever reverse proxy already fronts it. Previews open in
their own browser tab via the Review tab's **Open preview** button.
The proxy never rewrites response bodies, so an app that emits
absolute asset paths must be told its base path. Root-relative
redirects are rewritten onto the prefix — unless the app, honoring
`PREVIEW_BASE_PATH`, already emitted the prefix itself; those pass
through untouched. Terminal and
one-click preview sessions export `PREVIEW_BASE_PATH` (e.g.
`/preview/42`), `PREVIEW_ORIGIN`, and `PREVIEW_PORT` (the repository's
declared port — unique per repository across the instance, so serve
commands should bind it rather than hardcode one). Terminal sessions
additionally export `CODELEAD_TTY_FILE`, which is CodeLead's own
resize channel and not something to set or rely on (ADR-0010):

The project-side view of all this — collected as a checklist, with
drop-in templates for a repository's `CLAUDE.md`/`AGENTS.md` and a
`codelead-ready` skill — is in
[`project-readiness.md`](project-readiness.md).

| Stack | Recipe |
|---|---|
| Vite | `vite --port "$PREVIEW_PORT" --base "$PREVIEW_BASE_PATH/"` |
| Phoenix | `PORT="$PREVIEW_PORT" mix phx.server` with `url: [path: System.get_env("PREVIEW_BASE_PATH", "/")]` in the endpoint config (read the env in `dev.exs` at boot, or in `config/runtime.exs`) — **and the three things that setting cannot reach**, below |
| Next.js | `next dev -p "$PREVIEW_PORT"` with `basePath: process.env.PREVIEW_BASE_PATH ?? ""` in `next.config` |
| Rails | `rails server -p "$PREVIEW_PORT"` with `config.relative_url_root = ENV["PREVIEW_BASE_PATH"]` |
| Plain static server | serve the directory on `$PREVIEW_PORT`; relative asset paths need nothing more |

These recipes matter only under the default path gateway. Under
[subdomain previews](#subdomain-previews-preview_domain)
`PREVIEW_BASE_PATH` is empty, so the same commands degrade gracefully
to a plain `--port` — an app that cannot be path-prefix-hosted at all
is exactly what that gateway exists for.

#### When the preview tab flickers

`url: [path: …]` (and its equivalents above) covers what the *router*
emits — `~p` routes and static paths. It reaches nothing that lives
outside the router, and a Phoenix app ships three such things by
default:

- **The LiveSocket path.** `assets/js/app.js` carries a literal
  `new LiveSocket("/live", …)` straight from the generator. Under a
  path preview that socket opens against **CodeLead's own** LiveView
  endpoint, which completes the upgrade and then rejects the join — the
  session token was signed by a different `secret_key_base`. The
  client reads that as `stale` and falls back to a full page load, so
  **the preview reloads itself a couple of times a second, forever**.
  If a LiveView preview flickers, this is why. Render the path instead
  of hardcoding it:

  ```heex
  <%!-- root.html.heex --%>
  <meta name="live-socket-path" content={MyAppWeb.Endpoint.path("/live")} />
  ```
  ```js
  // assets/js/app.js
  const path = document
    .querySelector("meta[name='live-socket-path']")
    .getAttribute("content")
  const liveSocket = new LiveSocket(path, Socket, { /* … */ })
  ```

  `Phoenix.Endpoint.path/1` applies the configured `:url` `:path`, so
  this stays `/live` when `PREVIEW_BASE_PATH` is unset — nothing to
  undo in production.

- **Absolute `url()` in CSS.** `url("/fonts/x.woff2")` misses the mount
  and 404s against CodeLead. Make it relative to the stylesheet, which
  resolves under any mount — counting the levels from where the
  *bundle* lands, not the source: from `assets/css/app.css` up to a
  top-level `fonts/` that is `url("../../fonts/x.woff2")`.

- **Hand-written literal `href`/`src`.** A stray `href="/"` in a layout
  walks the user out of the preview and into CodeLead. Use `~p`.

CodeLead notices the reload loop and breaks it: repeated navigations to
the same `/preview/<id>/` URL get a diagnostic page naming these three
causes instead of another proxied response. The page carries a
one-click bypass, and `PREVIEW_LOOP_BREAKER=off` disarms the check
instance-wide. It is a *diagnostic*, not a fix — bodies are still never
rewritten.

### Cookies in the preview (path gateway)

Under the default path gateway the preview shares CodeLead's own
origin, so the proxy gives each task its own cookie jar: an upstream
`Set-Cookie: sid=abc; Path=/` reaches the browser as
`_clp<task_id>_sid=abc; Path=/preview/<task_id>`, and the prefix is
peeled off again on the way upstream. The previewed app sees exactly
the cookies it set, and a previewed CodeLead can no longer overwrite
your session cookie and log you out of your own instance.

One consequence is worth knowing before you preview a Django, Laravel,
or Angular app. Those frameworks use **double-submit CSRF**: the server
sets a *readable* cookie (`csrftoken`, `XSRF-TOKEN`), and client-side JS
reads it out of `document.cookie` and echoes the value in an
`X-CSRFToken` / `X-XSRF-TOKEN` header. Inside a path preview that JS
finds the prefixed name instead and sends no header, so **AJAX writes
get 403** — while everything server-side is unaffected, because the
proxy restores the original name upstream. Server-rendered form posts
(a `{% csrf_token %}` hidden field, Laravel's `_token`) keep working,
and Phoenix is unaffected entirely: its token comes from a
server-rendered `<meta>` tag and its session cookie is `HttpOnly`, so
nothing reads cookies by name in the browser.
[Subdomain previews](#subdomain-previews-preview_domain) are the fix —
each task owns a real origin there, so cookies keep their names and
none of this applies.

### Subdomain previews (`PREVIEW_DOMAIN`)

The escape hatch for apps the path gateway cannot serve: each task gets
its own origin, `task-<id>.<PREVIEW_DOMAIN>`, proxied through the same
app with **no** cookie renaming, **no** `Location` rewriting, and no
base-path requirement. Enabling it replaces path previews
**instance-wide** — exactly one gateway is active, and a stale
`/preview/…` link fails with a branded page pointing at the task's
current preview address.

Setup, once:

1. **Wildcard DNS**: point `*.preview.example.com` at the same host as
   the app.
2. **Reverse-proxy rule**: forward the wildcard vhost to the app —
   concrete Caddy and nginx blocks (and the wildcard-certificate
   caveat: DNS-01 challenge, DNS-provider credentials) are in
   [`deployment.md`](deployment.md#reverse-proxy-configuration).
3. Set `PREVIEW_DOMAIN=preview.example.com`.
4. Restart.

The recommended value is `preview.<apex of PHX_HOST>` —
`PHX_HOST=codelead.example.com` → `PREVIEW_DOMAIN=preview.example.com`,
previews at `task-42.preview.example.com`. Staying on the same
registrable domain keeps app and previews same-site, so `SameSite=Lax`
cookies (CodeLead's and the previewed app's) behave normally. A
`PREVIEW_DOMAIN` on a *foreign* registrable domain makes every preview
cookie third-party — browsers block those, the auth handshake breaks,
and boot logs a prominent warning: that configuration is unsupported.

Since the preview origin never sees CodeLead's (host-only) session
cookie, the **Open preview** button carries a short-lived signed token;
the preview origin exchanges it for its own session cookie
(`_clp_session` — a name previewed apps should not use) and strips it
via redirect. Visiting a preview subdomain directly without that
handshake gets a branded 401 — open previews from the Review tab.
Authorization is unchanged from the path gateway: any logged-in user
may view any preview.

Dev needs no DNS at all: modern browsers resolve `*.localhost` to
loopback, so `PREVIEW_DOMAIN=preview.localhost mix phx.server` serves
previews at `task-42.preview.localhost:4000` with zero setup.

This is deliberately the feature's only knob — everything else about
previews keeps working by default under either gateway.

#### Switching gateways on a live instance

Tasks already sitting in Review keep working, but their **running dev
servers do not migrate**: a server captured `PREVIEW_BASE_PATH` in its
environment when it started, and it keeps emitting URLs from the old
gateway's mount until it is restarted. The symptom is a preview whose
document loads but whose stylesheets and scripts 404 under
`/preview/<id>/…`.

CodeLead reconciles the sessions it owns. A session is fingerprinted
with the preview URL it was started for, so a mismatch with the active
gateway stops the server and starts a fresh one — at boot for a
container survivor (which is discarded rather than adopted), and on the
next Start for a live session. A server started **by hand** from the
Terminal tab is outside that: CodeLead only ever signals the process it
recorded, so kill that one yourself before starting the preview. When
a request still arrives under the old mount and the upstream 404s it,
the proxy serves a diagnostic naming this cause instead of the
upstream's own 404.

Relatedly, Start preview refuses with *a server is already answering on
this task's preview port* rather than spawning a second server behind
the first — a probe cannot tell the two apart, and the older one wins
the port.

### Serving a preview from a container task

What a *repository* has to do about everything in this section, including
its `.devcontainer`, is collected in
[`project-readiness.md`](project-readiness.md); this is the mechanism
behind it.

The base path above is what the *browser* needs. A **container** task's
dev server carries further constraints, all consequences of the
execution model rather than settings — a local task has none of them,
because its server runs in the app's own process space and the proxy
dials loopback.

**Bind `0.0.0.0`, not `127.0.0.1`.** The proxy reaches a container task
through a relay sidecar on the task container's network, which forwards
to the container's ip — and a connection arriving over the network
cannot reach a socket bound to the container's own loopback. A server on
`127.0.0.1` is invisible to the preview no matter how the deployment is
configured:

| Stack | Flag |
|---|---|
| Phoenix | `http: [ip: {0, 0, 0, 0}]` |
| Vite | `--host` |
| Next.js | `-H 0.0.0.0` |

**Listen on exactly the declared `preview_port`.** The relay forwards
the port the repository declares, so a server on any other port resolves
to nothing — bind `$PREVIEW_PORT` and it always matches. Declaring or
changing `preview_port` needs no container recreate — the relay is
(re)created to match on the next preview touch — see
[Container-task live previews](deployment.md#container-task-live-previews).

**Companion services come from the devcontainer.** A database or cache
beside the app belongs in the repo's `.devcontainer` setup —
`dockerComposeFile` services come up with the environment, and
dependency installs or seeds run in its lifecycle hooks
(`postCreateCommand`/`postStartCommand`) — though the installs
themselves belong in the image, keyed on the lockfile, so the host's
layer cache serves every task instead of each one paying for them
again (see [`project-readiness.md`](project-readiness.md#making-the-devcontainer-work-for-agents-too)).
The executor never invents a services model of its own (ADR-0009).

**One-click preview.** With a `preview_command` declared on the
repository, the Review tab grows a Start preview button: the command
runs in the worktree (locally, or `docker exec`'d into the task's
devcontainer) with the project env plus `PREVIEW_BASE_PATH`/
`PREVIEW_ORIGIN`, a status chip follows
`Starting… → Running`, and a failure surfaces the command's log tail in
place. *Running* means the upstream answered an HTTP request, not merely
that a port accepted a connection — for a container task the relay
sidecar accepts on the dev server's behalf whether or not it ever bound,
so an open port proves nothing. The chip keeps checking afterwards and
turns to *Unreachable* when a server that was answering stops. The command should be a single process (installs belong in the
lifecycle hooks) — a leading `VAR=value` prefix is fine
(`PORT="$PREVIEW_PORT" mix phx.server`), but shell operators (`&&`,
`|`, `;`) do not survive the container path, which `exec`s the command
so the pid it records is the server's; put anything compound in the
lifecycle hooks or the project env store. The session stops on
request-changes, on leaving
Review for good, after `PREVIEW_IDLE_MINUTES` with nobody watching, and
when the app shuts down. Stopping signals the command's whole process
group, so a compound command's children go with it.

A container preview that outlives an *ungraceful* exit (`kill -9`, OOM,
a host crash) is re-attached at boot rather than left running unmanaged:
the Review tab shows the server that is actually serving, and Start
preview does not spawn a second one.

**Manual fallback.** Without a `preview_command`, start the server from
the task's Terminal. The session stops the shell after
`TERMINAL_IDLE_MINUTES` with no viewer, and stopping means signalling
the shell's whole process group — so a server started from it goes down
with it, backgrounded or not (ADR-0013). The same happens when the app
shuts down and when the execution context is destroyed.

Note the asymmetry with the one-click preview, and that it is
deliberate: a run entering Running stops the preview but *not* the
terminal. Request changes preserves the worktree, the branch and the ACP
session, so it preserves the shell you are holding too.

What also ends it is environment *removal*: cancel, Review→Planning
(`worktree_policy: :discard`), reaching Done (finalize always releases
the environment), or the boot reaper for any task not sitting in
Review. Only the workspace mount survives that, so anything written
outside it — an `initdb`'d data dir included — goes with the
environment. Durable state belongs under the worktree, the agent home,
or a compose volume the repo's own compose file declares.

## Git credentials

Cloning, fetching and pushing a **private** repository over `https://`
needs a forge access token. It lives in the project env store (encrypted —
the store's default) under the key for the repository's forge:

| Forge | Project env key |
|---|---|
| `github.com` | `GITHUB_TOKEN` |
| `gitlab.com` | `GITLAB_TOKEN` |

The same value is used for git transport *and* for opening the PR/MR at
Done — one token, one place. Set it in the first-run wizard's project
step, or on an existing project from the console:

```elixir
CodeLead.Projects.put_env(project_id, "GITHUB_TOKEN", "github_pat_…")
```

The wizard verifies the token against the remote (`git ls-remote`) the
moment you save it, so a bad one is reported there rather than at the
first dispatch.

`CodeLead.Git` hands the token to git through a per-invocation
`credential.helper` that reads it back out of the subprocess
environment, so it never lands in `.git/config`, in argv, or anywhere on
disk. The helper answers with the username `x-access-token`; both forges
ignore it and authenticate on the token alone, so there is no username
to configure. Dispatch failures are scrubbed of anything token-shaped
before they reach `task_steps`.

Three limits worth knowing:

- **SSH remotes (`git@…`) ignore the token** and use the server user's
  own key. The key must be usable without a passphrase prompt — git runs
  with `BatchMode=yes` and will fail rather than block.
- **Only GitHub and GitLab have a token convention.** Self-hosted forges
  fall back to the host's ambient git credentials.
- **With no token stored, git falls back to the server's own
  credentials** — the operator's keychain on a dev laptop, nothing at all
  in a container. This is the one that surprises people: a private repo
  can clone fine for weeks and then start failing the day a token is
  added, because installing the helper also *resets* the inherited ones.
  A local-only success is not evidence the deployment will work.

### When git refuses

`ensure_clone/3` re-points `origin` at the project's current repository
URL on every run, so editing the URL takes effect without deleting the
base clone. What it cannot fix is the credential — at clone time on
dispatch, or at push time when Approve → Done finalizes. `LC_ALL=C` pins
these messages, so they are safe to match on:

| Git says | What it means |
|---|---|
| `Invalid username or token` | The token was presented and rejected — expired, revoked, or simply not the value you think is stored. Note GitHub appends "Password authentication is not supported for Git operations" to *every* HTTPS auth failure; it is boilerplate, not the diagnosis. |
| `Repository not found` | The credential is valid but has no access to that repository — or the owner/repo in the URL is wrong. |
| `Write access to repository not granted` (HTTP 403 on push) | The token is valid and can *read* — clone and dispatch succeed, only Approve → Done fails. It has no write scope. Fine-grained PAT: **Contents: Read and write**. Classic PAT: the `repo` scope. GitLab words this `You are not allowed to push code to this project` and needs `write_repository`. |
| `could not read Username … terminal prompts disabled` | No token stored *and* no ambient credential on the host. |
| `Permission denied (publickey)` | An SSH remote whose key the server cannot use. |
| `CONFLICT (content)` / `Automatic merge failed` | Merge or squash mode only: the branch conflicts with the default branch. Nothing was merged and nothing pushed. Request changes so the agent rebases, or switch the task to Pull request mode and resolve it on the forge. |
| `non-fast-forward` / `Updates were rejected` | Merge or squash mode only: the default branch moved on the remote between the fetch and the push. Nothing landed — approve again to retry against its new tip. Never force-pushed. |
| `protected branch` / `GH006` / `pre-receive hook declined` | The remote refuses direct pushes to the default branch. This is exactly what Pull request mode is for; switch the task or the project default. |

`CodeLead.Git.refusal/1` sorts output into these three classes
(`:auth` / `:write_denied` / `:other`) and `remote_failure/4` turns one
into the sentence the operator reads. The last three rows are not about
credentials, so they get their own pair — `merge_refusal/1` and
`merge_failure/4`, which falls through to `remote_failure/4` for
anything that *is*.

### Approve defaults (per project)

`projects.settings["finalize"]` holds what Approve → Done does by
default, edited under **Settings → Projects → \<project\> → On approve**:

| Key | Values | Applies to |
|---|---|---|
| `repo` | `pull_request` (default) / `merge` / `squash` | `:repo`-target tasks |
| `folder` | `artifact` (default) / `commit_to_path` | `:folder`-target tasks |
| `commit_path` | a repository-relative path, default `artifacts` | where `commit_to_path` lands the artifact |

An individual task overrides this in the **On approve** selector on its
own page (`tasks.finalize_mode`); leaving it on *Project default* means
it keeps following the project, including after the project changes.
An unrecognized or wrong-target value in the column is ignored rather
than run — see [`task-workflow.md`](task-workflow.md) → *Finalize modes*.

Merge and squash push straight to the repository's default branch. On a
forge with branch protection that push will be refused; use pull-request
mode there.

### PR template (per project)

`projects.settings["pr_template"]` holds the description used when
Approve → Done opens a pull/merge request, edited under **Settings →
Projects → \<project\> → PR template**. A blank field clears it back to
the built-in default:

```
{{description}}

---
Created by CodeLead for task #{{task_id}}.
```

`CodeLead.Finalizer.create_pull_request/4` substitutes four
placeholders before sending the body to the forge: `{{title}}`,
`{{description}}`, `{{task_id}}` and `{{branch}}`. The template only
affects the PR/MR **body** — the title is always `tasks.title`
verbatim, and merge/squash mode never opens a PR at all.

Triage a GitHub token without involving CodeLead:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" https://api.github.com/repos/OWNER/REPO
# 200 = valid, with access · 401 = expired or invalid · 404 = valid, no access to that repo
```

A fine-grained PAT needs the repository's owner as its **resource
owner**, that repository selected under *Repository access*, and
**Contents: Read and write** (read alone clones, but Done pushes).

Every git invocation runs with a sanitized environment: `GIT_ASKPASS`,
`SSH_ASKPASS` and the `VSCODE_GIT_ASKPASS_*` variables are unset,
`GIT_TERMINAL_PROMPT=0`, and `LC_ALL=C`. Without this, a server started
from a VS Code integrated terminal inherits that terminal's askpass hook
and a clone pops a GitHub sign-in dialog on the operator's desktop
instead of failing; on a headless host it would hang instead.

## Harness prerequisites

`:acp` agents launch a harness binary that must be on the **`PATH` of
the process running CodeLead** (`System.find_executable/1` resolves it
before the port is opened — putting `PATH` in the project env store does
not help).

| Harness | Binary | Install |
|---|---|---|
| `claude_code` | `claude-agent-acp` | `npm i -g @agentclientprotocol/claude-agent-acp` (needs Node ≥ 22) |
| `codex` | `codex` | the Codex CLI, providing `codex acp` |

A missing binary fails the run at dispatch — before any repository is
cloned — with a message naming the executable.

> The Claude harness was published as `@zed-industries/claude-code-acp`
> (binary `claude-code-acp`) until it was renamed. If you still have the
> old package installed, replace it — the binary name changed, so the
> default `:harnesses` config no longer finds it.

The **Docker image bundles `claude-agent-acp`**; only `codex` is
bring-your-own there. See *Docker image* below.

## Docker image

Published as `ghcr.io/emischorr/codelead:latest` (multi-arch, amd64 and
arm64). `docker build -t codelead .` produces the same release image
locally; it needs no manual harness install. The buildx invocation used to
publish is in the `Dockerfile` header comment, and repeated with the rest of
the deployment story in [`deployment.md`](deployment.md).

| Build arg | Default | Purpose |
|---|---|---|
| `CLAUDE_ACP_VERSION` | pinned in the Dockerfile | Version of `@agentclientprotocol/claude-agent-acp` to bundle. Bump it deliberately — the image is reproducible only because it is pinned. |
| `ALPINE_VERSION` | pinned in the Dockerfile | Base for both the runner and the harness stage. Node comes from that release's `nodejs` package, so the two always agree on musl; the build fails if it is ever older than Node 22, which the harness requires. |

The harness lands in `/opt/harness` (on `PATH`); `npm` stays behind in the
harness stage, so the runner carries only `nodejs`.

**Mount a volume on `/data`.** The image runs as the unprivileged `elixir`
user (uid 1000) and points two variables there:

- `HOME=/data/home` — the agent harness writes its own config and session
  state under `$HOME`. Without a writable home it starts and then fails.
- `WORKSPACE_ROOT=/data/workspace` — base clones, task worktrees, task
  folders. Without the override these would land inside the release
  directory.

### What the agent can run inside the image

An ACP session runs shell commands, so the runner carries a toolbox beyond
what the release itself needs: `bash` (BusyBox has no `bash` applet, and the
harness's shell tool invokes bash — without it *every* shell call the agent
makes fails), the GNU builds of `coreutils`/`findutils`/`grep`/`sed`/
`diffutils` (BusyBox applets share their names but reject flags agents reach
for by habit — `grep -P`, `find -printf`, `sort -V`, `date -d`), plus `curl`,
`jq`, `ripgrep` and `openssh-client`. `SHELL=/bin/bash` is set explicitly
rather than left to a fallback.

**The agent does not see CodeLead's own configuration.** Local subprocesses
(and ACP terminal commands) inherit the app's environment, so
`CodeLead.Executor.EnvScrub` strips the instance-internal variables —
`WORKSPACE_ROOT`, `DATABASE_URL`, `SECRET_KEY_BASE`, `ENCRYPTION_KEY` and
the rest of the names read in `config/runtime.exs` — before spawning.
An inherited `WORKSPACE_ROOT` once let an agent's `mix test` (run inside a
task worktree on CodeLead's own repo) resolve the instance's workspace root
and wipe it. Operator-exported vars outside that denylist still pass
through, and a project env store entry always wins over the scrub, even
under an internal name — a `DATABASE_URL` meant for the *target* app
reaches the agent untouched.

**No language toolchain ships in the image**, and that is the limit worth
knowing before an agent tries to verify its own work. The release bundles ERTS
under `/app`, but neither `mix` nor `elixir` is on `PATH`; `npm` stays behind
in the harness stage (only `nodejs` is copied forward); nothing else — Python,
Go, Rust, a JVM — is there at all. An agent working on an Elixir project
therefore cannot run `mix test` in the stock image, however well the shell
works.

Extend the image with whatever the projects you point CodeLead at need to
build and test themselves:

```dockerfile
FROM ghcr.io/emischorr/codelead:latest
USER root
RUN apk add --no-cache elixir     # or nodejs npm / python3 / go / cargo …
USER elixir
```

Then swap `image:` for a `build:` in
[`deployment/docker-compose.yml`](../deployment/docker-compose.yml), or point
`image:` at your own tag.

Anything `apk` installs lands on `PATH` and needs nothing further. A toolchain
that installs **elsewhere** (`/opt/...`, a version manager under `$HOME`) does
need one more line, because Alpine's `/etc/profile` assigns `PATH` outright
instead of extending it and the harness builds its shell snapshot from a login
shell — so a bare `ENV PATH=` in your layer will not survive into the agent's
commands. Drop a profile snippet next to the image's own:

```dockerfile
RUN printf 'export PATH="/opt/mytool/bin:$PATH"\n' > /etc/profile.d/mytool.sh
```

> A `PATH` entry in the **project env store** replaces the inherited one for
> the harness (`Port.open`'s `env:` merges into the parent environment, so a
> key that is present wins), which hides every tool above. The same caveat as
> *Harness prerequisites*, one layer down: it does not help the agent find its
> tools, it stops it.

Extending the image is the workaround for **local** execution's single
shared environment. The per-repository fix is devcontainer execution:
enable it on the repository (Settings → Project → Repositories, or
`repositories.env_kind: :devcontainer`) and switch the task's Execution
to Container — the agent then runs inside the environment the repo's
own `.devcontainer` configuration describes, provisioned by the
official devcontainer CLI over the docker socket
([ADR-0003](adr/0003-container-execution-model.md),
[ADR-0009](adr/0009-devcontainer-execution.md)). Whatever works in VS
Code or Codespaces works here: a plain `"image":`, a
`build.dockerfile`, a `dockerComposeFile` with services, `features`,
lifecycle hooks, `remoteUser`, `runArgs`. Container execution is the
one licensed feature — `:container_execution_env` — so an instance with
no `LICENSE_KEY` can enable the environment but cannot select or start
Container execution; see [`licensing.md`](licensing.md). There is
deliberately no fallback environment: an undeclared one blocks the
start, and an enabled repo without a devcontainer config in the
worktree fails the run visibly. `agents.tool_features` remains a
dormant seam. Any musl (Alpine) or glibc (Debian bookworm or newer)
base works: the environment's libc is probed at run start and the
matching harness flavor is used (ADR-0006). The harness ships its own
runtime — a staged directory on the workspace holding bun plus the
adapter's package tree (ADR-0007), assembled in-docker on first use —
so devcontainer images need no node, nothing harness-related.

### Container execution in dev

Dev needs a `LICENSE_KEY` granting `:container_execution_env` — the gate
applies to a dev instance exactly as it does to a deployed one, and there
is no config override. Mint yourself an `owner` key
(see [`licensing.md`](licensing.md)) and export it from `.envrc`.

The BEAM runs on the host in dev, so task environments bind-mount the
workspace at its real path — Docker Desktop's file sharing must cover
it. The devcontainer CLI is a dev prerequisite:
`npm i -g @devcontainers/cli` (the published image ships it). Then:
enable Devcontainer on a repository (the select in the repository
modal — a `devcontainer` badge confirms it), set a task's Execution to
Container, and Start. The first `devcontainer up` for a repo may build
images and install features (minutes, streamed to the log while the
task sits dispatched); later ups reuse the environment and are
near-instant. This repo's own `.devcontainer` prewarms deps and the
asset binaries into the image, so once the layer cache is warm a fresh
task's `up` costs a container start and an app compile, not a
`deps.get`. The **first** container run per libc family additionally
stages the matching harness runtime in a one-shot bun container
(ADR-0005/0007) — a few minutes, logged as `staging container harness
…`; it needs docker-side network access to the npm registry, and a
failed staging lands as a `run_failed` attention with the remedy.
Air-gapped or picky setups can bypass the build by pointing
`HARNESS_SOURCE` at a pre-built binary. `mix test --only docker` runs
the real-daemon integration test, and `mix test --only devcontainer`
the real-CLI one.

The quickest end-to-end check is dogfooding: CodeLead's own repo ships
a `.devcontainer` (app + Postgres via compose). Point your dev instance
at the checkout, set the repository to Devcontainer with
`preview_port: 4001` (4000 is the instance's own port, which is
blocked) and `preview_command: PORT="$PREVIEW_PORT" mix phx.server`,
and run a container task — the Review tab's Open preview then shows
CodeLead itself through `/preview/<task_id>/` (or, with
`PREVIEW_DOMAIN` set, on its own subdomain — where the previewed
CodeLead's session cookie works unrenamed, so you can even log into
it). The repo's `config/dev.exs` and `config/test.exs` read `PGHOST`
(the compose `db` service) and `DEVCONTAINER` (bind `0.0.0.0` instead
of loopback) for exactly this.

Migrations are not automatic *inside the image*: `/app/bin/server` is the
default command, and `/app/bin/migrate` (which evals
`CodeLead.Release.migrate/0`) has to be run separately. The compose stack in
[`deployment/`](../deployment/) does that with a one-shot `migrate` service
the app waits on, so a deployed instance migrates itself on every
`docker compose up`.

## Workspace layout (planned)

```
<WORKSPACE_ROOT>/
  repos/<repo-name>/        # managed base clone per linked repository
  worktrees/task-<id>/      # git worktree per :repo-target task
  tasks/<id>/               # task folder per :folder-target task
```

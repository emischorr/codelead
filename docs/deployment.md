# Deployment (last updated: 2026-08-19)

How to run CodeLead on a server. For the five-minute version see the
README's *Getting started*; for the full environment variable reference see
[`configuration.md`](configuration.md). This document covers the parts that
only matter once the instance is not on your laptop.

## The HTTP posture

**CodeLead serves plain HTTP and knows nothing about TLS.** There is no
https→http redirect, no HSTS header, no `force_ssl`. `config/prod.exs` says
why:

> TLS termination, http→https redirect, and HSTS are the reverse proxy's
> job. The app serves plain HTTP; operators put whatever proxy they like in
> front.

This is the ordinary self-host arrangement. Some operators already terminate
TLS at an ingress, a load balancer, or a home-lab proxy; the ones who don't
have their own preference about what to run. An app that insisted on
redirecting to `https://` would be wrong for both groups.

The consequence: **nothing stops you exposing port 4000 to the internet in
the clear.** Passwords and session cookies would cross the network
unencrypted. Put a proxy in front, or keep it on a private network.

## The image

`ghcr.io/emischorr/codelead:latest`, built from the repo's `Dockerfile`.

| | |
|---|---|
| Platforms | `linux/amd64`, `linux/arm64` |
| Base | Alpine; Elixir 1.20.3 / Erlang 28.5.0.5 in the build stage |
| User | Starts as **root**: the entrypoint (`docker-entrypoint.sh`) owns the `DATA_ROOT` roots and grants itself the docker socket's group — the two things that would otherwise need host preparation — then drops to `elixir` (uid/gid 1000) via `su-exec` before starting the release. The app itself never runs as root (and cannot bind ports below 1024); `user: "1000:1000"` skips the entrypoint's setup for hardened deployments |
| Bundled harness | `@agentclientprotocol/claude-agent-acp` at `/opt/harness` (on `PATH`) for **local** execution. The container-execution harness is not baked in — a runtime directory is staged into the workspace over the docker socket on the first container run per libc flavor (ADR-0007). Codex is bring-your-own, local-only |
| Docker CLI | `docker-cli` (no daemon) — drives sibling task containers through the mounted socket |
| Entrypoints | `/app/bin/server` (default `CMD`) and `/app/bin/migrate` |
| Mutable state | `$DATA_ROOT/home` (`HOME`) and `$DATA_ROOT/workspace` (`WORKSPACE_ROOT`); the image defaults to `/data/*`, which the compose stack overrides to follow the `DATA_ROOT` bind |

`/app/bin/migrate` evals `CodeLead.Release.migrate/0`
(`lib/code_lead/release.ex`), which runs every pending migration for each repo
in `:ecto_repos`. It is safe to run repeatedly and safe to run when there is
nothing to do.

Building and publishing it yourself — the commands are also in the
`Dockerfile` header:

```bash
docker buildx create --name multiarch --driver docker-container --use   # once
docker login ghcr.io                                                    # once

docker buildx build --platform=linux/amd64,linux/arm64 --no-cache \
  -t ghcr.io/OWNER/code_lead:0.1.0 -t ghcr.io/OWNER/code_lead:latest --push .
```

See [`configuration.md`](configuration.md#docker-image) for the build args.

## The compose stack

[`deployment/`](../deployment/) holds a working three-service stack. It is the
reference — the README's instructions describe these files rather than
restating them, so there is only one thing to keep correct.

Secrets come from a `.env` beside `docker-compose.yml`, which compose loads
automatically. The repo ships **`.env.example`**, not `.env`: the template is
committed, and `.env` is gitignored so a filled-in copy cannot be committed
back. `cp .env.example .env` and fill in all four values before the first
`docker compose up`.

**`db`** — `postgres:18-alpine`, with the named volume `pg` mounted at
`/var/lib/postgresql` (the Postgres 18 image keeps its data one level below
that). `init-app-db.sh` is mounted into `/docker-entrypoint-initdb.d/` and
runs **only on first init of an empty volume**, creating a `codelead` role
and a `codelead` database owned by it — the app does not connect as the
superuser. Changing `APP_DB_PW` later will *not* re-run the script; alter the
role by hand.

**`migrate`** — the same image with `command: ["/app/bin/migrate"]` and
`restart: "no"`. It waits for the database healthcheck, migrates, and exits.

**`app`** — `command: ["/app/bin/server"]`, published on `4000:4000`. It
depends on `migrate` with `condition: service_completed_successfully`, so it
only boots once migrations have applied cleanly. A failed migration stops the
deploy instead of starting an app against a half-migrated schema.

Because `migrate` runs on every `docker compose up`, upgrades need no extra
step.

### The data directory

The `app` service bind-mounts the host directory `DATA_ROOT` (set in `.env`)
into the container **at the identical path**. It holds the agent harness's
configuration and session state (`$DATA_ROOT/home`, the container's `HOME`)
and every base clone, task worktree, and task folder
(`$DATA_ROOT/workspace`, `WORKSPACE_ROOT`) — including work that hasn't been
merged yet. No preparation needed: a missing bind source is auto-created by
the daemon, and the image's entrypoint hands the directory to the app user
(uid 1000) before dropping privileges — see [The image](#the-image). What
lands on disk is owned by uid 1000, which on a typical single-admin host is
the operator's own account.

The identical-path rule is load-bearing, not cosmetic
([ADR-0009](adr/0009-devcontainer-execution.md)): task devcontainers are
provisioned by the devcontainer CLI *inside* the app container, but every
bind source it emits — the repo's own compose file paths, the CLI's
workspace mount — is resolved by the **host** daemon in the host's mount
namespace. Only when the host path and the in-container path coincide does
the daemon find the worktree; anything else makes it silently create an
empty directory and mount that, and the devcontainer fails on its first
lifecycle hook ("no mix.exs was found", missing `package.json`, …).

This *reverses* the earlier advice. Stacks deployed before ADR-0009 used a
named volume (`codelead-data` at `/data`, announced via `WORKSPACE_VOLUME`),
which worked for the old image-based executor because CodeLead authored every
mount by volume name — but a volume's data has no stable host path, so
devcontainer execution under it is impossible and such tasks now refuse to
start with a message pointing here. **Migrating an existing stack** (with the
stack down, after setting `DATA_ROOT` in `.env`):

```bash
docker run --rm -v codelead-data:/from -v /srv/codelead/data:/to alpine cp -a /from/. /to/
```

(`cp -a` preserves the volume's uid-1000 ownership, and the entrypoint owns
the directory roots on the next start — no chown needed.)

(Stacks older than the `name: codelead-data` pin hold their data in
`deployment_codelead-data` — substitute that name.) Afterwards `docker volume
rm codelead-data` reclaims the space. Also check the host for phantom
directories a failed pre-migration devcontainer attempt left behind — the
daemon auto-creates the missing bind source, so an empty host-side
`/data/workspace/…` tree may exist; remove it.

**Paths recorded before the move heal themselves at boot.** The database
holds absolute paths (base clones, task worktrees), and git's worktree
metadata holds more; after the root moves the app rewrites the rows to the
new location where the files exist, runs `git worktree repair`, and logs what
it did — and it never follows a recorded path outside the current
`WORKSPACE_ROOT`, so a stale row can't land a clone in the container's
ephemeral layer again ([ADR-0012](adr/0012-workspace-path-reconciliation.md)).

What it **cannot** heal: base clones that were (re)created *inside a
container's ephemeral layer* on a stack that ran with a stale root — those
died with the container, taking any commits that existed only there;
worktrees checked out against such a clone hold their files but not their
history. Recovering such a stack by hand:

1. Copy anything wanted out of the affected
   `$DATA_ROOT/workspace/worktrees/task-<n>` directories (the checked-out
   files are intact).
2. Clear the dead references so the next run starts fresh:

   ```sql
   UPDATE repositories SET base_clone_path = NULL WHERE base_clone_path LIKE '/data/%';
   UPDATE tasks SET worktree_path = NULL, branch_name = NULL WHERE worktree_path LIKE '/data/%';
   ```

   (Also clear task rows whose worktree exists under the new root but whose
   diff still errors with `not a git repository: /data/…` — their base clone
   is gone and `git worktree repair` has nothing to repair against.)
3. Remove the orphaned worktree directories — files a container run created
   as root need root:
   `docker compose exec -u 0 app rm -rf $DATA_ROOT/workspace/worktrees/task-<n>`.

The next dispatch re-clones missing repositories under the bind mount.

### The docker socket

The `app` service mounts `/var/run/docker.sock`, which is what lets a task
run in the environment its repository's `.devcontainer` configuration
describes — the bundled devcontainer CLI provisions it through this socket.
**A mounted docker socket is root-equivalent on the host** — anyone who
controls the CodeLead process can start privileged containers. That trade is
accepted, and stated here rather than discovered, under the single-tenant,
self-hosted assumption ([ADR-0003](adr/0003-container-execution-model.md),
[ADR-0009](adr/0009-devcontainer-execution.md)). To run without
container execution, remove the socket mount — container-selecting tasks
then refuse to start with a clear message. (The `DATA_ROOT` bind stays
either way; it is where all mutable state lives.)

**Socket permissions are handled by the entrypoint.** On a Linux host the
socket is `root:docker 0660` while the app runs as uid 1000 — the entrypoint,
still root at that point, reads the socket's owning gid, grants the service
user that group, and only then drops privileges. Nothing to configure. Two
consequences worth knowing:

- The gid is read **once, at container start**. If the socket is mounted or
  its group changed afterwards, restart the stack.
- A **hardened deployment** that sets `user: "1000:1000"` on the `app`
  service skips the root entrypoint entirely — and takes the host
  preparation back: create and `chown -R 1000:1000` the `DATA_ROOT`
  directory yourself, and pass the socket's group id via
  `group_add: ["<gid>"]` (`stat -c '%g' /var/run/docker.sock` on the host;
  numeric — the image has no `docker` group to resolve a name against).
  Getting it wrong surfaces as `permission denied` on every docker call,
  with container tasks refusing to start with a message saying so.

Under **rootless Docker** there is no `/var/run/docker.sock`; the socket lives
at `$XDG_RUNTIME_DIR/docker.sock`. Mount that path instead and set `DOCKER_HOST`
on the `app` service — the CLI honours it ([`configuration.md`](configuration.md)).

Verify mount and permissions from inside the container:

```bash
docker compose exec app ls -l /var/run/docker.sock
docker compose exec app docker info      # server info, not an error
```

Everything a devcontainer config references resolves against the **host**
daemon: an `"image":` is pulled there, a `build.dockerfile` is built there
(the image ships the compose and buildx CLI plugins for exactly this), and
compose services run there. The repo carries its own environment, so nothing
needs to be hand-built or pre-copied onto the deployment host — the first
`devcontainer up` per task does whatever pulling and building the config
demands, and later ups reuse it.

Container execution is also the one **licensed** feature
(`:container_execution_env`). An instance with no `LICENSE_KEY` cannot select
or start it, whether or not the socket is mounted; everything else runs
unrestricted on the community tier. See [`licensing.md`](licensing.md).

### Container-task live previews

The Review tab's live preview proxies `/preview/:task_id/` to the task's dev
server — started with the one-click Start preview button (repositories with a
`preview_command`) or by hand in the task's Terminal
([ADR-0008](adr/0008-preview-and-terminal.md),
[ADR-0009](adr/0009-devcontainer-execution.md)).
For **local** tasks nothing needs configuring — the server runs in the app's
own process space and the proxy dials loopback. For **container** tasks a
relay sidecar (`codelead-preview-<task_id>`, image `PREVIEW_RELAY_IMAGE`,
default `alpine/socat` — pulled on first use) joins the task container's
network and publishes the declared `preview_port` on the host, and the app
dials that published port. This also works with zero configuration: the
address is auto-detected (`CodeLead.PreviewGateway.Address`) — loopback when
the BEAM runs directly on the docker host, the docker bridge gateway (asked
from the daemon itself, so custom subnets resolve too) when the app runs in
a container, as in this stack. The port binds to that address only — never a
public interface — and browsers always go through the authenticated proxy.

Only setups the detection cannot cover — a remote docker daemon, Docker
Desktop, a bridge whose gateway is not reachable from the app container —
need the manual override, on the app service:

```yaml
PREVIEW_PUBLISH_IP: <address the app container can reach>   # e.g. 172.17.0.1
PREVIEW_UPSTREAM_HOST: <the same address>
```

A relay created *before* the address changed carries the old binding; the
next preview touch recreates it on the current one — always safe, because no
agent exec runs inside a relay. The websocket rules
below (`Upgrade`/`Connection` pass-through, no buffering) apply to `/preview/*`
exactly as they do to `/live/websocket`, so a *location-scoped* proxy config
must cover this path too — and, when subdomain previews are enabled, the
[wildcard vhost](#wildcard-vhost-for-subdomain-previews) as well.

That is the operator's half. What the server *inside* the environment has to
do — bind `0.0.0.0`, listen on exactly the declared port — and where its
companion services come from is in
[`configuration.md`](configuration.md#serving-a-preview-from-a-container-task).

**Troubleshooting "Nothing is listening at 127.0.0.1:\<high port\>".** For a
container task, *loopback plus an ephemeral port* on this page means the
relay exists and published a host port (that's where the number comes from),
but the app is dialing its *own* container's loopback — either the
auto-detection fell back (its one-time warning, `could not auto-detect the
docker bridge gateway`, is in the app log) or an explicit
`PREVIEW_UPSTREAM_HOST` override points at loopback. Nothing done inside the
task container — restarting the dev server, changing ports — can fix it.
Confirm it in one step from the deploy host:

```bash
curl -m 3 http://127.0.0.1:<high port>/                          # host → relay: works
docker compose exec app curl -m 3 http://127.0.0.1:<high port>/  # app → its own loopback: refused
```

Relay and docker failures also log with the underlying docker error; check
`docker compose logs app` before digging deeper.

### What you must add

`restart: unless-stopped` on `db` and `app`, so the instance survives a host
reboot.

## URLs: `PHX_HOST`, `SCHEME`, `URL_PORT`, `ALLOWED_HOSTS`

Four variables decide what the app thinks its own address is. They split into
two independent jobs:

- **The canonical URL** — `PHX_HOST` + `SCHEME` + `URL_PORT`. These build the
  absolute URLs in login links, user invites, and email-change confirmations
  (`lib/code_lead_web/live/user_live/login.ex`, `settings_live/users.ex`).
  There is exactly one canonical URL, whatever else the instance answers to.
- **The origin check** — `PHX_HOST` + `ALLOWED_HOSTS`. Together they list
  every address a browser may open the LiveView WebSocket from.

### The origin check

Phoenix compares the WebSocket handshake's `Origin` header against the allowed
list and rejects anything else with a 403. A rejection is the confusing failure
where the page renders fine and then nothing is interactive — the server-rendered
response is never origin-checked, so only the live parts die. Symptoms are a
dead UI, repeated connection attempts in the browser console, and
`Could not check origin for Phoenix.Socket transport` in the app log.

`PHX_HOST` is always allowed. `ALLOWED_HOSTS` is a comma-separated list of
additional addresses:

- a **bare host** — `192.168.1.50`, `codelead.local`, `*.example.com` —
  matches that host on any scheme and any port;
- a **full origin** — `http://192.168.1.50:4000` — must match exactly;
- `*` on its own **disables the origin check entirely**. Useful when the
  address is dynamic (Tailscale, a rotating LAN IP), at the cost of Phoenix's
  cross-origin WebSocket protection. Only do this on a network you trust.

Note that `PHX_HOST` itself matches on host only, ignoring scheme and port —
so `PHX_HOST: codelead.example.com` accepts both `https://codelead.example.com`
and `http://codelead.example.com:4000`.

### Recipes

`PORT` is not in that list. It sets the port the app binds to inside the
container and has no effect on generated links — `URL_PORT` is what appears in
them, and it defaults to the standard port for `SCHEME` (443 for `https`, 80
for `http`). Keeping the two apart is what lets an instance listen on 4000 as
an unprivileged user while telling the world it lives at `https://host`.

**Direct HTTP, no proxy** — reachable at `http://codelead.example.com:4000`:

```yaml
      PHX_HOST: codelead.example.com
      SCHEME: http
      PORT: "4000"
      URL_PORT: "4000"
```

Both ports appear because both are true here: the app binds 4000 and users
type 4000. They are still separate settings — with `ports: - "8080:4000"`
published instead, `PORT` stays `4000` and `URL_PORT` becomes `8080`.

**Behind a TLS-terminating proxy on 443** — reachable at
`https://codelead.example.com`:

```yaml
      PHX_HOST: codelead.example.com
      SCHEME: https
      # URL_PORT deliberately unset — defaults to 443, so links carry no
      # port suffix. PORT stays at its 4000 default; the proxy talks to that.
```

For a proxy on some other port, set `URL_PORT` to the port people type — e.g.
`URL_PORT: "8443"` for `https://codelead.example.com:8443`. Never move `PORT`
to a privileged port to fix links: the container's unprivileged uid 1000
cannot bind it and the app will fail to start.

**Both at once** — `https://codelead.example.com` through the proxy *and*
`http://192.168.1.50:4000` straight from the LAN:

```yaml
      PHX_HOST: codelead.example.com   # canonical: what emailed links use
      SCHEME: https                    # ...and the canonical address is TLS
      # URL_PORT deliberately unset — 443
      ALLOWED_HOSTS: "192.168.1.50"
```

`SCHEME` and `URL_PORT` describe the *canonical* address only, so they follow
the proxied one. The LAN address needs no scheme or port setting of its own —
it only has to pass the origin check, and a bare host in `ALLOWED_HOSTS`
matches any scheme and port.

Keep `ports: - "4000:4000"` published so the direct path exists, and point the
proxy at that same port. Pick the proxied address as `PHX_HOST`: it is the one
that works from anywhere, and it is what login links and invites will say.

Two consequences worth knowing:

- **Sessions are per-host.** Cookies set on `192.168.1.50` and on
  `codelead.example.com` are separate, so the two addresses are separate
  logins. This is browser behaviour, not something the app can bridge.
- **Emailed links always point at `PHX_HOST`.** A login link opened on the LAN
  will still send the browser to the canonical address.

## Reverse proxy configuration

Whatever you put in front must:

- **Forward WebSocket upgrades.** The entire UI is LiveView; without
  `Upgrade`/`Connection` passthrough on `/live/websocket` the app loads and
  then goes inert.
- **Use a long read timeout.** Agent runs stream for minutes at a time and
  the WebSocket stays open across them. The usual 60-second default will cut
  runs off mid-flight.
- **Not buffer responses**, so streamed transcript and diff updates arrive as
  they are produced.
- **Set `X-Forwarded-For` / `X-Forwarded-Proto`** — the app does not act on
  them today (nothing rewrites on `x-forwarded-proto` now that `force_ssl` is
  off), but they cost nothing and matter if that ever changes.

**Caddy** — the short version, with automatic certificates:

```caddyfile
codelead.example.com {
	reverse_proxy localhost:4000
}
```

**nginx:**

```nginx
server {
	listen 443 ssl http2;
	server_name codelead.example.com;

	ssl_certificate     /etc/letsencrypt/live/codelead.example.com/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/codelead.example.com/privkey.pem;

	location / {
		proxy_pass http://127.0.0.1:4000;
		proxy_http_version 1.1;

		proxy_set_header Upgrade    $http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host       $host;
		proxy_set_header X-Real-IP  $remote_addr;
		proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;

		proxy_read_timeout 3600s;
		proxy_buffering off;
	}
}
```

`Host $host` is what keeps `PHX_HOST` and the browser's hostname agreeing.

### Wildcard vhost for subdomain previews

Only needed when the instance opts into subdomain previews
([`PREVIEW_DOMAIN`](configuration.md#subdomain-previews-preview_domain)):
the per-task hosts `task-<id>.preview.example.com` must reach the same
app, so the proxy grows one wildcard vhost with the same websocket and
buffering rules as the main one.

**Caddy** — one extra site block. The catch is the certificate: a
wildcard cert can only be issued through a **DNS-01** challenge, so
Caddy needs credentials for your DNS provider (via the provider's DNS
plugin — the `dns` directive below):

```caddyfile
*.preview.example.com {
	tls {
		dns <provider> <credentials>
	}
	reverse_proxy localhost:4000
}
```

**nginx** — a second `server` block; the wildcard certificate has to be
obtained the same way (e.g. certbot with a DNS plugin):

```nginx
server {
	listen 443 ssl http2;
	server_name *.preview.example.com;

	ssl_certificate     /etc/letsencrypt/live/preview.example.com/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/preview.example.com/privkey.pem;

	location / {
		proxy_pass http://127.0.0.1:4000;
		proxy_http_version 1.1;

		proxy_set_header Upgrade    $http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host       $host;
		proxy_set_header X-Real-IP  $remote_addr;
		proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;

		proxy_read_timeout 3600s;
		proxy_buffering off;
	}
}
```

Plus a wildcard DNS record `*.preview.example.com` pointing at the same
host, and `PREVIEW_DOMAIN=preview.example.com` in the app's `.env`.
`Host $host` is load-bearing here too — it is how the app tells the
tasks apart.

## Upgrading

```bash
docker compose pull
docker compose up -d
```

`up -d` recreates the app container, and a graceful shutdown now **stops every
preview server and terminal session** rather than leaving them running
(ADR-0013). Check the two tiles at the bottom of the dashboard first: *Preview
servers* and *Terminal sessions* name the tasks whose session the restart will
end.

`migrate` reruns as part of `up` and the app waits for it, so schema changes
apply themselves. Watch it if you want the reassurance:

```bash
docker compose logs migrate
```

`pull` only refreshes the image. Changes to the compose file itself reach the
running container only when it is recreated, which `up -d` does once the file
on disk actually differs. Take the current
[`deployment/docker-compose.yml`](../deployment/docker-compose.yml) over yours,
and read [The data directory](#the-data-directory) before you do: a stack
that predates the `DATA_ROOT` bind keeps its workspace in a named volume, and
adopting the new file without the one-time copy starts you on an empty
directory. A stack from the `group_add`/`DOCKER_GID` era simply drops both —
the entrypoint took that job over — and can delete `DOCKER_GID` from `.env`.

## Backups

Three things, and all three are needed to restore:

1. **The database.** `docker compose exec db pg_dump -U codelead codelead > backup.sql`
2. **The `DATA_ROOT` directory**, if you have in-flight work — unmerged task
   branches live in worktrees there, not in the database.
3. **`ENCRYPTION_KEY`.** Provider credentials and project secrets are
   encrypted at rest with it. A database restored without the matching key
   still holds those rows, but nothing can read them and there is no
   recovery — you would re-enter every credential.

Keep the key somewhere other than the machine you are backing up.

## Before you expose it

Known gaps that change how you'd deploy this:

- **There is no authorization.** A user's role is stored and displayed but
  never checked; every signed-in user reaches every settings page, including
  provider credentials and project secrets. Treat every account as an admin
  account.
- **Outbound email is off unless you configure it.** Without `SMTP_HOST` the
  instance has no transport, and the surfaces that need one are hidden rather
  than left to fail silently: no magic-link form on the login page, no
  magic-link invite option in Settings → Users. Username + password (set from
  `/setup` and `/settings/users`) is the default way to create and log in to
  accounts and needs no email at all. Set `SMTP_HOST` (see
  [`configuration.md`](configuration.md)) to turn the email paths on. One
  loose end remains either way: `/users/settings/email` still reports that a
  confirmation link was sent, which is untrue on an instance without mail.
- **There is no health-check endpoint.** No `/health` route exists, and the
  compose file has no healthcheck on `app` — an orchestrator has nothing to
  probe but the TCP port.
- **The container holds real credentials and real repository access.** Forge
  tokens, model provider keys, and clones of your repositories all live
  inside it, and agents execute code there — with a real shell and the GNU
  CLI tools, which is exactly what makes an agent able to run your linters
  and tests (see *What the agent can run inside the image* in
  [`configuration.md`](configuration.md)). It is not a service to put on a
  public address for convenience.
- **The compose stack mounts the docker socket** for container execution — a
  mounted `/var/run/docker.sock` is root-equivalent on the host; the
  single-tenant, self-hosted assumption is what makes that acceptable
  ([ADR-0003](adr/0003-container-execution-model.md)). See *The docker
  socket* above for how to opt out.

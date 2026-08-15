# Deployment (last updated: 2026-08-15)

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
| User | `elixir`, uid/gid 1000 — **not root**, so it cannot bind ports below 1024 |
| Bundled harness | `@agentclientprotocol/claude-agent-acp` at `/opt/harness` (on `PATH`) for **local** execution. The container-execution harness is not baked in — a runtime directory is staged onto the data volume over the docker socket on the first container run per libc flavor (ADR-0007). Codex is bring-your-own, local-only |
| Docker CLI | `docker-cli` (no daemon) — drives sibling task containers through the mounted socket |
| Entrypoints | `/app/bin/server` (default `CMD`) and `/app/bin/migrate` |
| Mutable state | `/data/home` (`HOME`) and `/data/workspace` (`WORKSPACE_ROOT`) |

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

### The data volume

The `app` service mounts the **named volume** `codelead-data` at `/data`. It
holds the agent harness's configuration and session state (`/data/home`) and
every base clone, task worktree, and task folder (`/data/workspace`) —
including work that hasn't been merged yet. Without the mount, `docker
compose down` would discard all of that.

Keep it a *named* volume rather than a bind mount. The container executor
creates sibling containers through the host docker socket and hands them the
workspace **by volume name** (`WORKSPACE_VOLUME`) — a bind path from inside
the app container would be resolved by the host daemon in the *host's* mount
namespace and point at the wrong place, or nowhere
([ADR-0003](adr/0003-container-execution-model.md)). `HOST_DATA_ROOT` is the
escape hatch for operators who insist on a bind mount.

The compose file pins the volume's name (`name: codelead-data`) so
`WORKSPACE_VOLUME` stays correct regardless of the compose project name.
**Upgrade note:** a stack created before this pin holds its data in a volume
compose named `deployment_codelead-data`. Pinning on such a stack makes
compose create a *new, empty* `codelead-data` — either keep the old name (drop
the `name:` line and set `WORKSPACE_VOLUME: deployment_codelead-data`), or
migrate the data once
(`docker run --rm -v deployment_codelead-data:/from -v codelead-data:/to
alpine cp -a /from/. /to/`) with the stack down.

### The docker socket

The `app` service mounts `/var/run/docker.sock`, which is what lets a task
run in its own container built from the repository's declared image. **A
mounted docker socket is root-equivalent on the host** — anyone who controls
the CodeLead process can start privileged containers. That trade is accepted,
and stated here rather than discovered, under the single-tenant, self-hosted
assumption ([ADR-0003](adr/0003-container-execution-model.md),
[ADR-0004](adr/0004-container-executor-iteration-two.md)). To run without
container execution, remove the socket mount and the `WORKSPACE_VOLUME` env —
container-selecting tasks then refuse to start with a clear message.

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

## Upgrading

```bash
docker compose pull
docker compose up -d
```

`migrate` reruns as part of `up` and the app waits for it, so schema changes
apply themselves. Watch it if you want the reassurance:

```bash
docker compose logs migrate
```

## Backups

Three things, and all three are needed to restore:

1. **The database.** `docker compose exec db pg_dump -U codelead codelead > backup.sql`
2. **The `/data` volume**, if you have in-flight work — unmerged task
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
- **Outbound email does not work.** Production has no mail adapter
  configured (`config/config.exs` sets Swoosh's local adapter, whose preview
  route is dev-only), so magic-link invites and email-change confirmations go
  nowhere. Create users with a password from Settings → Users.
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

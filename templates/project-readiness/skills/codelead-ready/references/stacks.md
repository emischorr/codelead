# Per-stack recipes

Read only the section for the stack you detected.

Every section has the same four parts: the **preview command** to enter in
CodeLead, the **base path** edit, the **host binding**, and a starter
**devcontainer**. A fifth part, *host allowlist*, appears where the framework
has one — those all see the **upstream** `host:port` (`127.0.0.1:<port>` for a
local task, the relay's address for a container task), never the browser's
host, which arrives separately as `x-forwarded-host`.

---

## Vite (and Vite-based: Vue, Svelte, SolidStart, Astro dev)

Nothing in the repo needs to change — every knob is a flag.

**Preview command**

```
npm run dev -- --host --port "$PREVIEW_PORT" --base "$PREVIEW_BASE_PATH/"
```

The trailing slash is deliberate: `PREVIEW_BASE_PATH` carries none, and Vite
wants one. Unset, this degrades to `--base "/"`, which is the default.

**Host binding** — `--host`, as above.

**Host allowlist** — Vite 5.4+/6 blocks unknown hosts. If the preview shows
*"Blocked request. This host is not allowed."*, add to `vite.config`:

```js
server: { allowedHosts: true }   // dev config only
```

**Devcontainer starter** — `.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "app",
  "image": "mcr.microsoft.com/devcontainers/javascript-node:22",
  "remoteUser": "node",
  // Installs belong here, never in the preview command.
  "postCreateCommand": "npm ci"
}
```

---

## Next.js

**Preview command**

```
next dev -H 0.0.0.0 -p "$PREVIEW_PORT"
```

**Base path** — `basePath` is config-only, so this one edit is unavoidable.
In `next.config.js` / `next.config.mjs`:

```js
const basePath = process.env.PREVIEW_BASE_PATH || ""
export default { basePath, assetPrefix: basePath || undefined }
```

Empty string is Next's own default, so nothing changes outside CodeLead.
Use `next/link` and `next/image` everywhere — they apply `basePath`; a raw
`<a href="/…">` does not.

**Host binding** — `-H 0.0.0.0`, as above.

**Devcontainer starter** — same as the Vite starter.

---

## Phoenix

The stack with the most to get right, and the one CodeLead itself uses — its
own `config/dev.exs` is a working copy of everything below.

**Preview command**

```
PORT="$PREVIEW_PORT" mix phx.server
```

A leading `VAR=value` is allowed; chaining with `&&` is not.

**Base path and host binding** — in `config/dev.exs`, on the endpoint:

```elixir
config :my_app, MyAppWeb.Endpoint,
  # 0.0.0.0 inside a container, loopback otherwise. Set DEVCONTAINER in the
  # devcontainer's environment (see the starter below).
  http: [
    ip: if(System.get_env("DEVCONTAINER"), do: {0, 0, 0, 0}, else: {127, 0, 0, 1}),
    port: String.to_integer(System.get_env("PORT") || "4000")
  ],
  # Serves ~p routes and static paths under the preview mount. "/" when unset.
  url: [path: System.get_env("PREVIEW_BASE_PATH", "/")],
  # The proxied `host` header will not match the configured URL.
  check_origin: false
```

**The LiveSocket loop — fix this even if the preview looks fine.**
`assets/js/app.js` ships with a literal `new LiveSocket("/live", …)` straight
from the generator. `url: [path: …]` cannot reach it, so under a path preview
that socket opens against **CodeLead's own** LiveView endpoint, which
completes the upgrade and rejects the join as stale. The client reads that as
a stale session and does a full page load — and the preview reloads itself a
couple of times a second, forever.

Render the path instead of hardcoding it:

```heex
<%!-- root.html.heex, in <head> --%>
<meta name="live-socket-path" content={MyAppWeb.Endpoint.path("/live")} />
```

```js
// assets/js/app.js
const path = document
  .querySelector("meta[name='live-socket-path']")
  .getAttribute("content")
const liveSocket = new LiveSocket(path, Socket, { /* … */ })
```

`Phoenix.Endpoint.path/1` applies the configured `:url` `:path`, so this stays
`/live` when `PREVIEW_BASE_PATH` is unset. Nothing to undo in production.

Then sweep for the two remaining escapes `url: [path: …]` does not cover:
absolute `url("/fonts/…")` in CSS (make it relative to where the bundle lands
— from `assets/css/app.css` to a top-level `fonts/` that is
`url("../../fonts/…")`), and literal `href="/"` in layouts (use `~p`).

**Devcontainer starter** — `.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "app",
  "dockerComposeFile": "compose.yml",
  "service": "app",
  "workspaceFolder": "/workspace",
  "remoteUser": "dev",
  "postCreateCommand": "mix setup"
}
```

`.devcontainer/compose.yml`:

```yaml
services:
  app:
    build: .
    command: sleep infinity
    volumes:
      - ..:/workspace:cached
    environment:
      PGHOST: db          # config/dev.exs reads this for the Repo host
      DEVCONTAINER: "true" # config/dev.exs binds 0.0.0.0 when set
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: my_app_dev
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 2s
      timeout: 3s
      retries: 15
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

`.devcontainer/Dockerfile` — the part that is easy to get wrong:

```dockerfile
# Pin to match the project's own .tool-versions. Debian rather than Alpine
# gives glibc, apt, and script(1) for a full PTY in the Terminal tab.
FROM hexpm/elixir:<elixir>-erlang-<otp>-debian-trixie-<date>

RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential inotify-tools postgresql-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Non-root, uid 1000: the devcontainer CLI remaps it to the workspace owner
# on Linux (updateRemoteUserUID), and CodeLead execs run as it via remoteUser.
RUN useradd -m -u 1000 -s /bin/bash dev

# Hex/rebar outside $HOME: CodeLead overrides HOME per task, so a toolchain
# living under ~ is invisible to agents.
# Build artifacts off the shared workspace mount: a host checkout's _build
# holds host-compiled artifacts (NIFs, esbuild/tailwind binaries) that would
# poison Linux builds, and vice versa.
ENV MIX_HOME=/opt/mix HEX_HOME=/opt/hex MIX_BUILD_ROOT=/opt/build LANG=C.UTF-8
RUN mkdir -p /opt/mix /opt/hex /opt/build && chown -R dev:dev /opt/mix /opt/hex /opt/build

USER dev
RUN mix local.hex --force && mix local.rebar --force
```

---

## Rails

**Preview command**

```
bin/rails server -b 0.0.0.0 -p "$PREVIEW_PORT"
```

**Base path** — in `config/environments/development.rb`:

```ruby
config.relative_url_root = ENV["PREVIEW_BASE_PATH"].presence
```

Use `*_path` helpers throughout; a literal `href="/"` escapes the mount.

**Host allowlist** — `config.hosts` blocks unknown `Host` headers. In
development either clear it (`config.hosts.clear`) or allow the upstream:

```ruby
config.hosts << ENV["PREVIEW_PORT"].then { "127.0.0.1:#{_1}" } if ENV["PREVIEW_PORT"]
```

**Devcontainer starter** — a compose setup like the Phoenix one, with:

```dockerfile
# Gems outside $HOME, for the same reason as Hex above.
ENV GEM_HOME=/opt/gems BUNDLE_APP_CONFIG=/opt/bundle BUNDLE_PATH=/opt/gems
ENV PATH=/opt/gems/bin:$PATH
RUN echo 'export PATH=/opt/gems/bin:$PATH' > /etc/profile.d/gems.sh
```

and `"postCreateCommand": "bundle install && bin/rails db:prepare"`.

---

## Django

**Preview command**

```
python manage.py runserver "0.0.0.0:$PREVIEW_PORT"
```

**Base path** — in settings:

```python
import os
FORCE_SCRIPT_NAME = os.environ.get("PREVIEW_BASE_PATH") or None
STATIC_URL = f"{FORCE_SCRIPT_NAME or ''}/static/"
```

**Host allowlist** — `ALLOWED_HOSTS` must accept the upstream host, not the
browser's. In development `ALLOWED_HOSTS = ["*"]` is the simple answer.

**Known limitation, not fixable here:** Django's double-submit CSRF breaks on
AJAX writes when the preview shares CodeLead's origin — client JS looks for
`csrftoken` and finds a namespaced name. Server-rendered form posts with
`{% csrf_token %}` keep working. The fix is on the operator's side (per-task
origins), not in this repo. Say so and move on.

**Devcontainer starter** — `mcr.microsoft.com/devcontainers/python:3.12`,
`"remoteUser": "vscode"`, dependencies into a venv outside `$HOME`:

```dockerfile
ENV VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH
RUN python -m venv /opt/venv && chown -R vscode:vscode /opt/venv
RUN echo 'export PATH=/opt/venv/bin:$PATH' > /etc/profile.d/venv.sh
```

and `"postCreateCommand": "pip install -r requirements.txt && python manage.py migrate"`.

---

## Static files

**Preview command**

```
python3 -m http.server "$PREVIEW_PORT" --bind 0.0.0.0 --directory dist
```

**Base path** — nothing to configure. Keep every asset path relative
(`./assets/…`, not `/assets/…`) and it works under any mount.

**Devcontainer starter** — any small image with python3 or a static server;
`"image": "mcr.microsoft.com/devcontainers/base:bookworm"` is enough.

---

## Anything else

State the contract and work it out from the framework's own documentation:

1. Listen on `$PREVIEW_PORT`, falling back to the project default when unset.
2. Bind `0.0.0.0`.
3. Serve every generated URL under `$PREVIEW_BASE_PATH` — look for the
   framework's term: base path, base href, script name, mount point, path
   prefix, `relative_url_root`.
4. If the framework has a host allowlist, let the upstream host through.
5. If there is no such setting at all, say so — that project needs the
   operator to give each task its own origin, and no repo change substitutes.

# 0008 — Live preview via in-app path proxy; terminal over the LiveView socket

## Status

Accepted (2026-08-16). Superseded in part by ADR-0009 (published-ports
upstream resolution — a relay sidecar replaces `-p`-at-create), by
ADR-0010 (post-spawn terminal resize; terminals for folder targets),
and by ADR-0011 (the embedded preview surface — previews open in a new
tab — and the single-gateway assumption — `SubdomainProxy` exists
behind `PREVIEW_DOMAIN`), and by ADR-0013 (closing a session's Port does
not stop the process behind it — sessions trap exits and stop by
process group).

## Context

Reviewing UI/web work from a diff cannot judge interaction, animation,
or UX — the Review gate degrades into theater for exactly the work
agents are best at. The review contract chosen is a **URL**: something
in the task's execution context serves HTTP, and the Review tab renders
it. A dev server is the 99% case; Storybook, static servers, or an
emulator behind noVNC are just other URL producers. Iteration 1 is
deliberately *manual* — the user starts the server themselves in a real
Terminal tab — because the proxy and terminal are the hard, durable
infrastructure and typing the command was never the hard part
(`PREVIEW_ROADMAP.md` holds the automation roadmap).

Two constraints shaped everything:

- Erlang ports have no TTY, so `docker exec -t` refuses to run and no
  host PTY can be handed to a subprocess.
- There is no network path from the BEAM to a sibling task container:
  none is created with `--network` or `-p` (ADR-0004), the dev BEAM
  runs on the host (where Docker Desktop's bridge is unreachable), and
  the deployed app container sits on the compose network while task
  containers sit on the default bridge.

## Decision

- **In-app path proxy as the preview gateway.** `/preview/:task_id/*`
  is reverse-proxied by the app itself behind the normal session auth
  (`:preview` router pipeline — deliberately not `:browser`: no
  `accepts`, no CSRF, no secure-header stamping). Container ports are
  never exposed to users; a future managed hosting needs the in-app
  path anyway. The seam is `CodeLead.PreviewGateway`
  (`url_for/1`, `upstream_for/1`) with `PathProxy` as the only
  implementation; `SubdomainProxy` (per-task subdomains, own cookie
  origin, no base-path requirement) is the named future impl.
- **Hand-rolled proxy on the existing stack, one new dep.** Plain HTTP
  streams through Req (`into: :self`, chunked out via `send_chunked`,
  SSE included); websocket upgrades ride `WebSockAdapter` (Bandit)
  client-side and `mint_web_socket` upstream — the one new dependency,
  a small framing layer over the Mint already in the tree.
  `ReverseProxyPlug` was rejected (weak websocket story, HTTPoison
  default). `Plug.Parsers` is wrapped (`PreviewAwareParsers`) so
  `/preview/*` bodies reach the proxy unread.
- **No body rewriting — `PREVIEW_BASE_PATH` is the contract.** The
  proxy rewrites exactly one thing: root-relative `Location` headers.
  Apps that emit absolute asset paths must be configured with the base
  path (terminal execs export `PREVIEW_BASE_PATH`/`PREVIEW_ORIGIN`);
  rewriting HTML/JS bodies is a tar pit and stays rejected.
- **Same-origin cookie hygiene:** the app's session cookie is stripped
  from forwarded Cookie headers; everything else passes (accepted
  same-origin MVP tradeoff, fixed for real by `SubdomainProxy`).
- **Published ports, not networks or tunnels, for container
  upstreams.** A declared `repositories.preview_port` is published at
  container create as `-p <PREVIEW_PUBLISH_IP>:0:<port>` (ephemeral
  host port, resolved via `docker port`; loopback in dev, the docker
  bridge gateway — reachable from the app container, off public
  interfaces — when deployed). A shared docker network was rejected
  (forces a compose migration on every operator and re-couples what
  ADR-0004 decoupled); a `docker exec` socat/nc tunnel was rejected as
  default (per-connection relay hop, requires a tool the image contract
  doesn't promise) but remains the fallback candidate for networks
  where publishing is impossible. Reconciliation: a running container
  missing the declared binding is recreated (cattle), **unless** a live
  runner would lose its exec — then the container is kept and the
  preview 502s until the next run.
- **`preview_port` lives on the repository** — repo-owns-the-runtime,
  beside `image_ref`. Nullable; nil means "review by diff only".
- **The boot reaper keeps Review-state container tasks.** Previously
  any container without a live TaskRunner was removed at boot; a task
  in Review has no runner but hosts reviewer execs, the terminal, and
  the preview. Execs self-heal the container either way
  (`ensure_for_task/1`), but a dev server inside it would not come
  back.
- **PTY inside the target, `script(1)`, plain-pipe fallback.** The
  terminal allocates its PTY *inside* the spawned context — util-linux
  /BSD `script` on the host, `docker exec … script -qec` in the
  container (probed with `command -v script`) — because no TTY exists
  on the Erlang side to satisfy `docker exec -t`. Images/hosts without
  `script` degrade to `sh -i` over a pipe, flagged in the UI. Post-spawn
  resize is out of scope (no TIOCSWINSZ channel through `script`);
  initial size travels as `COLUMNS`/`LINES`.
- **Terminal transport is the LiveView socket, not a channel.** The
  app has zero Phoenix channels; adding a socket, its auth story, and a
  second connection to move keystrokes and log lines is not worth it.
  Frames travel base64-encoded via `pushEvent`/`push_event`; a
  dedicated channel is the escape hatch if throughput ever matters.
  The Port is owned by a per-task `CodeLead.Terminal.Session`
  GenServer (Registry-keyed, `restart: :temporary`, bounded
  scrollback, idle timeout), so the shell survives page refreshes and
  is reattached by task id. xterm.js is vendored into
  `assets/vendor/xterm/` (no npm toolchain), imported from the
  colocated hook via esbuild's `@` alias.

## Consequences

- Anything that serves HTTP under a base path previews today; apps
  that can't honor a base path wait for `SubdomainProxy`.
- Dev-server websockets (Vite HMR, LiveView) work through the proxy;
  the relay answers each leg's pings itself.
- Container previews on a deployed instance need two env vars
  (`PREVIEW_PUBLISH_IP`/`PREVIEW_UPSTREAM_HOST`) — a documented opt-in,
  not a compose migration; local-task previews need nothing.
- The terminal is a real shell with the project env injected — the
  same trust posture as agent execs, and like every container exec it
  sits behind the `:container_execution_env` license gate for
  container tasks.

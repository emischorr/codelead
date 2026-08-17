# 0009 — Devcontainer-based container execution

## Status

Accepted (2026-08-17). Supersedes in part ADR-0004 (image declaration,
idle entrypoint, forced user, resource caps) and ADR-0008
(published-ports upstream resolution).

## Context

The iteration-two container executor (ADR-0004) asked the operator to
hand-build a toolchain image on the deployment host, declare its tag as
`repositories.image_ref`, and still start services and dev servers by
hand in the Terminal tab. Dogfooding showed the combination is not
viable for CodeLead's audience: the idle `sleep` entrypoint means an
image's own `ENTRYPOINT`/`CMD` never runs, and the deployed stack's
forced `--user 1000:1000` lands execs on a uid with no account in most
images — so a database packaged in the image can be neither auto-started
nor reliably hand-started, and the preview's real scope collapsed to a
single-process dev server. Meanwhile ADR-0003 had already reserved the
`.devcontainer` seam (`env_kind: :devcontainer`, `devcontainer_path`)
and PREVIEW_ROADMAP.md parked multi-service support on "devcontainer.json
+ compose is the industry answer".

## Decision

- **The repository's `.devcontainer` configuration is the one container
  execution path.** `env_kind` collapses to `[:devcontainer, :default]`;
  `image_ref` and `dockerfile` are dropped (a forward migration maps old
  `image` rows to `devcontainer` — a prebuilt image now belongs in
  devcontainer.json as `"image":`). There is still no fallback
  environment: an undeclared repo refuses visibly, and a declared one
  without a config file in the worktree fails with routing copy.
- **Provisioning shells out to the official `@devcontainers/cli`**
  (`CodeLead.Executor.DevcontainerCli` → `devcontainer up
  --workspace-folder <worktree> --log-format json`), not a native
  reimplementation. The CLI owns JSONC parsing, variable substitution,
  features, image builds, compose orchestration, lifecycle hooks,
  `overrideCommand` keepalive, and user resolution — the whole moving
  spec, so a repo's existing devcontainer works here because the same
  implementation runs it everywhere else. A native subset would have had
  to say no to `features` forever. The CLI is baked into the app image
  (own build stage, `/opt/devcontainer`, pinned `DEVCONTAINER_CLI_VERSION`);
  dev machines install it with `npm i -g @devcontainers/cli`.
- **The hot path stays plain `docker exec`.** The CLI runs only at
  provision time; agent, reviewers, terminal, and preview exec into the
  resolved primary container over the same Port bridge as before. Execs
  pass `--user` resolved from the container's `devcontainer.metadata`
  label when the config names a remote user, because a bare exec lands
  on the image default. The retired `--entrypoint sleep` and forced
  `CONTAINER_USER` follow from this; `CONTAINER_USER` survives only as
  the harness build container's user. `CONTAINER_CPUS`/`CONTAINER_MEMORY_MB`
  are retired too — `runArgs`/`hostRequirements` in devcontainer.json own
  resources now.
- **Identity stays cattle, via id-labels.** `devcontainer up` gets
  `--id-label codelead.task_container=true --id-label
  codelead.task_id=<id>` (plus managed/project labels); everything is
  re-resolvable from the task id alone (`docker ps --filter label=…
  --no-trunc`), and re-running `up` — idempotent by design — heals a
  stopped or externally removed environment.
- **Teardown is label-based; compose projects go down whole.** There is
  no `devcontainer down`. The primary's `com.docker.compose.project`
  label decides: present → `docker compose -p <proj> down --volumes
  --remove-orphans` (service containers carry no codelead labels and die
  with the project), absent → `docker rm -f`. The boot reaper applies
  the same rule, keeping active-run and Review-state environments.
- **The workspace root rides in as one extra `--mount` at its
  coincident path** (volume or bind, same precedence as before), so the
  worktree's gitdir and the staged harness resolve unchanged. The CLI's
  own `/workspaces/<folder>` mount is ignored — execs keep
  `-w <worktree_path>`.
- **Preview upstreams move to a relay sidecar** (`codelead-preview-<id>`,
  `PREVIEW_RELAY_IMAGE`, default `alpine/socat`): it joins the task
  container's network, forwards to its ip:preview_port, and publishes on
  `PREVIEW_PUBLISH_IP:0`. This replaces `-p`-at-create (impossible — the
  CLI takes no publish flags, and a compose service's ports belong to
  the repo's compose file) and retires ADR-0008's stale-binding
  container recreate: a relay can be recreated at any moment because no
  agent exec runs inside it. `docker port` resolution and
  `PREVIEW_UPSTREAM_HOST` semantics survive unchanged.

## Consequences

- A repo with a working `.devcontainer` runs out of the box — services
  (databases, caches) included via compose, dependency installs and
  seeds via lifecycle hooks. The image contract (`sleep`, hand-started
  services) is gone with the hand-built image.
- The app image grows by node + the devcontainer CLI and needs
  `docker-cli-compose`/`docker-cli-buildx`; provisioning gains a node
  process launch per `up` (~1s warm) and possibly minutes cold (builds,
  features) — streamed to the log, surfaced as the ordinary dispatch
  failure on error.
- Errors from `up` arrive as CLI text: the result JSON's message plus a
  bounded output tail, coarser than ADR-0004's per-step typed errors.
- Operators who used `image_ref` must add a devcontainer.json naming
  the same image; the migration preserves the enablement, the first run
  after upgrade fails with copy that says exactly that.
- The forced-user retirement moves file-ownership correctness to the
  CLI's `updateRemoteUserUID` remapping (Linux) — the reason execs
  honor `remoteUser` instead of staying root.
- `mint_web_socket`-era proxy code is untouched; only upstream
  resolution changed, so `SubdomainProxy` remains a pure gateway swap.

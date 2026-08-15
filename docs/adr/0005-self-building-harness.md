# 0005 — The container harness stages itself

## Status

Accepted (2026-08-15)

## Context

ADR-0004 made the container harness a bun-compiled binary staged onto
the workspace volume at boot, copied from a path baked into the release
image (`HARNESS_SOURCE`). That assumed the release image. A dev
instance — the BEAM on the host, no baked binary, no `HARNESS_VERSION`
env — failed its first container dispatch with an error whose remedy
was hand-compiling the binary with bun and exporting two env vars.
Dogfooding surfaced this immediately: an operator should never have to
build a component the system knows how to build, on a machine that, by
definition of the feature being used, already runs Docker.

## Decision

- `HARNESS_VERSION` has a pinned default in `config/runtime.exs`, kept
  in sync with the image's `ARG CLAUDE_ACP_VERSION` — the version is
  configuration, never a prerequisite.
- When no staged binary and no `HARNESS_SOURCE` file exists, the
  harness is **built lazily in a one-shot bun container** over the same
  docker daemon the executor already uses: `bun install` of the pinned
  adapter version and `bun build --compile` inside `oven/bun:1-alpine`,
  with only the outfile landing on the workspace mount. Compiling
  without a `--target` targets the build container's own platform,
  which is the task containers' platform by construction.
- The build happens **at first need, not at boot** — triggered by the
  first container preflight, before any repository clone, while the
  task visibly sits in `run_state: :dispatched`. Once per version;
  staging is serialized through one process, so concurrent dispatches
  wait on a single build instead of racing it.
- The deployed image's baked binary remains the fast path (boot copies
  it, as before), and `HARNESS_SOURCE` doubles as the manual override
  for air-gapped setups.

Rejected:

- **Building eagerly at boot** — pays minutes and a few hundred
  megabytes of pulls on every fresh instance whether or not container
  execution is ever used, violating "an instance without container use
  boots unaffected".
- **Downloading prebuilt binaries from CodeLead releases** — a
  distribution channel to build, secure, and version, for artifacts
  upstream does not publish; the daemon already at hand can produce the
  same bytes without any of that.

## Consequences

- The first container run on a fresh instance takes a few minutes
  longer and needs docker-side network access to the npm registry; a
  failed build surfaces as the ordinary `run_failed` attention with the
  override remedy, and a retry rebuilds.
- The version pin now lives in two places (`runtime.exs` default and
  the Dockerfile `ARG`), held together by cross-referencing comments.
- The build script's correctness under `--user` (writable `/tmp` build
  tree, in-container `chmod`) is what keeps volume ownership sane on
  prod-shaped hosts; Docker Desktop's ownership mapping hides these
  concerns in dev.
- ADR-0004's "staged at boot" is refined to "copied at boot when baked,
  built on first use otherwise"; nothing in 0004 is contradicted.

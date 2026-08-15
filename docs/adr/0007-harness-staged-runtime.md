# 0007 — The staged harness is a runtime directory, not a compiled binary

## Status

Accepted (2026-08-15)

## Context

With the libc flavors of ADR-0006 in place, the compiled harness
started and completed the ACP handshake — then died at `session/new`
with `Cannot find module '@anthropic-ai/claude-agent-sdk' from
'/$bunfs/root/…'`. That is the first moment the adapter instantiates
the Claude Agent SDK, and the SDK resolves modules and its native CLI
*dynamically at runtime* (`require.resolve`), which cannot work inside
a `bun build --compile` executable's virtual `$bunfs` filesystem —
a known SDK limitation (claude-agent-sdk-typescript#150).

Two further facts settled the direction. Upstream `claude-agent-acp`
never supported compilation at all: its build is plain `tsc` and its
`bin` runs under node — the "standalone binary" premise ADR-0004/0005
built on was wrong. And the SDK's sanctioned workaround for compiled
binaries — embedding per-platform CLI packages as file assets and
extracting them via `extractFromBunfs()` from a custom entrypoint —
means authoring and maintaining a JS sub-project coupled to SDK
internals.

## Decision

- **Stage a runtime directory per flavor instead of compiling.**
  `harness/<version>/<flavor>/` holds the flavor-matched `bun` runtime
  (copied out of the staging image), a real `bun add`-installed
  `node_modules` of the pinned adapter, and a three-line `sh` wrapper
  at the *unchanged* exec path (`claude-agent-acp`) that runs the
  adapter's entry under the staged bun. Everything resolves on real
  disk, so the SDK's dynamic resolution and native-CLI spawn need no
  accommodation.
- **The flavor-matched install container selects everything**: the bun
  binary's libc, and — because the SDK publishes
  `linux-{x64,arm64}-musl` platform packages alongside the glibc ones —
  the SDK's native CLI flavor too.
- **The image bakes no harness for container execution anymore.** Lazy
  in-docker staging (ADR-0005) is the universal path — the deployed
  stack mounts the socket regardless — and `HARNESS_SOURCE` (now
  defaulting to unset) remains only as the air-gapped escape hatch: a
  directory of pre-staged flavor dirs, copied at boot.
- Staged-completeness is "wrapper *and* `bun` present", which doubles
  as the migration check: a bare compiled binary left by the previous
  generation is detected as incomplete and restaged.

## Consequences

- A staged flavor costs roughly the adapter tree plus a bun binary
  (~400 MB) on the workspace volume; a mixed Alpine/Debian fleet pays
  it twice.
- The harness runs under bun rather than the node its upstream targets.
  Accepted: the SDK supports bun, and with everything on real disk a
  compat problem is an ordinary debuggable error, not a vfs mystery.
- Staging is `bun add` + file copies — faster and simpler than
  compilation, and the same first-run latency and failure surface as
  ADR-0005 described.
- ADR-0004's "bun-compiled binary" clause and ADR-0006's "compiled
  binary per flavor" wording are superseded in substance by this
  decision; everything else in 0004–0006 — mounted harness, cattle
  containers, lazy serialized staging, libc probe and flavors — stands
  unchanged.

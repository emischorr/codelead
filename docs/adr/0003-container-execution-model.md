# 0003 — Container execution: the harness runs inside the environment

## Status

Accepted (2026-08-15)

## Context

Agents produce materially better work when they can run the project's
linters, formatters, and tests in a loop, and the planned Developer
terminal needs the same environment — but nothing supplies a per-project
toolchain today: the worktree provides the files, the service image
provides only its own runtime. The planned `DockerContainer` executor
(architecture spec §5.2) is the per-project execution environment. It is
not built yet; this ADR locks the decisions that would be expensive to
retrofit once worktree storage and the executor contract calcify.

Two models were possible for where the ACP harness process lives:
(A) inside the container, driven over `docker exec -i`; (B) on the
service side, routing only command execution into the container via
ACP's client-side `terminal` capability. Harness reality settles it:
`claude-agent-acp` proxies *permission* (the SDK's `canUseTool` becomes
an ACP `session/request_permission`) but the SDK executes commands in
its own process; `codex-acp` runs shell inside Codex's own sandbox; the
only adapter that ever delegated execution to the client terminal is the
deprecated `zed-industries/claude-code-acp`. The ACP client is a
permission gate and display surface, never an executor — a harness kept
outside the container would sandbox nothing.

A second constraint comes from topology. CodeLead itself runs as a
container and would create *sibling* containers through the host docker
socket. Bind-mount paths passed through that socket resolve in the
host's mount namespace, not CodeLead's — a path like
`/data/workspace/worktrees/task-42` means nothing to the host daemon.

## Decision

- **Model A.** `Executor.spawn/3` launches the agent process *inside*
  the provisioned execution context. The container implementation
  attaches over `docker exec -i`, reusing the Port stdio bridge of
  ADR-0001. Client-side ACP capabilities stay host-side as permission
  and display, which remains correct because host and container see the
  workspace at identical paths (below).
- **The named-volume rule.** Base clones, worktrees, and task folders
  live on a named Docker volume, and sibling containers reference it by
  name (or `--volumes-from`) — never by a bind path from CodeLead's own
  namespace. An explicit `HOST_DATA_ROOT` translation is the escape
  hatch for operators who insist on a bind mount, not the default.
- **Harnesses are mounted binaries.** The agent CLIs are never baked
  into project images; the executor mounts them into the container.
  Project images stay toolchain-only, and the harness version stays
  pinned to CodeLead rather than to images it does not control.
- **Toolchain ownership is layered.** The repository owns the base
  runtime — an objective property of the repo (`.tool-versions`,
  `mix.exs`), declared per repository (`env_kind` with
  `devcontainer_path`/`image_ref`/`dockerfile`, resolution order
  `.devcontainer` → `image_ref` → `dockerfile` → default image). Agents
  own only additive tools (`agents.tool_features`), never a competing
  base runtime. Executing agents inherit the project environment;
  reviewers may layer their own tools onto it.
- **Backend selection is per task** (`tasks.execution_env`,
  `:local | :container`, default `:local`) — the spec's "user-selectable
  executor", renamed because "executor" already means the executing
  agent throughout the code and UI.
- **Threat model.** Mounting the docker socket is root-equivalent on
  the host. Accepted, and stated rather than discovered, under the
  single-tenant, self-hosted assumption.

## Consequences

- The schema seams (`repositories.env_kind` quartet,
  `tasks.execution_env`, `agents.tool_features`) and
  `Context.exec_ref` are dormant: nothing reads them until the
  container executor ships, and their validation ships with it.
- `StageEffects.discard_context/1` rebuilds a `Context` from DB rows,
  so a container implementation must recover its identity from the
  task id alone (e.g. container labels), never from `exec_ref`.
- The driver's host-side `fs/*` and `terminal/*` handling stays valid
  only while the named-volume rule holds; breaking it silently breaks
  path coincidence, which nothing checks at runtime.
- The word "executor" keeps two meanings at arm's length: the
  `CodeLead.Executor` behaviour and the executing agent. The task
  column avoids the collision (`execution_env`), the behaviour name
  keeps it.
- No per-tool-call permission nagging inside the sandbox: auto-grant
  within the isolated worktree/container stays the policy; escalations
  that leave it surface as attention items.

# Documentation Index

Map of the repo's documentation. Design notes describe how things work
*today*; ADRs record decisions and are immutable (see `adr/README.md`).

## Specs (source of truth for the MVP target state)

- [`../codelead-product-spec.md`](../codelead-product-spec.md) — what CodeLead is and how it behaves.
- [`../codelead-architecture-spec.md`](../codelead-architecture-spec.md) — data model, state machine, behaviours.

## Getting started

- [`console-api.md`](console-api.md) — the IEx walkthrough of the full workflow.

## Operations

- [`deployment.md`](deployment.md) — running it on a server: the plain-HTTP posture and why TLS is the operator's, the published image, the `deployment/` compose stack (including the docker socket mount for container execution and the pinned data-volume name with its upgrade note), `PHX_HOST`/`SCHEME`/`URL_PORT` recipes for direct and proxied access, reverse proxy requirements, upgrades, backups, and the gaps to know about before exposing it.

## Design notes

- [`architecture.md`](architecture.md) — module map: contexts, behaviours, runtime processes.
- [`configuration.md`](configuration.md) — environment variables, application config keys, workspace layout, git credentials (and how to read a forge's refusal), per-project approve defaults and PR template, harness prerequisites, the Docker image and what an agent can actually run inside it (shell and CLI tools yes, language toolchains no — declare a per-repo container image, or extend the image for local runs), container execution in dev, the preview/terminal config keys and the `PREVIEW_BASE_PATH` contract.
- [`task-workflow.md`](task-workflow.md) — the state machine as implemented in `CodeLead.Tasks`: the `CodeLead.Workflow` definition it runs on (stage types, edge policies), transition table, stage effects, finalize modes and their cleanup rule, the scheduler's admission gates and scheduled runs, deviations, IEx usage.
- [`git-workspace.md`](git-workspace.md) — workspace layout, base clones, worktrees/branches (including when an existing directory may be reused), diff/commit/push, merging a finished branch into the default branch on Done, forge tokens, executor provisioning, `mix code_lead.workspace.clean`.
- [`agent-drivers.md`](agent-drivers.md) — the AgentDriver behaviour, normalized event contract, LlmApi/Acp implementations, preflight, permission escalations and agent questions (ACP elicitation).
- [`cost-tracking.md`](cost-tracking.md) — agent_runs (token split, duration), where ACP reports tokens vs money, nightly rollups, pricing precedence, billing modes, spend queries (lifetime vs month-to-date, and why the two tables merge per day), calendar-month budget gate.
- [`reviews.md`](reviews.md) — reviewer fan-out, advisory verdicts, read-only ACP posture, rework loop.
- [`planning.md`](planning.md) — the planning surface: the `:plan` role, `llm_api` spec refinement vs the `acp` repo-aware survey, the survey's disposable detached worktree, message kinds, and the escalation gap.
- [`web-ui.md`](web-ui.md) — the LiveView layer: the dashboard at `/`, board + task page (Task / Agent / Review / Terminal tabs, including the live-preview iframe + diff toggle and the xterm.js terminal), the `/settings` area, the mode-derived Approve button and artifact download, design tokens, the app-shell height contract, component inventory, PubSub wiring, the live/collapsible diff and its JS hook.
- [`navigation.md`](navigation.md) — the sidebar contract: the `@nav` map and its `on_mount` hook, what is enabled/deactivated/hidden where, the one collapsible sidebar and its expanded/collapsed/drawer renderings, the best-effort Anthropic subscription rate-limit tile, how the selected project and the sidebar width are remembered client-side, and the project switcher's per-project color/running-pulse/attention badge backed by an org-wide `project_stats` subscription.
- [`setup-and-auth.md`](setup-and-auth.md) — the `setup_done` flag, the setup/auth router gates, the first-run wizard, and how the generated auth stack was merged.
- [`licensing.md`](licensing.md) — the ELv2 posture and the `CodeLead.License` entitlement seam: the one gated feature (`:container_execution_env`) and how it is enforced, the offline signed key and its `LICENSE_KEY` env var, tier baselines merged with per-key grants including the `:owner` tier, fail-open-to-community, why unknown feature names are dropped, how to add a gated feature, minting, and running a licensed instance locally.

## ADRs

- [`adr/README.md`](adr/README.md) — ADR conventions.
- [`adr/0001-acp-transport.md`](adr/0001-acp-transport.md) — hand-rolled JSON-RPC subset over Erlang Ports instead of ACPex 0.1.x.
- [`adr/0002-persist-agent-transcript.md`](adr/0002-persist-agent-transcript.md) — `agent_events` as its own table, separate from the `task_steps` audit trail.
- [`adr/0003-container-execution-model.md`](adr/0003-container-execution-model.md) — the container executor's locked seams: the harness runs inside the execution environment, the named-volume rule, toolchain ownership (repo owns the base runtime, agents add tools), and the dormant schema fields.
- [`adr/0004-container-executor-iteration-two.md`](adr/0004-container-executor-iteration-two.md) — the built container executor: no default/fallback image, containers as cattle (volume-durable worktree + agent home), the bun-compiled musl-static harness staged at boot, env at exec time, visible refusal over invisible holds, the container-user strategy.
- [`adr/0005-self-building-harness.md`](adr/0005-self-building-harness.md) — the harness stages itself: pinned version default, lazy serialized in-docker build on the first container run when no baked binary exists; rejected boot-eager builds and downloading prebuilt binaries.
- [`adr/0006-harness-libc-flavors.md`](adr/0006-harness-libc-flavors.md) — one harness binary per libc flavor, matched by probing the task image at spawn: bun-compiled binaries are dynamically linked and a same-platform `--target` embeds the building bun itself, so the build image selects the flavor; corrects 0004's musl-static assumption.
- [`adr/0007-harness-staged-runtime.md`](adr/0007-harness-staged-runtime.md) — the staged harness is a runtime directory (flavor-matched bun + real package tree + sh wrapper), not a compiled binary: the SDK's dynamic module/CLI resolution cannot work inside bun's compile-time virtual filesystem; the image bakes no container harness anymore.
- [`adr/0008-preview-and-terminal.md`](adr/0008-preview-and-terminal.md) — the Review tab's live preview and the Developer terminal: the URL contract behind the `CodeLead.PreviewGateway` seam, the in-app `/preview/:task_id/*` path proxy (Req-streamed HTTP + Mint.WebSocket relay) behind session auth, published-port upstream resolution for container tasks, `PREVIEW_BASE_PATH` instead of body rewriting, `script(1)`-in-target PTY with plain-pipe fallback, terminal over the LiveView socket with a Session-owned Port. The iteration roadmap (one-click preview, SubdomainProxy) lives in [`../PREVIEW_ROADMAP.md`](../PREVIEW_ROADMAP.md).

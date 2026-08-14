# Documentation Index

Map of the repo's documentation. Design notes describe how things work
*today*; ADRs record decisions and are immutable (see `adr/README.md`).

## Specs (source of truth for the MVP target state)

- [`../codelead-product-spec.md`](../codelead-product-spec.md) — what CodeLead is and how it behaves.
- [`../codelead-architecture-spec.md`](../codelead-architecture-spec.md) — data model, state machine, behaviours.

## Getting started

- [`console-api.md`](console-api.md) — the IEx walkthrough of the full workflow.

## Operations

- [`deployment.md`](deployment.md) — running it on a server: the plain-HTTP posture and why TLS is the operator's, the published image, the `deployment/` compose stack and what it omits, `PHX_HOST`/`SCHEME`/`URL_PORT` recipes for direct and proxied access, reverse proxy requirements, upgrades, backups, and the gaps to know about before exposing it.

## Design notes

- [`architecture.md`](architecture.md) — module map: contexts, behaviours, runtime processes.
- [`configuration.md`](configuration.md) — environment variables, application config keys, workspace layout, git credentials (and how to read a forge's refusal), per-project approve defaults and PR template, harness prerequisites, the Docker image.
- [`task-workflow.md`](task-workflow.md) — the state machine as implemented in `CodeLead.Tasks`: the `CodeLead.Workflow` definition it runs on (stage types, edge policies), transition table, stage effects, finalize modes and their cleanup rule, the scheduler's admission gates and scheduled runs, deviations, IEx usage.
- [`git-workspace.md`](git-workspace.md) — workspace layout, base clones, worktrees/branches (including when an existing directory may be reused), diff/commit/push, merging a finished branch into the default branch on Done, forge tokens, executor provisioning, `mix code_lead.workspace.clean`.
- [`agent-drivers.md`](agent-drivers.md) — the AgentDriver behaviour, normalized event contract, LlmApi/Acp implementations, preflight, permission escalations and agent questions (ACP elicitation).
- [`cost-tracking.md`](cost-tracking.md) — agent_runs (token split, duration), where ACP reports tokens vs money, nightly rollups, pricing precedence, billing modes, spend queries (lifetime vs month-to-date, and why the two tables merge per day), calendar-month budget gate.
- [`reviews.md`](reviews.md) — reviewer fan-out, advisory verdicts, read-only ACP posture, rework loop.
- [`planning.md`](planning.md) — the planning surface: the `:plan` role, `llm_api` spec refinement vs the `acp` repo-aware survey, the survey's disposable detached worktree, message kinds, and the escalation gap.
- [`web-ui.md`](web-ui.md) — the LiveView layer: the dashboard at `/`, board + task page, the `/settings` area, the mode-derived Approve button and artifact download, design tokens, the app-shell height contract, component inventory, PubSub wiring, the live/collapsible diff and its JS hook.
- [`navigation.md`](navigation.md) — the sidebar contract: the `@nav` map and its `on_mount` hook, what is enabled/deactivated/hidden where, the one collapsible sidebar and its expanded/collapsed/drawer renderings, and how the selected project and the sidebar width are remembered client-side.
- [`setup-and-auth.md`](setup-and-auth.md) — the `setup_done` flag, the setup/auth router gates, the first-run wizard, and how the generated auth stack was merged.
- [`licensing.md`](licensing.md) — the ELv2 posture and the `CodeLead.License` entitlement seam: why it gates nothing today, the offline signed key and its `LICENSE_KEY` env var, tier baselines merged with per-key grants, fail-open-to-community, why unknown feature names are dropped, how to add a gated feature, and minting.

## ADRs

- [`adr/README.md`](adr/README.md) — ADR conventions.
- [`adr/0001-acp-transport.md`](adr/0001-acp-transport.md) — hand-rolled JSON-RPC subset over Erlang Ports instead of ACPex 0.1.x.
- [`adr/0002-persist-agent-transcript.md`](adr/0002-persist-agent-transcript.md) — `agent_events` as its own table, separate from the `task_steps` audit trail.

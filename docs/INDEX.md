# Documentation Index

Map of the repo's documentation. Design notes describe how things work
*today*; ADRs record decisions and are immutable (see `adr/README.md`).

## Specs (source of truth for the MVP target state)

- [`../codelead-product-spec.md`](../codelead-product-spec.md) — what CodeLead is and how it behaves.
- [`../codelead-architecture-spec.md`](../codelead-architecture-spec.md) — data model, state machine, behaviours.

## Getting started

- [`console-api.md`](console-api.md) — the IEx walkthrough of the full workflow.

## Design notes

- [`architecture.md`](architecture.md) — module map: contexts, behaviours, runtime processes.
- [`configuration.md`](configuration.md) — environment variables, application config keys, workspace layout, git credentials (and how to read a forge's refusal), harness prerequisites, the Docker image.
- [`task-workflow.md`](task-workflow.md) — the state machine as implemented in `CodeLead.Tasks`: transition table, deviations, IEx usage.
- [`git-workspace.md`](git-workspace.md) — workspace layout, base clones, worktrees/branches, diff/commit/push, forge tokens, executor provisioning.
- [`agent-drivers.md`](agent-drivers.md) — the AgentDriver behaviour, normalized event contract, LlmApi/Acp implementations, preflight.
- [`cost-tracking.md`](cost-tracking.md) — agent_runs (token split, duration), where ACP reports tokens vs money, nightly rollups, pricing precedence, billing modes, spend queries, budget gate.
- [`reviews.md`](reviews.md) — reviewer fan-out, advisory verdicts, read-only ACP posture, rework loop.
- [`web-ui.md`](web-ui.md) — the LiveView layer: the dashboard at `/`, board + task page, the `/settings` area, design tokens, component inventory, PubSub wiring, the live/collapsible diff and its JS hook.
- [`navigation.md`](navigation.md) — the sidebar contract: the `@nav` map and its `on_mount` hook, what is enabled/deactivated/hidden where, the full/rail/drawer renderings, and how the selected project is remembered off-project.
- [`setup-and-auth.md`](setup-and-auth.md) — the `setup_done` flag, the setup/auth router gates, the first-run wizard, and how the generated auth stack was merged.

## ADRs

- [`adr/README.md`](adr/README.md) — ADR conventions.
- [`adr/0001-acp-transport.md`](adr/0001-acp-transport.md) — hand-rolled JSON-RPC subset over Erlang Ports instead of ACPex 0.1.x.
- [`adr/0002-persist-agent-transcript.md`](adr/0002-persist-agent-transcript.md) — `agent_events` as its own table, separate from the `task_steps` audit trail.

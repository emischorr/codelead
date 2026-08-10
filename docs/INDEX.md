# Documentation Index

Map of the repo's documentation. Design notes describe how things work
*today*; ADRs record decisions and are immutable (see `adr/README.md`).

## Specs (source of truth for the MVP target state)

- [`../codelead-product-spec.md`](../codelead-product-spec.md) — what CodeLead is and how it behaves.
- [`../codelead-architecture-spec.md`](../codelead-architecture-spec.md) — data model, state machine, behaviours.

## Design notes

- [`configuration.md`](configuration.md) — environment variables, application config keys, workspace layout.
- [`task-workflow.md`](task-workflow.md) — the state machine as implemented in `CodeLead.Tasks`: transition table, deviations, IEx usage.
- [`git-workspace.md`](git-workspace.md) — workspace layout, base clones, worktrees/branches, diff/commit/push, executor provisioning.
- [`agent-drivers.md`](agent-drivers.md) — the AgentDriver behaviour, normalized event contract, LlmApi/Acp implementations.
- [`cost-tracking.md`](cost-tracking.md) — agent_runs, nightly rollups, pricing map, spend queries, budget gate.

## ADRs

- [`adr/README.md`](adr/README.md) — ADR conventions.
- [`adr/0001-acp-transport.md`](adr/0001-acp-transport.md) — hand-rolled JSON-RPC subset over Erlang Ports instead of ACPex 0.1.x.

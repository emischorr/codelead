# 0001 — ACP transport: hand-rolled JSON-RPC subset over Erlang Ports

## Status

Accepted (2026-08-10)

## Context

CodeLead drives coding harnesses (Claude Code, Codex) over the Agent
Client Protocol: JSON-RPC 2.0, newline-delimited, over stdio. The
architecture spec left the transport open: adopt the ACPex library or
hand-roll a thin subset.

Evaluation of ACPex (hex v0.1.1, github.com/lostbean/acpex):

- Provides an `ACPex.Client` behaviour, typed protocol schemas for "all
  27 protocol types", and ndjson over native Erlang Ports — the same
  transport shape we need.
- Maturity is the problem: v0.1.x, ~30 commits, 10 stars, no visible
  production use. `session/load` support, permission-callback
  ergonomics, and usage extraction are undocumented; we would be
  depending on (and likely patching) a moving 0.x API in the most
  critical integration of the product.
- Our needed subset is small: 6 outgoing methods (initialize,
  session/new|load|prompt|cancel), 8 incoming (fs/read|write,
  session/request_permission, terminal/*), ndjson framing, id
  correlation. Implemented + tested it is ~500 LOC.

## Decision

Hand-roll the subset: `CodeLead.Acp.JsonRpc` (framing/classification),
`CodeLead.Acp.Connection` (Port bridge, id correlation), and
`CodeLead.AgentDriver.Acp` (protocol/state machine, permission policy,
terminal support). The boundary that must stay stable is
`CodeLead.AgentDriver`'s normalized event contract — ACPex (or any
future transport) can replace the internals behind `AgentDriver.Acp`
without touching callers.

Tests run against a scripted fake agent
(`test/support/fake_acp_agent.exs`), not a real harness.

## Consequences

- We own protocol-drift maintenance against the ACP spec; the surface
  is deliberately minimal.
- `session/load` capability is honored when the harness advertises it;
  otherwise (or on load failure) the driver falls back to a fresh
  session — *request changes* then relies on the feedback prompt plus
  the persistent branch/worktree for continuity. Whether real
  harnesses support load-resume and how they report token usage in the
  prompt result must be verified against the actual Claude Code ACP
  adapter; usage extraction currently reads `result.usage` /
  `result._meta.usage` permissively.
- Revisit ACPex once it stabilizes (1.x, session/load + usage
  documented); the swap is contained by design.


# Architecture Decision Records

One file per decision, recording *why* — the reasoning that the code cannot carry.
Keep them concise and on the point. Don't add ADRs for pure feature or product decisions if they don't touch the architecture.

## Format

`NNNN-kebab-case-title.md`, numbered sequentially from `0001`. Sections:

- **Status** — `Accepted`, or `Superseded by ADR-NNNN`.
- **Context** — the situation that forced the decision.
- **Decision** — what was decided, in the present tense.
- **Consequences** — what follows, including what got worse.

## They are immutable

Never edit an accepted ADR. To change a decision, write a new one and mark the old one
`Superseded by ADR-NNNN`. A reader must be able to trust that an ADR says what was decided
*then*, not what someone tidied it into later.

That immutability is the whole difference between an ADR and a design note in `docs/`:

| | ADR (`docs/adr/`) | Design note (`docs/*.md`) |
|---|---|---|
| Records | a decision and its rationale | how something works today |
| Changes | never — supersede instead | freely, in place |
| Stamp | none; it is dated by its number | `(last updated: YYYY-MM-DD)` |

So a rule list, a status, or a known-gaps table belongs in a design note. Put one in an ADR
and it is wrong the moment the code moves, with no honest way to fix it.

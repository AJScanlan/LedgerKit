# Architecture Decision Records

Each ADR records **one decision, its reasoning, and what it costs** — the "why" behind a
choice that is expensive to reverse.

## Relationship to the spec

`SPEC.md` is the contract; ADRs are the reasoning behind it. Where a rule is normative,
the spec holds the text and the ADR links to it — deliberately, so there is exactly one
copy to keep correct. An ADR that finds itself reproducing a spec table is drifting.

On any conflict, **the spec wins** (per `CLAUDE.md`) and the ADR is stale — fix the ADR.

## Status values

| Status | Meaning |
|---|---|
| **Draft** | Recorded, still moving. Safe to change without ceremony. |
| **Accepted** | Decided and implemented. Reversal needs a superseding ADR. |
| **Superseded** | Replaced. Kept forever — the reasoning stays useful. |

## Index

| # | Title | Status | Ratifies at |
|---|---|---|---|
| [001](ADR-001-event-encoding.md) | Tagged-JSON event encoding & discriminator registry | Draft | M9 |
| [002](ADR-002-identifiers.md) | Identifier design | Accepted | M1 |

# ADR-003 — Persistence dependency: GRDB behind an internal seam

**Status:** Draft · opened 2026-07-19 at M1 · ratifies at M4 (when wired)
**Spec:** §9 (persistence), §6.5/§11 (store actor & API shape), §10.6 (P1/P3), §12 (cut line)
**Code:** `Store/Persistence.swift` (the seam; no GRDB wiring until M4)

## Context

§9 needs little from a database: three tables (`events`, `snapshots`, `conversations`),
single-writer append transactions, suffix reads keyed on `(conversation_id, sequence)`,
transactional multi-table delete, and change observation for the conversation list (G9).
The spec recommends GRDB but defers the decision to implementation, behind "a small
protocol so this is swappable." This ADR records that decision and the seam's design
rules; M4 ratifies it by wiring.

## Options

| Option | Verdict |
|---|---|
| **SwiftData / Core Data** | **Rejected** (spec-mandated, §9): change-tracked mutable object graphs are the wrong shape for an append-only log with custom reduction — their machinery (faulting, merge policies, migration) solves problems this design defines away. |
| **Raw sqlite3** | Viable floor; remains the §12 cut-line fallback. Costs: hand-rolled statement binding, WAL setup, observation, and migration bookkeeping — all code that must be written and tested to reach parity. |
| **GRDB** | **Chosen.** SQLite toolkit, not an ORM — "SQL is not a dirty word." Mature, actively maintained, Swift 6 strict-concurrency clean. |
| SQLiteData / StructuredQueries (Point-Free) | Credible newer alternative (typed SQL, CloudKit sync). Not chosen: the spec names GRDB, sync is explicitly v0.3 territory, and the seam keeps a later swap cheap if v0.3 changes the calculus. |

## Why GRDB fits this design specifically

- **Concurrency model matches the store's.** GRDB serializes writes and (via
  `DatabasePool` + WAL) runs concurrent reads — the same single-writer discipline the
  `ConversationStore` actor imposes (§6.5). `DatabaseQueue` vs `DatabasePool` is an M4
  call; both sit behind `DatabaseWriter`, so it isn't an API decision.
- **In-memory `DatabaseQueue`** gives tests and previews a real SQL engine with zero
  I/O — the persistence counterpart of `ScriptedLanguageModel` (tenet 5), and what
  `PersistenceConfiguration.inMemory` maps to.
- **`ValueObservation`** feeds the `conversations` index to the projection's
  `conversationList` (G9, M7) without polling — and §9's "index updates on non-delta
  appends only" rule exists precisely so this observation doesn't churn at streaming
  cadence.
- **`DatabaseMigrator`** covers the little schema evolution we have (the *data* never
  migrates: events are versioned-and-frozen per ADR-001, snapshots are
  discard-on-mismatch).
- **Async/await with cancellation-safe transactions** aligns with the actor-based store
  and the §7.2 outcome boundary's transactional appends.

## Seam design rules (the part that outlives the dependency)

1. **GRDB types never leak.** The `PersistenceStore` protocol and everything it
   mentions are LedgerKit-owned values. Enforced structurally: the protocol is
   `internal`; consumers see only `PersistenceConfiguration` (§11's
   `.sqlite(url:)` shape).
2. **Bytes below, meaning above.** The backend stores encoded blobs + key/index
   columns; encoding, decoding, quarantine, and snapshot-version policy live above the
   seam. This is ADR-001's lossy-decode rule applied to storage: the backend can never
   corrupt what it never interprets.
3. **Atomicity is promised by verbs, not exposed as handles.** Callers get "these
   events append in one transaction," never a transaction object — keeping the protocol
   honest about what any future backend must guarantee, and keeping GRDB's
   `Database` handle out of signatures.
4. **Small on purpose.** Five verbs. Observation joins at M4/M7 as an `AsyncSequence`
   when the projection needs it; anything else must argue its way in.

## Costs accepted

- An external dependency (supply-chain and version-churn exposure) on the hot path of
  every app using LedgerKit. Mitigated by the seam: parity fallback is raw sqlite3.
- The seam itself is a thin layer of indirection that must not grow features — its
  budget is "small protocol," and D-rule 4 is the guard.

## Open until M4

- `DatabaseQueue` vs `DatabasePool` (likely pool for concurrent projection reads).
- Canonical encoder configuration shared with the frozen corpus (ADR-001 D-1).
- Schema-version column placement (ADR-001 D-2) — decided with the table DDL.
- The append verb's exact signature is being designed now at M1 (the one seam decision
  with API-shape consequences); this ADR inherits it once settled.

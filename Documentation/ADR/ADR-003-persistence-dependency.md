# ADR-003 — Persistence dependency: GRDB behind an internal seam

**Status:** **Accepted** · opened 2026-07-19 at M1 · updated 2026-07-25 (M2 audit: the read
verb returns `LoadedEvent`) · **ratified 2026-07-26 at M4 Phase 1, by wiring it**
(`Store/SQLitePersistenceStore.swift`, GRDB 7.11.1, 23 tests in 5 suites)
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
2. **Bytes below, meaning above.** GRDB stores and returns encoded blobs + key/index
   columns and never interprets them — it cannot corrupt what it does not read.
   Decoding happens in LedgerKit's own loader inside the conformance, and it is
   *two-stage* (envelope first, payload second, so a row-2 diagnostic keeps its
   `EventID` — ADR-001, §6.6 "Diagnostic identity"). Quarantine semantics and
   snapshot-version policy live above the seam entirely. This is ADR-001's
   lossy-decode rule applied to storage.

   **Corrected at the M2 audit:** the read verb returns `[LoadedEvent]`, not
   `[LedgerEvent]`. §6.6's input corollary requires that a row whose blob will not
   decode be *emitted* — dropping it turns a row-1/2 condition into a false **gap**
   diagnostic, and throwing makes the whole conversation unloadable over one bad row,
   which I2 forbids. `[LedgerEvent]` could represent neither outcome, so the seam as
   originally typed made M4's two-stage loader unimplementable above it and forced
   decode *below* the boundary this rule draws. The asymmetry with `append` — which
   takes typed records — is principled: encoding is total, decoding is not.
3. **Atomicity is promised by verbs, not exposed as handles.** Callers get "these
   events append in one transaction," never a transaction object — keeping the protocol
   honest about what any future backend must guarantee, and keeping GRDB's
   `Database` handle out of signatures.
4. **Small on purpose.** Six verbs. Observation joins at M4/M7 as an `AsyncSequence`
   when the projection needs it; anything else must argue its way in.

## Costs accepted

- An external dependency (supply-chain and version-churn exposure) on the hot path of
  every app using LedgerKit. Mitigated by the seam: parity fallback is raw sqlite3.
- The seam itself is a thin layer of indirection that must not grow features — its
  budget is "small protocol," and D-rule 4 is the guard.

## Settled at M4 Phase 1 (2026-07-26) — the wiring

- **`DatabasePool` for `.sqlite`, `DatabaseQueue` for `.inMemory`**, both behind
  `any DatabaseWriter` — which is why this was never an API decision. The pool brings WAL
  and concurrent reads that M7's projection wants while a write is in flight; in-memory
  databases have no pool form and need none, since a test has nothing to read
  concurrently.
- **Canonical encoder** is `WireJSON` (ADR-001 D-1, closed): `[.sortedKeys,
  .withoutEscapingSlashes]`, compact. The store and the corpus share the *configuration*,
  not the whitespace — corpus files pretty-print, because readability is their job and
  whitespace is invisible to the value comparisons those tests make. Byte-level pinning
  happens against `WireJSON` output.
- **Schema version is column-only** (ADR-001 D-2, closed; M4-PLAN D16). A version is
  loader routing metadata, exactly like `sequence`; duplicating it into the blob would add
  a permanent envelope key to every event ever written, to buy self-description that no
  transport needs — log transport moves *rows*, not bare blobs.
- **`events.payload` is TEXT, not BLOB.** JSON is text, and a log that
  `sqlite3 ledger.db "SELECT payload FROM events"` prints readably is worth real money in
  a project whose fixtures are documentation; it also puts SQLite's `json1` functions
  within reach for triage. Rule 2 asks that the database never *interpret* the value,
  which TEXT honours exactly as well as BLOB. Snapshots stay BLOB — the seam types that
  payload as `Data`, it is a disposable cache rather than audited truth, and nobody reads
  a snapshot by eye.
- **`STRICT` tables throughout.** SQLite's default affinity would happily store a string
  in an integer column; tenet 1 does not stop being true at the storage layer.
- **Identifiers reach SQL as bare UUID strings** via an internal `sqlText`, deliberately
  identical to ADR-002's wire form so the `conversation_id` column and the same field
  inside the blob are the same bytes — which is what makes §6.6 row 4's duplication an
  honest read-side check rather than one the writer forged agreement into. Spelled out
  rather than conforming the identifiers to GRDB's `DatabaseValueConvertible`, which would
  be visible to anyone importing both modules and is exactly the leak rule 1 forbids.
- **`from: "7.9.0"`, not `.exact(_:)`.** An exact pin in a *library* manifest forces a
  resolution conflict on any consumer who also depends on GRDB — a cost paid by other
  people to buy us nothing, since `Package.resolved` already pins the exact version for
  our own CI. (Resolved: 7.11.1.)

**Rule 4 held.** The protocol is still six verbs. Value observation did not join at M4.

## Settled at M7 (2026-08-16): value observation was considered and **declined**

Rule 4 anticipated `ValueObservation` joining "at M4/M7 as an `AsyncSequence` when the
projection needs it". M7 built the projection, so the question came due — and the answer is
no. Recorded here because a rule that *anticipated* an exception should say when the
exception was examined and turned down, or the next reader will assume it is still pending.

**The reasoning.** The `ConversationStore` actor is the **only writer in the process**. So
database-level observation would watch for changes that can only ever originate one actor
hop away — a second, heavier mechanism to learn what the store already knew at the instant
it did the writing. The projection is fed by store-side notification instead: the store
publishes when it commits, and the read side re-reads.

**What declining buys.** The seam stays at **six verbs**, so rule 4's "anything else must
argue its way in" is intact and nothing argued its way in. The in-memory test double stays
trivial — it needs no observation machinery to be a faithful stand-in. And a GRDB feature
stays out of the dependency surface, which keeps the §12 cut line to raw sqlite3 priced in
days rather than in weeks.

**What it costs, honestly.** Nothing today, and something the moment there is a **second
writer** — a widget, an app extension, or sync. A store-side feed cannot see writes made by
another process, so that is the change that reopens this: at that point `ValueObservation`
(or a cross-process equivalent) earns its way in with the argument rule 4 always asked for.
Noting the trigger explicitly, because "we declined it" and "we declined it *given one
writer*" are different decisions and only the second is true.

## Owned limitation: file protection

§9's `.completeUntilFirstUserAuthentication` minimum is applied to the database and its
sidecars on the iOS family (`FileProtectionType` is an iOS-family concept; macOS's
equivalent is FileVault, which is not ours to set). Two honest gaps: `-wal` and `-shm` do
not exist until the first write, so they are protected on the *next* open rather than the
first; and the robust answer is protection on the containing *directory*, which belongs to
the app because the app chose the directory. This is a floor, not a guarantee — §9's
guidance that sensitive domains layer their own encryption stands.

**Deferred to M9's hardening pass, deliberately and on the record** (rolled forward at M6
Phase 0; the note previously said "revisit at M5"). M5 came and went: `ConversationStore`
now owns database creation end to end and nothing about that changed the two gaps, because
both are properties of *where the app put the file* rather than of who opens it. Neither is
a correctness issue, and the honest fix — directory-level protection, or an explicit
`PersistenceConfiguration` knob for it — is a public-API decision that belongs with the
other 0.1.0 packaging choices rather than mid-milestone.

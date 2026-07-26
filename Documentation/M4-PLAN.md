# M4 Implementation Plan — SQLite store, snapshots, index

**Status:** In progress · opened 2026-07-26 at the M3 boundary · **Phases 0–4
done** (266 tests green); **Phase 5 next** — the wrap-up: SPEC rev 7 drafted from
§6 and ratified, ADRs recorded closed, ROADMAP + CLAUDE.md updated.
**Companion to:** [ROADMAP.md](./ROADMAP.md) (M4 section) · [SPEC.md](./SPEC.md) §9, §6.6, §6.3, §10.6 · [ADR-003](./ADR/ADR-003-persistence-dependency.md) (ratifies here) · [ADR-001](./ADR/ADR-001-event-encoding.md) (D-1/D-2/D-3 close here)
**Baseline:** M0–M3 done and audited, SPEC **rev 6 ratified**, **196 tests green**
(175 `LedgerKit` + 21 in the test-double package — `LedgerKitTestSupport` at
baseline, **`Understudy`** since Phase 0), both packages warning-free.
**Spec work:** **rev 7 drafts early in this milestone and ratifies at the M4
boundary.** Its full inventory is §6 of this plan. The one wire-affecting item
(D17) was approved and **implemented at Phase 4**; §6 item 11 is now a *record* of
what shipped rather than a proposal, and every other §6 item is still undrafted.

> **How to use this document.** This plan persists across sessions, agents, and
> compactions — it is the working memory for M4. Update the checkboxes and the
> per-phase status lines as work lands; record anything that changes a decision
> in the Decision log (D-numbers continue M3's sequence at **D13**, so a bare
> "D8" always means the same thing in every plan); do not silently deviate. Each
> phase ends with a **review gate**: stop, run both packages' suites, and review
> with Alexander before starting the next phase. SPEC edits require approval
> first — rev 7's checklist is §6, but drafting it is a session of its own.

---

## 1. What M4 is, in one paragraph

M4 wires ADR-003's seam to GRDB — three tables, the six verbs, the two-stage
envelope-first loader emitting `LoadedEvent`, versioned `FoldedState` snapshots,
and the conversations index — and moves P1/P3 from in-memory properties to
properties of the real store. It **starts** with something the roadmap didn't
originally list: a contract-hygiene pass (Phase 0) applying the M3 audit's API
findings, because those are breaking changes that cost nothing today and become
migration guides the moment M4/M5 give the surface callers. The audit's
justification, once more: M4 and M5 are where these types get consumers; after
that, every tightening is a break.

**Roadmap exit criteria (the contract for "done"):**
- Cold-open of a 10k-event conversation replays **≤ one generation's suffix**
  (asserted as *rows replayed*, which is deterministic — never wall time).
- **P1 and P3 green against the real store**, exhaustive over the corpus.
- The conversation list is **one table read**, maintained on non-delta appends.
- The loader emits `LoadedEvent` per §6.6's input corollary; the corpus `raw`
  row form is implemented and row-1/row-2 fixtures exist **on disk**.
- Phase 0 landed: no public memberwise inits on derived state,
  `PersistenceConfiguration` is a struct, `MessageContent` renamed,
  **`Understudy`** shipped as the test-double package's real name.
- ADR-003 ratified; ADR-001 D-1/D-2/D-3 closed; SPEC rev 7 ratified.

---

## 2. Context that must survive compaction

The M3 audit (2026-07-26) read the installed SDK's `FoundationModels.swiftinterface`
(path in CLAUDE.md; 3,583 lines, Beta 4) against SPEC §14. **Seven of the nine
OQs are now answerable by reading.** These facts feed rev 7 (§6) and M6; do not
re-derive them:

| Fact | Where in the interface | Feeds |
|---|---|---|
| `LanguageModelSession(model: some LanguageModel, tools:, transcript:)` exists | ~L1910 | OQ1 closed — rehydration initializer |
| `LanguageModelSession.Error` — `.concurrentRequests`, `.transcriptMutationWhileResponding` | ~L1985 | OQ6 closed — busy session is a **typed error** now, superseding the iOS 26 "surfaces as `rateLimited`" evidence. §7.2 gate stays as insurance. M6 residue: confirm it's *thrown*, not trapped |
| `ResponseStream.Snapshot { content, rawContent, transcriptEntries (27+), usage (27+) }` | ~L2200 | OQ4 closed |
| Provider channel has **`replaceTextSegment`** beside `appendText`, both with `segmentID` | Response.Action | **§7.3's prefix property is provider behavior, not an API guarantee.** M6 should diff segment-aware via `transcriptEntries`, or expect the fail-loud path to fire on well-behaved providers |
| `Transcript.Entry` has a **seventh case: `attachment`** (multimodal, 27+) | ~L2253 | N11 count stale; text-only user content is now a *scoping decision* to own in rev 7 |
| `Transcript.ToolCalls` / `.ToolOutput` / `.Reasoning` all have **public inits**; reasoning carries `segments` + `signature: Data?` | ~L2475–2604 | OQ2/OQ9 closed — v0.2 transcript-fidelity is feasible, reasoning recordable *in principle*; v0.1 ignores by choice |
| `LanguageModel` protocol = `capabilities` + `executorConfiguration` only; configurations opaque; **no `modelID` key anywhere** | ~L1440 | OQ8 closed — requested `ModelDescriptor` is **app-supplied at driver init**; `StopInfo.resolvedModelID` is provider convention, expect nil on-device |
| `ContextOptions { includeSchemaInPrompt, reasoningLevel }`; `Transcript` is `MutableCollection` + `RangeReplaceableCollection` at 27; `TranscriptErrorHandlingPolicy { .revertTranscript, .preserveTranscript }` | ~L3068, ~L2754 | OQ7 closed — everything is session-scoped; §2's sherlock check **passes** |
| `LanguageModelError.RateLimited` carries **`resetDate: Date?`** (not a duration) | ~L1516 | §8 lift rules gain an Apple-native third form; driver converts date→duration at normalization time |
| `LanguageModelError.ContextSizeExceeded` carries **`contextSize: Int, tokenCount: Int`** | ~L1500 | D17 — the one wire decision, below |
| `Usage.Input { totalTokenCount, cachedTokenCount }`, `Usage.Output { totalTokenCount, reasoningTokenCount }` | ~L1955 | §7.7's ⚠️ closes; maps 1:1 onto `TokenUsage`'s four fields |
| `Refusal.explanation` is an **on-demand generation** (`Response<String>` property), not stored data | ~L1639 | Confirms rev 6's decision not to project refusal text |

**Also decided at the boundary (2026-07-26): the test-double package is named
`Understudy`.** The theatrical metaphor is load-bearing (`Script`, `Cue`,
"park"); the name is unmistakably third-party in a `LanguageModel*` namespace
Apple grew four types into this cycle; and discoverability is the package
description's job, not the module name's. SPEC §10.1's provisional-name clause
resolves in rev 7.

---

## 3. Decisions (made up front; revisit only at a review gate)

### D13 — Contract hygiene precedes all store work *(Phase 0)*
Every M3-audit API finding lands **before** the store exists, in one pass:

- **Internal-ize the derived-state memberwise inits** — `Message`,
  `Conversation`, `QuarantinedEvent`, and `ConversationSummary` (found while
  planning: same class of type, same argument). Consumers get illegal states
  (a `.streaming` user message carrying a `generationID`) from inits the
  reducer never needed to be public. The evidence they serve no one: the
  Playground already needs `@testable` to reach `MessageTree`'s internal nodes
  init, so public inits on the *elements* of an unbuildable tree were dead
  surface. The honest preview path — build a small event list, call
  `Conversation(reducing:loadedFrom:)` — exercises real semantics and cannot
  produce illegal states. Tests, the Playground, and fixtures are all
  `@testable` and unaffected.
- **`Content` → `MessageContent`.** Wire-neutral: Swift type names never reach
  any encoding (payload tags are `Kind` raw values; the snapshot's synthesized
  coding uses case/label names; StateDump switches on case names per D10).
- **`MessageState.failed` gains labels** —
  `case failed(partial: String, error: GenerationError, recoverability: Recoverability)`.
  Positional pattern matches still compile; construction and labeled matches
  become self-documenting.
- **`GenerationError: CustomStringConvertible`** — non-contractual prose, the
  `QuarantineReason` pattern, so apps stop reaching for `String(describing:)`.
- **`PersistenceConfiguration` becomes a struct with static factories**
  (`.sqlite(url:)`, `.inMemory`) — D12's own rule ("enums for values consumers
  destructure, structs-with-factories for instructions consumers construct")
  applied to the first type it obviously governs. Configurations are
  constructed, never switched over, and this one *will* grow options (file
  protection, snapshot cadence). Same argument applies to `ScriptExhaustion`,
  weakly; do it in the same pass while both packages are open.

### D14 — `LedgerKitTestSupport` → `Understudy` *(Phase 0)*
Decided 2026-07-26. The rename is **maximally cheap right now**: LedgerKit does
not yet import the package (its test target first does at M5/M6), so the blast
radius is the package's own directory, manifest, product, module, its tests'
imports, the Xcode scheme (added at M3), the workspace reference, and the
living docs (CLAUDE.md, ROADMAP.md). Historical documents (M3-PLAN, SPEC rev ≤6
text) keep the old name as a matter of record; SPEC §10.1 updates in rev 7.
Directory, package, product, and module are all `Understudy` — one name, no
variants.

### D15 — One production wire encoder; ADR-001 D-1 closes *(Phase 1)*
Extract an internal `WireJSON` (name illustrative) into LedgerKit proper:
`JSONEncoder` with `[.sortedKeys, .withoutEscapingSlashes]`, **compact** — the
canonical bytes the store writes. The corpus *files* stay pretty-printed
(readability is their job; that is the file format, not the store's bytes) —
the nuance D-1's phrasing glossed: "the store must share the corpus's encoder"
really means **byte-level pinning happens against `WireJSON` output**, via
literal-string assertions (WireFormatTests already pins one under sorted keys;
extend deliberately) and the Phase 2 store↔corpus equivalence tests, which
compare *values after decode*, where whitespace is invisible. Snapshots also
encode via `WireJSON` for uniformity — while noting that per §6.3 that
conformance commits to nothing.

### D16 — Schema-version placement *(ADR-001 D-2)* — **RESOLVED: column-only** (2026-07-26, Alexander)
§9: "every event row carries a schema version." Column-only, or column + blob?
- **Column-only (recommended):** version is loader routing metadata, exactly
  like `sequence` — "bytes below, meaning above" says bookkeeping lives in
  columns. Transport/export moves *rows* (sequence, version, blob), never bare
  blobs — ADR-001's bytes-move-as-rows rule already implies this. The corpus
  row form gains a `version` field (defaulted `1`) at the same time, keeping D5's
  table-mirroring honest.
- **Column + blob (the counterargument):** a self-describing blob survives
  being separated from its row, the `conversationID` precedent. Costs a
  permanent envelope key on every event ever written.
Present both to Alexander with the DDL; record the outcome here and in ADR-001.

**Outcome:** column-only, as recommended. Recorded in ADR-001 D-2 (closed) and
ADR-003's "Settled at M4 Phase 1". Consequence worth stating so the column's
silence is not mistaken for neglect: **nothing reads it yet, by design** — with
one version there is nothing to route. It is the hook an upcaster hangs from, and
the first version bump is what gives it both a switch and a test. The corpus
`version` field lands with Phase 2's row-form work.

### D17 — `contextSizeExceeded` gains an optional payload *(pending rev 7 approval; Phase 4)*
The recommendation from the audit, restated so the wire reasoning survives:
Apple's error carries `contextSize` and `tokenCount`; the `.reduceContext`
affordance wants "how far over" (N3 makes overflow a headline failure on-device);
and widening the case **later** is expensive while widening it **now** is
additive. Shape: `case contextSizeExceeded(contextSize: Int?, tokenCount: Int?)`
with absent-key optional encoding. **This is not a tag retirement** — the
`contextSizeExceeded` tag is unchanged; old logs decode with nil fields; old
readers ignore unknown keys (keyed containers skip extras). The two new field
keys join ADR-001 R-2's registry. Classification is untouched (the mapping
ignores the payload, same as `rateLimited`). A `wire/` fixture pinning the
**field-less** old form lands with the change, so the pre-widening bytes stay
decodable forever by test rather than by assumption.

### D18 — Property sweeps stay exhaustive, and P1 splits are P3's discipline *(Phase 4)*
M3's rule carries forward: no seeds, no randomized flake — corpus fixtures are
small, so P1 enumerates **every flush split of every fixture** (the
`persisted ++ tail` boundary at every row), same shape as P3's split sweep.
D6 also carries: generators only ever *remove or split*; never reorder, never
duplicate (§6.6 ordering precondition).

### D19 — `events.payload` is TEXT; `snapshots.payload` stays BLOB *(taken during Phase 1)*
Not planned up front — surfaced writing the DDL, where §9's word "blob" turned out
to be describing *opacity*, not a SQLite storage class.

**Decision: `events.payload` is TEXT holding UTF-8 JSON.** JSON *is* text, and the
whole point of the events table is that it is the audited, permanent truth. A log
that `sqlite3 ledger.db "SELECT payload FROM events"` prints readably is worth
real money in a project whose fixtures are documentation and whose §10 story is
"how do you even debug this" — and it puts SQLite's `json1` functions within reach
for ad-hoc triage (`json_extract(payload, '$.payload.kind')` over a hostile log
beats writing a program). BLOB renders as hex, which costs exactly that.

**This does not weaken ADR-003 rule 2.** That rule asks the database never to
*interpret* the value, and TEXT honours it identically: SQLite stores and returns
the bytes, LedgerKit's loader is still the only thing that decodes them. Nothing
about the column type invites the database to participate in meaning.

**`snapshots.payload` stays BLOB**, and the asymmetry is the reasoning rather than
an oversight: the seam types that payload as `Data`, a snapshot is a disposable
cache of a fold rather than audited truth, and nobody has ever wanted to read one
by eye. Converting `Data` → String → `Data` to buy readability nobody needs is
work in exchange for nothing.

**Costs accepted:** one UTF-8 conversion per row in each direction (JSON is always
valid UTF-8, so it cannot fail); and the two tables now differ, which is a fact a
reader could mistake for accident — hence this entry, the DDL comment, and
ADR-003's settled section all saying why.

---

## 4. Public-API ergonomics guardrails for M4

M4 adds **almost no public surface, deliberately** — that is the review
standard for every diff in Phases 1–3. After M4 the public additions are:
`PersistenceConfiguration` (struct, factories, no public stored properties) and
`ConversationSummary` (read-only; internal init after Phase 0). Everything else
is internal: `PersistenceStore`, the GRDB conformance, `Snapshot`, `WireJSON`,
the loader.

Rules to hold every change against:

1. **GRDB never leaks** (ADR-003 rule 1) — not in signatures, not in thrown
   error types, not re-exported. A GRDB error crossing the seam is wrapped.
2. **Constructed-not-destructured types are structs with factories** (D12).
   `PersistenceConfiguration` is the template; anything similar M4 tempts you
   to add (snapshot policy, file-protection choice) follows it.
3. **No public memberwise inits on derived or read-model state.** The log is
   the only public way to make a `Conversation`; the store is the only way to
   make a `ConversationSummary`.
4. **No new public error type at M4.** The seam is internal; failures surface
   through the store actor at M5, where `LedgerError` gets designed *once*,
   against real verbs (§6.5/§11). Resist sketching it early.
5. **Options have homes before they have names.** File protection
   (`.completeUntilFirstUserAuthentication` minimum, §9) is *applied* at M4 as
   a default; whether it's *configurable* is an API decision the struct shape
   keeps cheap to defer.
6. **Doc comments carry positioning** — the standard set by
   `Store/Persistence.swift`; a reader of any public symbol should learn why
   it is shaped that way, not just what it does.

---

## 5. Phases

Phase 0 gates everything (it renames things the other phases touch). Phases
1→2→3 are sequential (verbs → loader → snapshots). Phase 4 needs 1–3; the rev 7
*draft* can happen any time after Phase 0 and must be approved before Phase 4's
D17 task.

---

### Phase 0 — Contract hygiene (the M3-audit pass)

**Goal:** every breaking API change lands before the surface gains callers;
the package the ecosystem meets first gets its real name.

- [x] **Understudy rename (D14)** — ✅ **done 2026-07-26, as its own commit** so
      the mechanical rename stays reviewable apart from the semantic API changes
      below. Directory (`git mv`, so `--follow` history survives all ten files),
      package/product/target names, `Sources/Understudy/`,
      `Tests/UnderstudyTests/`, both `@testable import`s, the shared `.xcscheme`
      (file + three blueprint identifiers) and its user-state plist, the
      workspace `FileRef`, CLAUDE.md (commands, architecture, status, M3
      landmarks), and this plan. `swift build`/`swift test --package-path
      Understudy` green, **21 tests**, warning-free.
      **Split of treatment, deliberate:** operational text (commands, paths,
      architecture, status) was renamed; **historical narrative was not** —
      M3-PLAN, SPEC rev ≤6, and the ROADMAP's struck-through M0/M3 records keep
      `LedgerKitTestSupport` as a matter of record, with one forward-pointing
      note added in the ROADMAP's M3 section so no reader is misled. Rewriting a
      completed milestone's record to match a later decision would falsify the
      log, which is the same instinct tenet 2 applies to conversations.
      **Zero source files needed touching** — no doc comment in the five
      sources ever named the package, which is what D14 meant by minimal blast
      radius; the only remaining mention is `Package.swift`'s new provenance
      comment.
- [x] Internal-ize `Message.init`, `Conversation.init`, `QuarantinedEvent.init`,
      `ConversationSummary.init` (D13). Playground/tests unaffected
      (`@testable`). Each carries its *own* reason at the site, because they
      differ: `Message`/`Conversation` can express states no log produces, a
      hand-built `QuarantinedEvent` asserts a reduction that never happened, and
      a hand-built `ConversationSummary` asserts index facts no log backs.
- [x] `Content` → `MessageContent`, everywhere including doc comments.
- [x] `MessageState.failed(partial:error:recoverability:)` labels.
- [x] `GenerationError: CustomStringConvertible` (prose non-contractual, say so
      in the doc comment; ADR-001's sentinel-string rule already covers the
      `unrecognized` descriptions it will interpolate).
- [x] `PersistenceConfiguration` → struct with `.sqlite(url:)` / `.inMemory`
      factories over internal storage; `ScriptExhaustion` gets the same
      treatment in Understudy.
- [x] Suites green in both packages; **200** (179 + 21), zero warnings.

**Exit:** ✅ zero public memberwise inits on derived state; `import Understudy`
compiles; **200 green** (175 → 179 in LedgerKit: four new diagnostics tests).
**Review gate:** read the whole diff as an API reviewer — this is the last
cheap look at the pre-1.0 surface before M4/M5 freeze it in practice.

**Status: ✅ done 2026-07-26.** Three judgment calls made while implementing,
each recorded here because they are the parts a reader would otherwise have to
reverse-engineer from the diff:

- **`MessageContent.init` stays public** while its four siblings went internal.
  D13's argument is specifically about *illegal states*, and a wrapper over a
  `String` has no invariant to violate — so the rule does not reach it. It also
  earns its keep: a consumer previewing their own bubble view needs some way to
  hand it content, and with `Message.init` gone this is the only remaining way.
- **Only the *public* `MessageState.failed` gained labels; `FoldedMessageState`
  did not.** The position-counting problem is real at three payloads and absent
  at two, and the asymmetry now carries information: the public enum is the one
  consumers destructure, so it gets the ergonomic treatment; the folded one is
  reducer-internal and reads fine positionally. `Classify.swift` shows both in
  four lines — positional destructure of the folded case, labelled construction
  of the public one — which is the clearest statement of the distinction.
- **The Playground was fixed, not rewritten.** Its `.failed` construction needed
  the new labels (playgrounds are invisible to `swift build`, so this would have
  broken silently). Converting it to the honest `Conversation(reducing:)` example
  — which D13's doc comments now advertise — is deliberately **not** done here: it
  is an iOS/UIKit playground that cannot be compile-verified from the CLI, and
  shipping unverifiable code to make a point about good examples is a bad trade.
  A ⚠️ comment at the top of the file records why it needs `@testable` and what
  the real path is. **Carried as a follow-up** — best done in Xcode, or at M7
  when the observable projection gives previews a better story anyway.

**Also landed, beyond the checklist:** four tests for the new rendering
(`ErrorDiagnosticsTests`), asserting **structure and payload propagation, never
prose** — non-emptiness over the whole `Wire.allErrors` inventory, no dangling
separators from the one *assembled* rendering, and that `unrecognized` and
`providerFailure` surface the payloads triage greps for (`"driver:"` prefixes,
status, `code`). Matching on wording would freeze exactly what ADR-001 promises
is loose. Placed beside `Wire.allErrors` because that is the module's only
exhaustive inventory of the taxonomy, and duplicating it is how a future case
silently escapes coverage. **Mutation-tested, both caught:** an empty
description for one case (caught by non-emptiness), and `compactMap` → `map { $0
?? "" }` in the assembly branch, which yields `"provider failure: : "` (caught
by the whitespace/separator assertions). Reverted; `git diff` on the file shows
insertions only.

**A free side effect worth knowing:** Swift Testing renders parameterized-test
arguments via `CustomStringConvertible`, so `GenerationError` cases now appear in
test names as readable prose (`provider failure: status 500: code
overloaded_error: Overloaded`) instead of reflection dumps. The `unrecognized`
floor's `"driver:"` convention is now legible in CI output for free.

---

### Phase 1 — GRDB wiring: schema + verbs

**Goal:** ADR-003 stops being a decision document and becomes a conformance.

**Status: ✅ done 2026-07-26 — 223 tests green** (202 `LedgerKit` + 21
`Understudy`), zero warnings. `Store/SQLitePersistenceStore.swift` (the
conformance), `Store/LedgerSchema.swift` (the two versions), `WireJSON` in
`Core/WireCoding.swift`, and `PersistenceStoreTests.swift` (23 tests in 5
suites). **ADR-003 is Accepted**; **ADR-001 D-1 and D-2 are closed**.

**Decisions taken at the gate, as recommended:** D16 → **column-only**;
`DatabasePool` for `.sqlite`, `DatabaseQueue` for `.inMemory`. Both are written up
in ADR-003's new "Settled at M4 Phase 1" section rather than only here, since
that is where a future reader looks.

**Three things decided while implementing, recorded because the diff does not
explain itself:**

- **`events.payload` is TEXT, not BLOB** (new, D19). JSON is text, and a log that
  `sqlite3 ledger.db "SELECT payload FROM events"` prints readably is worth real
  money in a project whose fixtures are documentation — it also puts SQLite's
  `json1` functions within reach for triage. ADR-003 rule 2 asks only that the
  database never *interpret* the value, which TEXT honours exactly as well.
  Snapshots stay BLOB: the seam types that payload as `Data`, it is a disposable
  cache rather than audited truth, and nobody reads a snapshot by eye.
- **The two version numbers are separate constants**, not one. A payload bump
  selects an upcaster and invalidates nothing; a reducer bump discards snapshots
  and migrates nothing. A single "schema version" could only have had one of
  those two behaviours, and picking either would have made the other
  inexpressible. `LedgerSchema` documents which is which and when to bump.
- **`load` is internal rather than private**, so the two-stage decode rules are
  tested by handing them bytes. That is both the sharper test and the cheaper
  one: the rules are pure, so going through a database would have added I/O *and*
  a GRDB dependency in the test target to verify something with no storage in it.
  This pulled the loader's unit tests **forward from Phase 2**, which is a
  deviation worth naming — Phase 2 keeps its real substance (the corpus `raw`
  form, row-1/2 fixtures on disk, `rich`/`hostile` on disk, end-to-end
  equivalence) and no longer has to invent a corrupt-row injection mechanism.

**Mutation-tested, all four caught, all reverted** (file diffed byte-identical
against its pre-mutation backup afterwards):

| Mutation | Caught by |
|---|---|
| Sequence assignment skips a number | contiguity **and** backend-assigns-sequence |
| `updatesIndex` returns `true` for `deltaAppended` | the ~4 Hz churn test, on both assertions |
| Single-stage decode (envelope discarded with payload) | all three row-1/row-2 identity tests |
| Conversation-mismatch check removed | foreign-batch rejection, on all three assertions |

The fourth is worth dwelling on: without that check, records naming a *foreign*
conversation were written into this conversation's sequence run — the writer
manufacturing exactly the cross-stream contamination §6.6 row 4 exists to detect
at read time. The check does not merely reject bad input; it prevents the store
from creating a condition the reducer would later have to diagnose.

**One gap closed late:** every suite initially used `.inMemory`, leaving the
production path — `DatabasePool`, WAL, file protection, and *migrating a database
that already has the schema* — completely untested. `PersistenceFileBackendTests`
now writes a real file, closes the store, reopens it, and reads back. Migration
idempotence on reopen is the cold-open path every app launch takes and the one
DoD-1's kill-and-relaunch demo depends on.

**Deferred deliberately:** the `schema_version` column's *value* is unasserted.
It is exercised (a wrong column name or a NOT NULL violation fails every append)
but nothing reads the number back, because nothing reads it at all yet — with one
version there is nothing to route. It is the upcaster hook, and the first version
bump is what gives it a test.

- [x] Add GRDB, pinned (first external dependency — record the version and the
      supply-chain note from ADR-003 in the commit message). **GRDB 7.11.1** via
      `from: "7.9.0"` — `.exact(_:)` in a *library* manifest would force a
      resolution conflict on any consumer who also depends on GRDB, a cost paid
      by other people to buy us nothing, since `Package.resolved` already pins
      exactly for our CI.
- [x] **DDL:** `events` keyed `(conversation_id, sequence)`, TEXT payload (D19),
      `schema_version` column-only (**D16 resolved: column-only**); `snapshots`
      (one row per conversation, BLOB payload); `conversations` + a
      `last_event_at DESC` index. All `STRICT`.
- [x] **`DatabaseQueue` vs `DatabasePool`:** confirmed as recommended — `.sqlite`
      → `DatabasePool` (WAL, the production shape; M7's concurrent projection
      reads want it), `.inMemory` → `DatabaseQueue` (in-memory pools don't
      exist), both behind `any DatabaseWriter`, which is why ADR-003 called this
      "not an API decision."
- [x] `append(_:to:)`: one transaction; **sequence assigned inside the write**,
      contiguous from 1; index maintenance on non-delta kinds derived from the
      payloads via an exhaustive `Payload.updatesIndex`, so a future kind cannot
      be added without deciding which side of the line it falls on; whole-batch
      rejection *before* the transaction opens; returns assembled
      `[LedgerEvent]`; empty batch is a no-op returning `[]`.
- [x] Debug-assert appended timestamps are born canonical
      (`WireDate.canonical` fixed point) — asserted rather than *repaired*, since
      canonicalizing at write time would give every event two identities
      depending on whether it had been to disk. `Log.timestampsAreCanonical`
      pins the fixture side so a violation reads legibly instead of trapping
      inside a store call (M3 handoff #3).
- [x] File protection `.completeUntilFirstUserAuthentication` at database
      creation (§9). Applied, not yet configurable (guardrail 5); the `-wal`/
      `-shm` and directory-level limitations are owned in ADR-003.
- [x] `deleteConversation`: transactional across all three tables, and scoped —
      both asserted.
- [x] `conversationSummaries()`: ordered `lastEventAt` descending, one read.
      Canonical ISO 8601 UTC means lexical order *is* chronological, so the index
      serves the sort without a collation.
- [x] **`WireJSON` extracted** (D15); the store encodes through it and nothing
      else; `pinnedJSON` now encodes through it too — a test configuring its own
      encoder would pin bytes nobody writes, hiding the *symmetric* fault that
      assertion is the only instrument for.
- [x] Tests: append/read round-trip value-identity (and that `append`'s return
      equals a subsequent read — the property M5's fold-forward depends on);
      sequence contiguity across three separate transactions; index rules
      including the ~4 Hz churn guard; delete; snapshots; list ordering;
      two-stage decode; **and the file backend**.

**Exit:** ✅ six verbs implemented and tested; **223 green**, zero warnings.
**Review gate:** DDL review with Alexander; **D16 decided and recorded** (here,
ADR-001 D-2, and ADR-003); **ADR-003 is now Accepted**.

---

### Phase 2 — Two-stage loader + corpus integration

**Goal:** §6.6's input corollary implemented by production code, and the two
corpus gaps M3 deliberately left (`raw` rows; `rich`/`hostile` on disk) close.

> **Pulled forward into Phase 1:** the loader itself and its unit tests are
> **done**, because `load` is a pure function over bytes and testing it through a
> database would have cost I/O and a GRDB dependency in the test target to verify
> something with no storage in it. What remains below is Phase 2's real
> substance — the *corpus* work — which no longer has to invent a corrupt-row
> injection mechanism.

- [x] `events(in:from:)`: **envelope first, payload second**. Row 1 →
      `.undecodable(sequence:eventID: nil, .envelope)`; row 2 →
      `.undecodable(sequence:eventID:, .payloadKind(tag))` with the envelope's
      identity recovered and the tag where legible. Never throws per-row, never
      drops a row, passes gaps through untouched (the fold diagnoses them).
- [x] **`CorpusFile` `raw` row form implemented** (M3 handoff #1) — stops
      throwing; routes bytes through `SQLitePersistenceStore.load`, the very
      function the store calls on every row it reads. The decode boundary now
      exists in exactly one place; the corpus consumes it rather than
      reimplementing it (the drift D5 refused to freeze).
- [x] **`wire/` gains row-1 and row-2 fixtures** — `undecodableRows`: a truncated
      row and a wrong-typed envelope field (both lose identity), a *future*
      payload kind (keeps identity, names itself), a non-object payload (keeps
      identity, no legible tag), and a trailing valid event proving reduction
      continued past five damaged rows in a row.
- [x] **`rich` and `hostile` land on disk** via `raw` rows — excluded at M3
      *because* they contained synthesized `LoadedEvent.undecodable` rows; those
      are now built **from bytes**, so the reason expired by construction
      (M3 handoff #2).
- [x] End-to-end equivalence: every *replayable* corpus fixture written through
      the store, read back, and folded lands on the same `FoldedState` the
      in-memory fixture folds to.

**Exit:** ✅ loader is the only decode site; the corpus runs against bytes the
production loader read. **226 green** (205 + 21).
**Review gate:** walk the row-2 path end to end — this is the
forward-compatibility diagnostic a developer will actually read in 2027;
its quality is the point of two-stage decode.

**Status: ✅ done 2026-07-26.** The architectural move worth naming: **corpus
fixtures stopped *synthesizing* damaged rows and started *deriving* them from
bytes.** M3 could not do this — with no real loader, the only way to give a
damaged row meaning was to write the answer test-side, which would have frozen
fixtures against a reimplementation of the decode boundary. Now
`Log.unknownPayloadKind(_:)` and `Log.corruptRow(_:)` build bytes and run the
production loader over them, so the file on disk contains exactly the input the
in-memory fixture folded — one source of truth instead of two descriptions.

`Log.undecodable(_:identified:)` survives and still synthesizes, deliberately: the
fold's contract is to turn a loader outcome into a diagnostic, and where the value
came from is none of its business, so fold-level unit tests may legitimately hand
it one. What changed is that `CorpusDocument(_:)` refuses to serialize a
synthesized row — the split is enforced, not merely advised.

**The coverage gain is bigger than "two more files".** The corpus now *depends on*
the loader: mutating the loader's tag recovery breaks `rich`/`hostile`'s
**in-memory** residue expectations, which was impossible while those fixtures
minted their own reasons. Two layers that used to be independently right about the
same thing are now wired together.

**Store equivalence is scoped, and the scope is stated in code** rather than as a
list of fixture names that goes stale: `Log.isStoreReplayable`. Three fixtures are
excluded and each for a structural reason — `gapSwallowedTerminal` has a gap
(`append` assigns contiguous sequences inside the write transaction and must not
reproduce a hole), `rich`/`hostile` have byte-built rows (encoding is total,
decoding is not — the typed write path cannot express an unreadable row) and
`hostile` additionally has a foreign event (`append` rejects the batch rather than
manufacture what §6.6 row 4 exists to detect). Mutation-testing confirmed the
exclusion is load-bearing: widening it to everything produces both a fold mismatch
and a thrown `conversationMismatch`.

**Mutation-tested, all four caught, all reverted** (three files diffed
byte-identical against their backups afterwards):

| Mutation | Caught by |
|---|---|
| Corpus `raw` rows bypass the production loader | the wire-dump comparison **and** all three tag assertions |
| Loader drops the unknown-kind tag | `rich`/`hostile` in-memory residue, at fold *and* classify |
| Row-1 diagnostics wrongly claim identity | both corrupt-envelope tests |
| `isStoreReplayable` widened to everything | store equivalence, on fold mismatch and on the rejected batch |

**One bug found in my own test helper, worth recording** because it is the failure
mode CLAUDE.md warns about in the reducer, committed one layer out:
`isStoreReplayable` first compared against `Array(1...Int64(rows.count))`, which
**traps** for the zero-row `empty` fixture. The whole test process died with a
signal instead of one expectation failing. Rewritten as an `enumerated()` walk. The
lesson generalizes past the reducer: a trapping *helper* is worse than a failing
one, because it destroys the report that would have told you what broke.

**Found and pinned, not fixed — for SPEC rev 7 (§6 item 14).** A payload kind this
version *does* know, carrying a body that will not decode, is reported as
`unknownPayloadKind("deltaAppended")`. The disposition is right (skip the row, keep
identity, keep reading) but the wording misleads, because §6.6 rows 1–2 have no
case for "known kind, malformed body" — row 1 is "no identity recoverable", row 2
is "unknown discriminator", and this is neither. `wire/undecodableRows` pins the
behaviour so it cannot drift unnoticed.

---

### Phase 3 — Snapshots + cold open

**Goal:** the §9 fast path, provably equivalent to replay (P3 is the law here).

- [x] `Snapshot` payload = `WireJSON`-encoded `FoldedState` (synthesized
      `Codable` — disposable by design; the *version fields* are the contract).
      `reducerVersion` / `schemaVersion` constants live in `LedgerSchema`.
- [x] **Discard-on-mismatch without decoding** (version fields ride outside the
      payload). **Four conditions, one branch** — either version disagrees, the
      payload does not decode, the payload names a different conversation than its
      key, or `upToSequence < 1`. Never fatal, never migrated. Logging is deferred
      to M5 for the same reason §8 defers "logged loudly" to normalization: the
      obligation belongs to the layer that has a logger.
- [x] Resume path: `latestSnapshot` → decode → `fold(resuming:after:with:)` over
      the suffix read, as `PersistenceStore.foldedState(of:)`. An **extension, not
      a seventh verb** — ADR-003 rule 4 caps the seam at six requirements, and this
      is a composition of three of them, so policy stays above the seam and no
      backend can override it.
- [x] **P3 against the real store**, and against the codec — see below; these are
      two distinct sweeps, and only one of them can reach diagnostics.
- [x] **Cold-open criterion: 10,004 events, 3 rows replayed, ~28 ms.** Measured on
      the resume path itself via a counting `PersistenceStore` wrapper, not by a
      separate read that would only prove *a* suffix read is cheap.
- [x] Corrupt-snapshot fixtures: truncated payload, both version mismatches,
      foreign payload, impossible sequence — plus a **control** asserting a
      current checkpoint *is* usable, without which every one of those could pass
      because nothing is ever usable.

**Exit:** ✅ cold open ≤ one generation's suffix, by construction and by test.
**239 green** (218 + 21).
**Review gate:** snapshot policy read against §9 line by line (best-effort,
diagnostics persisted, `.open` stored open).

**Status: ✅ done 2026-07-26.**

**Two P3 sweeps, because one cannot cover what the other does.** M3 already swept
P3 at every split of every fixture — but entirely in memory, handing a live
`FoldedState` straight back to `fold(resuming:)`. The new sweeps add the two
things that make it a persistence property:

- **Through the codec** (`SnapshotCodecTests`) — *all* fixtures, all splits. No
  `append` is involved, so gaps and byte-built rows are fine, which matters
  because `rich` and `hostile` are the only fixtures with **diagnostics**. This is
  the sweep that enforces §9's "snapshots must persist diagnostics", and it counts
  its residue-carrying checkpoints (≥10) so the claim cannot go vacuous.
- **Through the store** (`SnapshotStoreTests`) — replayable fixtures only, all
  splits, real SQLite. Split 0 runs first, while no checkpoint exists, because
  `save` replaces and the pure-replay path is otherwise unreachable.

**`after:` is load-bearing, not bookkeeping.** The resume passes
`snapshot.upToSequence` as `after:`, and the codec sweep passes *the last folded
row's sequence* — not the row count, which is a different number the moment a log
has a gap. Getting it wrong is how a hole straddling the checkpoint boundary
silently closes; mutation-testing it to `0` fails the store sweep immediately.

**Mutation-tested, all four caught, all reverted** (file diffed byte-identical
afterwards):

| Mutation | Caught by |
|---|---|
| Snapshot drops `diagnostics` | codec sweep, on both the round-trip and the resume |
| Resume reads from `upToSequence` (off by one, so deltas double) | store sweep |
| Version + sequence guards removed | all three discard tests |
| `after: 0` — checkpoint boundary lost | store sweep |

The off-by-one is the one worth naming: re-reading the checkpoint's last row is
harmless for every payload kind *except* `deltaAppended` and
`toolInvocationRecorded`, which accumulate (§6.6's ordering precondition). It
would have doubled a message's text at exactly the splits where the last folded
row was a delta, and left every other split green.

**The cold-open test asserts the recovery shape, not just an equal state.** First
draft parented the interrupted turn to `nil`, which quarantines under I6 and
cascades — so it would have measured three diagnostics while claiming to measure
crash recovery. Now the turn is a legitimate continuation, and the assertion is
`.open(partial: "half an ans")` with **zero** diagnostics: DoD-1's mechanism
reached *through a snapshot resume*, which is the path that could silently fail
here, since the generation→message routing map has to be rebuilt from
`FoldedMessage.generationID` rather than replayed.

**Cost owned:** the suite went 0.18 s → 0.58 s, essentially all of it *appending*
10k records (the resume itself is 28 ms). Worth it — the roadmap's exit criterion
names 10k, and a criterion tested at 100 events is not the criterion. The
comparison test was trimmed to 100 generations, since proving "reads everything"
needs no particular size.

---

### Phase 4 — Property tests + rev 7 implementation

**Goal:** the §10.6 obligations M4 owns, plus the one wire change rev 7 approves.

- [x] **P1 (fold/tail equivalence):** `reduce(persisted ++ unflushedTail) ==
      reduce(logAfterFlush)` — exhaustive over every fixture × every split
      (D18). This is the shape the M5 store actor will live by
      (`append` returns the tail so the actor folds forward); prove it now.
      `FoldForwardTests.swift`, three tests: the fold level, the **classified**
      level (§10.6 states P1 over `reduce`, and `classify` is where I5's
      finalization lives), and the many-small-flushes composition.
- [x] **P2 scaffolding only:** parameterize the projection-equivalence harness
      over a live set, test with the empty set (≡ fold identity). The overlay
      itself is M7's; the harness existing is what "scaffolding" means.
      `ProjectionChecks.swift` (the predicate + `LiveSet`/`LiveOverlay`/
      `identityOverlay`) and `ProjectionCheckTests.swift` (the sweep + seven
      tests *of the predicate*).
- [x] **D17, if rev 7 approves:** widen `contextSizeExceeded`; optional named
      keys; `RecoverabilityMapping` untouched; ADR-001 R-2 registry gains
      `contextSize`/`tokenCount`; `LEDGERKIT_RECORD=1` regenerates `dev/`; a
      `wire/` fixture pins the field-less old form forever.
      **Approved by Alexander 2026-07-26** as part of the Phase 4 instruction;
      the *SPEC* text (rev 7 item 11) still lands in Phase 5's drafting session,
      which is the only thing left of D17.
- [x] **Registry enforcement (ADR-001 D-3):** a test over a checked-in
      `tags.json` mirroring R-3's inventory — payload kinds, outcome kinds,
      error kinds, raw-value enums, R-2 field keys, and the reserved table.
      Fails loudly on reuse, rename, or silent removal. (Scoped small: a
      manifest test, not a code generator.)
- [x] Mutation-test the suites whose failure mode is subtle (the M3 practice,
      now standing policy): break sequence assignment (skip a number), break
      snapshot version checking (accept mismatched), break the loader's
      envelope-first order (drop identity), break index maintenance (update on
      deltas) — each must be caught, then reverted. **Six injected, six caught**
      (table below), every file diffed byte-identical against its backup after.

**Exit:** ✅ P1/P3 green corpus-wide against the store; registry test green.
**266 green** (245 `LedgerKit` + 21 `Understudy`), zero warnings.
**Review gate:** rev 7 draft review against §6 below — the drafting session
should start from that list, not from memory.

**Status: ✅ done 2026-07-26.**

**P1 is not P3 with different words, and the distinction is the reason it needed a
store.** Both split a log; P3 puts a *checkpoint* through a boundary and resumes,
while P1 puts the **tail** through one — or rather asks whether it needs to. Its
whole question is whether the values `append` handed back are interchangeable with
the bytes a re-read decodes, and in memory those are the same array, so only a real
store can answer it. The failure modes it owns are therefore the store's: a sequence
assigned wrongly in a *second* transaction, a timestamp that does not survive its own
encoding (ADR-001 R-5), an encoder asymmetric in one direction. Each would leave the
M5 actor's in-memory state quietly disagreeing with its own database — the worst
available shape, since both halves look fine alone.

**Three sub-properties, deliberately separate:** `append`'s return equals what a read
returns (per split, not once per fixture — that is where a `MAX(sequence)+1` slip in a
second transaction shows); the fold-forward equals the replay; and the *classified*
reduction agrees too, because a flush landing mid-generation must not finalize
differently from a full replay or the shortcut could manufacture a phantom crash.

**P2's scaffolding is a parameterization, not a stub.** The overlay is an argument
(`LiveOverlay`), so M7 changes what is passed in and not one assertion. `identityOverlay`
is not a placeholder either — it is the literally correct overlay for an empty live
set, which is the state every cold open lands in, so §10.6's "crash recovery is P2's
degenerate case" is testable *today*. The sweep runs it over every fixture at every
truncation (a truncation is a crash) and counts the `.interrupted` messages it saw, so
the claim cannot go vacuous.

**The predicate has its own tests, which is the `InvariantCheckTests` argument
transplanted:** a predicate returning `[]` for everything would make that sweep pass
while enforcing nothing — and the sweep is the part still running at M7. So seven tests
feed it deliberately wrong projections (faked `.streaming` with nothing live; a live
generation left dead; the wrong partial; a live set naming a terminated generation; an
overlay that edits the title or drops a message) plus a control. Gutting
`projectionProblems` to `return []` fails six of them.

**A `referenceOverlay` exists in the test target and is deliberately not shipped.**
Without *some* satisfying overlay, clauses 1 and 3 would only ever be shown failing
inputs, and a predicate nothing can satisfy passes the same way a correct one does.
It is a control in `SnapshotDiscardTests`' sense; M7's real `overlay_live` replaces the
argument, never the predicate.

**D-3's answer turned out to be three mechanisms, not one**, and the reason is worth
keeping: a both-directions manifest comparison cannot see a *deleted* case, because
nothing observes a tag that no longer exists. What closes it is coupling the registry
test to `Wire`'s exhaustive inventories (now `internal` for exactly this), so removal
fails to **compile**. Renames and unregistered additions are the manifest's;
reuse is caught twice — once as bookkeeping, once by requiring a reserved tag to
*throw* on decode, which is the half that survives someone "restoring compatibility"
in the decoder.

**One duplicate retired:** `CorpusFileTests` held its own hard-coded copy of the ten
payload kinds and now reads the manifest. A second copy of a registry can only drift
from the first — and then the test enforcing the registry is the one asserting the
stale answer.

**D17 landed additive, and the corpus proved it rather than the commit message
claiming it:** `dev/` is byte-identical after `LEDGERKIT_RECORD=1`, because no existing
fixture uses the case and the nil form encodes to the pre-widening bytes exactly. The
cost that is *not* free is Swift-side — enum cases cannot have default parameter
values, so every construction site must now spell both labels. Three test files, today;
that number only grows.

**Mutation-tested, all six caught, all reverted** (every file diffed byte-identical
against its backup afterwards):

| Mutation | Caught by |
|---|---|
| A retired tag made live again (`Kind.contextSizeExceeded = "contextWindowExceeded"`) | 8 tests, incl. **both** halves of the reserved check and the D17 legacy fixture |
| A registered field key renamed (`endpoint` → `pathEndpoint`) | the registry's field-key check, plus every `dev/` byte comparison |
| The manifest gutted (a level emptied, the reserved table cleared) | the level check, the corpus-coverage check, **and** both non-vacuity floors |
| `append` returns a sequence it did not write | P1's fold-forward equality **and** its return-equals-read sub-property |
| `append` skips a sequence number | P1 (`replayed == whole`), cold open, store equivalence |
| `projectionProblems` returns `[]` unconditionally | six of the seven P2 predicate tests |

The first is the one to dwell on: it is *tag reuse*, the single thing ADR-001 forbids
outright, and it was caught by a test that reads a JSON file and by a test that expects a
decode to throw. Either alone would have been enough this time; neither alone covers the
other's failure mode.

**Also fixed in passing:** four `try` markers left over from Phase 2 (when
`CorpusDocument.loadedEvents()` stopped throwing) were emitting warnings. Both packages
are warning-free again.

---

### Phase 5 — Wrap-up

- [ ] **SPEC rev 7 ratified** at the M4 boundary (new appendix, "Changes from
      rev 6" header; every §6 item below dispositioned — landed, deferred, or
      rejected with reasoning).
- [ ] ADR-003 → Accepted; ADR-001 D-1/D-2/D-3 recorded closed with outcomes.
- [ ] ROADMAP: M4 struck through with audit note; **OQ tracker updated** —
      OQ1/2/4/6/7/8/9 marked closed-by-reading with their M6 empirical residues
      (§2's table is the source).
- [ ] CLAUDE.md: status paragraph rewritten (M4 done, Understudy landed,
      commands updated, M5 next); new landmarks recorded (WireJSON, loader,
      snapshot versions, registry manifest).
- [ ] Both packages green, warning-free; traceability below filled.

---

## 6. Rev 7 inventory (the drafting checklist — do not draft from memory)

Sourced from the M3 audit; citations are `arm64e-apple-macos.swiftinterface`
line regions (Beta 4 — re-verify line numbers if a new beta lands first).

1. **Close OQ1** — transcript seeding: `LanguageModelSession(model:tools:transcript:)` (~L1910).
2. **Close OQ2** — tool observation: `Snapshot.transcriptEntries` mid-stream;
   `Transcript.ToolCalls`/`ToolOutput` publicly constructible (~L2475/2544).
   §7.6's "live tool UI is a session concern" stands, now with the surface named.
3. **Close OQ4** — element is `ResponseStream<Content>.Snapshot`
   `{ content, rawContent, transcriptEntries, usage }`. **Amend §7.3:** the
   provider channel includes `replaceTextSegment` (+ `segmentID` on
   `appendText`), so append-only plain text is provider behavior, not an API
   guarantee; the driver's fail-loud path is right, and M6 should prefer
   segment-aware diffing over flat-string prefix diffing.
4. **Close OQ6** — `LanguageModelSession.Error.concurrentRequests` /
   `.transcriptMutationWhileResponding` (typed, 27+). Supersedes the iOS 26
   `rateLimited` evidence; §7.2's gate is retained as defense-in-depth; the
   normalization exclusion now names this error. M6 residue: thrown vs trapped.
5. **Close OQ7** — sherlock check passes: `ContextOptions
   { includeSchemaInPrompt, reasoningLevel }` is per-request; `Transcript` is
   `MutableCollection`/`RangeReplaceableCollection` with
   `TranscriptErrorHandlingPolicy { revert, preserve }`; `session.usage`
   aggregates. All session-scoped. Positioning strengthened: the working copy
   is now officially mutable, which is an argument *for* durable truth outside it.
6. **Close OQ8** — requested descriptor is **app-supplied** (protocol exposes
   only `capabilities` + opaque `executorConfiguration`). Soften §7.8's
   resolved-identity expectation: no standard metadata key exists;
   `resolvedModelID` is per-provider convention, nil expected on-device.
7. **Close OQ9** — reasoning is observable (channel family) and constructible
   (`Transcript.Reasoning { segments, signature, metadata }`). Reword N11:
   "not recordable" becomes "deliberately not recorded in v0.1."
8. **Close §7.7's ⚠️** — usage field names verified; record the
   `Usage.Input/.Output` → `TokenUsage` mapping.
9. **Amend §8 lift rules** — Apple-native rate-limit form is
   `RateLimited.resetDate: Date?`; normalization converts date → duration at
   normalization time (a legal clock read in the driver), preserving the
   clock-independent persisted value and the `terminalTimestamp + retryAfter`
   display contract.
10. **Amend N11 (+ N8 vicinity)** — `Transcript.Entry` has seven kinds
    (`attachment` added, 27+); text-only user content
    (`userMessageAppended(content: String)`) is recorded as an owned v0.1
    scoping decision with additive headroom, not an accident of iOS 26 shapes.
11. **D17** — ✅ **shipped at Phase 4**, so rev 7 *records* rather than proposes:
    `contextSizeExceeded(contextSize: Int?, tokenCount: Int?)`, absent-key
    optionals, tag unchanged, classification untouched. §8's code block and its
    coverage table both need the new payload; note the 1:1 row now carries
    Apple's two fields. Mention `wire/contextSizeExceededLegacy` as the pin on
    the pre-widening form.
12. **§10.1** — the provisional name resolves: **Understudy**. Strike the stale
    OQ3 ⚠️ in the same section.
13. **Footnote** — `Refusal.explanation` is on-demand generation
    (`Response<String>`), not stored data: rev 6's no-projection call confirmed.
14. **§6.6 rows 1–2 have no case for "known kind, malformed body"** (found at M4
    Phase 2, pinned by `wire/undecodableRows`). Row 1 is "no identity
    recoverable"; row 2 is "unknown payload discriminator". A row whose envelope
    reads and whose payload names a kind we *do* know, but whose body will not
    decode, is neither — and the loader currently reports it as row 2, rendering
    the slightly false `unknown payload kind: deltaAppended`. **The disposition is
    right and should not change** (skip the row, keep the identity, keep
    reading — contained loss, exactly like row 2). Only the inventory's wording is
    wrong. Two candidate fixes: widen row 2 to "payload undecodable, with the tag
    where legible", or add a row and a `QuarantineReason` case for a malformed
    known payload. Widening is cheaper and loses nothing a diagnostic reader
    needs; a new case would let fixtures distinguish "from the future" from
    "corrupt", which has some triage value. Either way §6.6 claims to be a
    complete inventory, and today it isn't.

---

## 7. Explicit handoffs to M5 (recorded so they aren't lost)

1. **The stamping site.** The store *actor* mints `Record`s and must stamp with
   `WireDate.canonical` at birth (ADR-001 R-5). M4's debug assertion and the
   corpus's `timestampsAreCanonical` both fail if it slips.
2. **Snapshot refresh policy** (§9: after each `generationEnded`, 500-event
   floor, best-effort async) is store-actor behavior. M4 ships the verbs and
   the resume path; nothing at M4 *triggers* refresh.
3. **`LedgerError` is designed at M5**, against the real verbs — M4 must not
   pre-commit a public error surface (guardrail 4).
4. **`append` returns the assembled tail** so the actor can fold forward
   (`persisted ++ tail`) instead of re-reading; P1 is the property that makes
   that legal, and it is green before M5 starts.
5. **In-flight registration / the live set** (single-flight, §6.5) is M5;
   `overlay_live` and P2's completion are M7.

## 8. Coverage traceability (fill at Phase 5)

| Obligation | Suite / evidence | Status |
|---|---|---|
| §6.6 rows 1–2 from disk (`raw` form + wire fixtures) | Phase 2 | ☐ |
| Diagnostic identity through production loader | Phase 2 | ☐ |
| P1 exhaustive over corpus | `FoldForwardTests` — every replayable fixture × every flush boundary, fold and classify levels | ☑ |
| P3 against real store, diagnostics included | Phase 3 | ☐ |
| Cold-open ≤ one generation suffix (rows replayed) | Phase 3 | ☐ |
| Index maintained on non-delta appends only | Phase 1 | ☐ |
| Timestamps born canonical at the store | Phase 1 + corpus | ☐ |
| Registry manifest (ADR-001 D-3) | `Registry/tags.json` + `RegistryTests` (10 tests) | ☑ |
| No public memberwise inits on derived state | Phase 0 | ☐ |
| Understudy renamed, both packages green | Phase 0 | ☐ |

## 9. Decision log

| # | Decision | Status |
|---|---|---|
| D13 | Contract hygiene precedes store work (audit pass, Phase 0) | **Landed** 2026-07-26 · `MessageContent.init` stays public (no invariant to violate); folded enum keeps positional `.failed` |
| D14 | `LedgerKitTestSupport` → `Understudy`; one name everywhere | **Landed** 2026-07-26 (accepted by Alexander; own commit) |
| D15 | One production `WireJSON` encoder; corpus files stay pretty; bytes pinned against `WireJSON` | **Accepted** · applies Phase 1 |
| D16 | Schema-version placement (column-only vs column+blob) | **Resolved: column-only** 2026-07-26 (Alexander) · ADR-001 D-2 closed |
| D19 | `events.payload` is TEXT (readable via `sqlite3`/`json1`); snapshots stay BLOB | **Accepted** 2026-07-26 · landed Phase 1 |
| D17 | `contextSizeExceeded` optional payload | **Landed** 2026-07-26 (approved by Alexander at the Phase 4 instruction) · additive on the wire, source-breaking in Swift (cases take no default arguments) · SPEC rev 7 item 11 still to draft in Phase 5 |
| D18 | P1 splits exhaustive, D6 generator discipline carries forward | **Accepted** · applied Phase 4 |
| D20 | ADR-001 D-3 closes as a **manifest test coupled to the exhaustive inventories** — the manifest cannot see a deleted case, so `Wire.allKinds`/`allErrors` went `internal` and removal is a compile error | **Accepted** 2026-07-26 · landed Phase 4 |

## 10. Status log

| Date | Phase | Tests | Note |
|---|---|---|---|
| 2026-07-26 | Plan drafted | 196 | Sourced from the M3 boundary audit; D13–D15/D18 accepted, D16 open, D17 pending rev 7 |
| 2026-07-26 | **Phase 0: Understudy rename (D14)** | **196** (175 + 21) | Rename only, as its own commit — no semantic changes. Historical docs deliberately left naming the old package |
| 2026-07-26 | **Phase 0 done (D13)** | **200** (179 + 21) | Breaking-surface pass: four inits internal, `MessageContent`, `.failed` labels, `GenerationError` description (+4 tests, mutation-tested), both config types → structs with factories. Zero warnings. Playground label-fixed; its rewrite carried as a follow-up |
| 2026-07-26 | **Phase 1 done (GRDB wiring)** | **223** (202 + 21) | GRDB 7.11.1, three `STRICT` tables, six verbs, `WireJSON`, `LedgerSchema`'s two versions, two-stage loader (pulled forward from Phase 2). D16 → column-only, D19 recorded. **ADR-003 Accepted; ADR-001 D-1/D-2 closed.** 4 mutations injected, all caught, all reverted |
| 2026-07-26 | **Phase 2 done (corpus integration)** | **226** (205 + 21) | `raw` rows implemented through the production loader; `rich`/`hostile` on disk (M3 handoffs 1–2 closed); `wire/undecodableRows` authored; store↔corpus equivalence sweep. Corpus now *depends on* the loader. 4 mutations caught. **Rev 7 gains item 14** (§6.6 has no case for "known kind, malformed body") |
| 2026-07-26 | **Phase 4 done (P1, P2 scaffolding, D-3, D17)** | **266** (245 + 21) | P1 through the real store at every flush boundary (fold *and* classify levels); P2's predicate + `LiveOverlay` parameterization, swept at every truncation with the empty live set, with seven tests of the predicate itself; `Registry/tags.json` + `RegistryTests` closing **ADR-001 D-3** (and retiring `CorpusFileTests`' duplicate registry); **D17** widened `contextSizeExceeded` with `dev/` provably byte-identical. 6 mutations caught. Four stale `try` warnings cleaned up |
| 2026-07-26 | **Phase 3 done (snapshots + cold open)** | **239** (218 + 21) | `Snapshot` coding + the four-condition discard policy + `foldedState(of:)` as a composition above the seam. P3 through the **codec** (all fixtures — the sweep that reaches diagnostics) and through the **store** (replayable, real SQLite). **Cold open: 10,004 events → 3 rows replayed, ~28 ms**, measured on the resume path via a counting wrapper. 4 mutations caught. Suite 0.18 s → 0.58 s, all of it appending |

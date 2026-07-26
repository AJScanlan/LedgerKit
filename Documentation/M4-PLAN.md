# M4 Implementation Plan — SQLite store, snapshots, index

**Status:** Planned · opened 2026-07-26 at the M3 boundary.
**Companion to:** [ROADMAP.md](./ROADMAP.md) (M4 section) · [SPEC.md](./SPEC.md) §9, §6.6, §6.3, §10.6 · [ADR-003](./ADR/ADR-003-persistence-dependency.md) (ratifies here) · [ADR-001](./ADR/ADR-001-event-encoding.md) (D-1/D-2/D-3 close here)
**Baseline:** M0–M3 done and audited, SPEC **rev 6 ratified**, **196 tests green**
(175 `LedgerKit` + 21 `LedgerKitTestSupport`), both packages warning-free.
**Spec work:** **rev 7 drafts early in this milestone and ratifies at the M4
boundary.** Its full inventory is §6 of this plan. One item is wire-affecting
(D17) and needs approval before Phase 4 implements it.

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

### D16 — Schema-version placement: decide at the Phase 1 gate *(ADR-001 D-2)*
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

- [ ] **Understudy rename (D14):** directory `LedgerKitTestSupport/` →
      `Understudy/`; package name, product, module, test-target imports; Xcode
      scheme; workspace file reference; CLAUDE.md commands + collision notes;
      ROADMAP living references. Historical docs untouched.
- [ ] Internal-ize `Message.init`, `Conversation.init`, `QuarantinedEvent.init`,
      `ConversationSummary.init` (D13). Playground/tests unaffected
      (`@testable`).
- [ ] `Content` → `MessageContent`, everywhere including doc comments.
- [ ] `MessageState.failed(partial:error:recoverability:)` labels.
- [ ] `GenerationError: CustomStringConvertible` (prose non-contractual, say so
      in the doc comment; ADR-001's sentinel-string rule already covers the
      `unrecognized` descriptions it will interpolate).
- [ ] `PersistenceConfiguration` → struct with `.sqlite(url:)` / `.inMemory`
      factories over internal storage; `ScriptExhaustion` gets the same
      treatment in Understudy.
- [ ] Suites green in both packages under the new names; count unchanged.

**Exit:** zero public memberwise inits on derived state; `import Understudy`
compiles; 196 green.
**Review gate:** read the whole diff as an API reviewer — this is the last
cheap look at the pre-1.0 surface before M4/M5 freeze it in practice.

---

### Phase 1 — GRDB wiring: schema + verbs

**Goal:** ADR-003 stops being a decision document and becomes a conformance.

- [ ] Add GRDB, pinned (first external dependency — record the version and the
      supply-chain note from ADR-003 in the commit message).
- [ ] **DDL:** `events` (`conversation_id`, `sequence`) UNIQUE, blob column,
      version column per **D16 (decide at this gate)**; `snapshots`;
      `conversations`.
- [ ] **`DatabaseQueue` vs `DatabasePool`:** recommendation — `.sqlite` maps to
      a `DatabasePool` (WAL, the production shape; M7's concurrent projection
      reads want it) and `.inMemory` maps to a `DatabaseQueue` (in-memory pools
      don't exist), both behind `any DatabaseWriter`, which is why ADR-003
      called this "not an API decision." Confirm at the gate.
- [ ] `append(_:to:)`: one transaction; **sequence assigned inside the write**,
      contiguous from 1; index maintenance on non-delta kinds derived from the
      payloads (Persistence.swift doc contract); whole-batch rejection on a
      record whose `conversationID` mismatches; returns assembled
      `[LedgerEvent]`; empty batch is a no-op returning `[]`.
- [ ] Debug-assert appended timestamps are born canonical
      (`WireDate.canonical` fixed point) — the corpus's
      `timestampsAreCanonical` is the cross-check (M3 handoff #3).
- [ ] File protection `.completeUntilFirstUserAuthentication` at database
      creation (§9). Applied, not yet configurable (guardrail 5).
- [ ] `deleteConversation`: transactional across all three tables.
- [ ] `conversationSummaries()`: ordered `lastEventAt` descending, one read.
- [ ] **`WireJSON` extracted** (D15); the store encodes through it and nothing
      else; the existing literal-bytes test moves onto it.
- [ ] Tests (in-memory): append/read round-trip value-identity; sequence
      contiguity across batches; index rules (created seeds the row,
      `titleChanged` updates it, delta flushes *don't touch it*, `lastEventAt`
      stamps on non-delta appends); delete removes all three tables' rows.

**Exit:** six verbs implemented and tested against in-memory GRDB.
**Review gate:** DDL review with Alexander; **D16 decided and recorded** (here
+ ADR-001); ADR-003 status flips to Accepted once the conformance passes.

---

### Phase 2 — Two-stage loader + corpus integration

**Goal:** §6.6's input corollary implemented by production code, and the two
corpus gaps M3 deliberately left (`raw` rows; `rich`/`hostile` on disk) close.

- [ ] `events(in:from:)`: **envelope first, payload second**. Row 1 →
      `.undecodable(sequence:eventID: nil, .envelope)`; row 2 →
      `.undecodable(sequence:eventID:, .payloadKind(tag))` with the envelope's
      identity recovered and the tag where legible. Never throws per-row, never
      drops a row, passes gaps through untouched (the fold diagnoses them).
- [ ] **`CorpusFile` `raw` row form implemented** (M3 handoff #1) — stops
      throwing; produces the same `LoadedEvent`s the production loader emits.
      The decode boundary now exists in exactly one place; the corpus consumes
      it rather than reimplementing it (the drift D5 refused to freeze).
- [ ] **`wire/` gains row-1 and row-2 fixtures** — bytes this version cannot
      write: a corrupt-envelope row, an unknown-payload-kind row. Assert the
      §6.6 diagnostic-identity rule from disk: the row-2 diagnostic carries the
      `EventID`.
- [ ] **`rich` and `hostile` land on disk** via `raw` rows — excluded at M3
      *because* they contain `LoadedEvent.undecodable`; that reason has now
      expired by construction (M3 handoff #2).
- [ ] End-to-end equivalence: every corpus file written through the store then
      loaded folds to a `FoldedState` identical to the in-memory fixture's.

**Exit:** loader is the only decode site; corpus sweeps run against
store-written bytes.
**Review gate:** walk the row-2 path end to end — this is the
forward-compatibility diagnostic a developer will actually read in 2027;
its quality is the point of two-stage decode.

---

### Phase 3 — Snapshots + cold open

**Goal:** the §9 fast path, provably equivalent to replay (P3 is the law here).

- [ ] `Snapshot` payload = `WireJSON`-encoded `FoldedState` (synthesized
      `Codable` — disposable by design; the *version fields* are the contract).
      `reducerVersion` / `schemaVersion` constants live beside the reducer.
- [ ] **Discard-on-mismatch without decoding** (version fields ride outside the
      payload). A payload that fails to decode despite matching versions is
      *treated as* a mismatch — discarded, logged, never fatal, never migrated.
- [ ] Resume path: `latestSnapshot` → decode → `fold(resuming:after:with:)`
      over the suffix read. One reduction path; the primitive already exists.
- [ ] **P3 against the real store:** snapshot at every split of every corpus
      fixture, resume equals full replay **including diagnostics** — the
      in-memory sweep re-run through persistence.
- [ ] **Cold-open criterion:** build a synthetic 10k-event log; assert the
      resumed fold **replays exactly the post-snapshot suffix** (row count, a
      deterministic assertion), and record — not assert — the wall-time.
- [ ] Corrupt-snapshot fixtures: truncated payload, wrong versions, valid
      payload/stale sequence.

**Exit:** cold open ≤ one generation's suffix, by construction and by test.
**Review gate:** snapshot policy read against §9 line by line (best-effort,
diagnostics persisted, `.open` stored open).

---

### Phase 4 — Property tests + rev 7 implementation

**Goal:** the §10.6 obligations M4 owns, plus the one wire change rev 7 approves.

- [ ] **P1 (fold/tail equivalence):** `reduce(persisted ++ unflushedTail) ==
      reduce(logAfterFlush)` — exhaustive over every fixture × every split
      (D18). This is the shape the M5 store actor will live by
      (`append` returns the tail so the actor folds forward); prove it now.
- [ ] **P2 scaffolding only:** parameterize the projection-equivalence harness
      over a live set, test with the empty set (≡ fold identity). The overlay
      itself is M7's; the harness existing is what "scaffolding" means.
- [ ] **D17, if rev 7 approves:** widen `contextSizeExceeded`; optional named
      keys; `RecoverabilityMapping` untouched; ADR-001 R-2 registry gains
      `contextSize`/`tokenCount`; `LEDGERKIT_RECORD=1` regenerates `dev/`; a
      `wire/` fixture pins the field-less old form forever.
- [ ] **Registry enforcement (ADR-001 D-3):** a test over a checked-in
      `tags.json` mirroring R-3's inventory — payload kinds, outcome kinds,
      error kinds, raw-value enums, R-2 field keys, and the reserved table.
      Fails loudly on reuse, rename, or silent removal. (Scoped small: a
      manifest test, not a code generator.)
- [ ] Mutation-test the suites whose failure mode is subtle (the M3 practice,
      now standing policy): break sequence assignment (skip a number), break
      snapshot version checking (accept mismatched), break the loader's
      envelope-first order (drop identity), break index maintenance (update on
      deltas) — each must be caught, then reverted.

**Exit:** P1/P3 green corpus-wide against the store; registry test green.
**Review gate:** rev 7 draft review against §6 below — the drafting session
should start from that list, not from memory.

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
11. **D17** — `contextSizeExceeded(contextSize: Int?, tokenCount: Int?)`: the
    wire item; approve or record deliberate omission (§3 D17 has the analysis).
12. **§10.1** — the provisional name resolves: **Understudy**. Strike the stale
    OQ3 ⚠️ in the same section.
13. **Footnote** — `Refusal.explanation` is on-demand generation
    (`Response<String>`), not stored data: rev 6's no-projection call confirmed.

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
| P1 exhaustive over corpus | Phase 4 | ☐ |
| P3 against real store, diagnostics included | Phase 3 | ☐ |
| Cold-open ≤ one generation suffix (rows replayed) | Phase 3 | ☐ |
| Index maintained on non-delta appends only | Phase 1 | ☐ |
| Timestamps born canonical at the store | Phase 1 + corpus | ☐ |
| Registry manifest (ADR-001 D-3) | Phase 4 | ☐ |
| No public memberwise inits on derived state | Phase 0 | ☐ |
| Understudy renamed, both packages green | Phase 0 | ☐ |

## 9. Decision log

| # | Decision | Status |
|---|---|---|
| D13 | Contract hygiene precedes store work (audit pass, Phase 0) | **Accepted** 2026-07-26 |
| D14 | `LedgerKitTestSupport` → `Understudy`; one name everywhere | **Accepted** 2026-07-26 (Alexander) |
| D15 | One production `WireJSON` encoder; corpus files stay pretty; bytes pinned against `WireJSON` | **Accepted** · applies Phase 1 |
| D16 | Schema-version placement (column-only vs column+blob) | **Open** — decide at Phase 1 gate |
| D17 | `contextSizeExceeded` optional payload | **Pending rev 7 approval** — implement Phase 4 |
| D18 | P1 splits exhaustive, D6 generator discipline carries forward | **Accepted** · applies Phase 4 |

## 10. Status log

| Date | Phase | Tests | Note |
|---|---|---|---|
| 2026-07-26 | Plan drafted | 196 | Sourced from the M3 boundary audit; D13–D15/D18 accepted, D16 open, D17 pending rev 7 |

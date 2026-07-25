# M3 Implementation Plan — Test corpus + `ScriptedLanguageModel`

**Status:** Phase 0 not started
**Companion to:** [ROADMAP.md](./ROADMAP.md) (M3 section) · [SPEC.md](./SPEC.md) §10, §6.6, §6.1, §6.3
**Baseline:** M0–M2 done and audited, SPEC rev 5 ratified, 143 tests green (LedgerKit package).

> **How to use this document.** This plan persists across sessions, agents, and
> compactions — it is the working memory for M3. Update the checkboxes and the
> per-phase status lines as work lands; record anything that changes a decision
> in the Decision log (D-numbers below); do not silently deviate. Each phase ends
> with a **review gate**: stop, run both packages' suites, and review with
> Alexander before starting the next phase. Spec amendments, if any become
> necessary, open **rev 6** (rev 5 is ratified) and require approval first.

---

## 1. What M3 is, in one paragraph

M3 turns the reducer's hand-written test suite into the exhaustive, hostile,
version-frozen corpus the spec calls the product differentiation (§10), and
ships `ScriptedLanguageModel` — a deterministic Foundation Models test double —
as the first real content of `LedgerKitTestSupport`. Everything here is
beta-independent except the OQ3 conformance surface, which is deliberately
stubbed behind an internal seam and bound to the real protocol at M6. M3 must
land before M4 because crash-point fuzzing hardens the fold *before* the
snapshot fast-path is built on top of it.

**Roadmap exit criteria (the contract for "done"):**
- I1–I7 provable via green suites.
- Crash-fuzz green: every fixture × every prefix × interior-gap variants — valid
  state, correct `.interrupted` synthesis (I5), no traps (I2).
- Hostile fixtures assert **exact** `diagnostics` residue, §6.6 row-for-row,
  plus the non-rules (tolerant terminal, role adjacency, duplicate `EventID`,
  gaps, cascade).
- Version-frozen corpus scaffolding exists (freezing happens at release, M9).
- `ScriptedLanguageModel` scripting engine complete and tested; OQ3 seam
  documented.

---

## 2. Decisions (made up front; revisit only at a review gate)

### D1 — Corpus lives as a registry in `LedgerKitTests`; every sweep iterates it
One catalog (`Corpus.all`: name → fixture) replaces the current pattern of each
suite privately building its own logs. A fixture bundles the `Log` plus its
expectations (expected folded literals where pinned, expected residue). All
sweep suites — truncation, interior-gap, P3 splits, determinism repeats,
classify-level I5 — iterate `Corpus.all`, so adding a fixture automatically
buys it every sweep. Fold-level sweeps need `@testable` internals (`fold`,
`FoldedState`), so the corpus stays in `LedgerKitTests`, reusing and extending
`ReducerFixtures.swift` (`Log`, `Fix`) rather than rebuilding it (CLAUDE.md).

### D2 — No third-party test dependencies; hand-rolled canonical dump
Golden-log snapshot testing uses our own small, deterministic, human-readable
textual dump of reduced state (`ConversationDump`, ~100 lines: messages in
sequence order, states, path, residue). Rationale: the frozen corpus commits to
its expected-output format *forever* (§10.2), and a third-party dump format
(swift-custom-dump / SnapshotTesting) can legitimately change its rendering
across library versions, which would churn frozen files for zero information.
Our dump is versioned with the corpus and doubles as living documentation. The
door stays open to adopt SnapshotTesting later for *dev-time* convenience; the
frozen format is ours either way.

### D3 — `LedgerKitTestSupport` does **not** depend on `LedgerKit`
Reverses the assumption in `LedgerKitTestSupport/Package.swift`'s platforms
comment (written at M0; treat like a stale roadmap note — fix the comment).
Two reasons, one hard: (a) SPM forbids package dependency cycles, and the
direction we will actually need at M5/M6 is `LedgerKit`'s *test target*
importing `ScriptedLanguageModel` for driver/store tests — that is only
possible if TestSupport stays LedgerKit-free; (b) the spec's positioning is
"useful to *any* FM app" (§10.1 "the gateway drug") — a double that drags in
LedgerKit types undermines its own pitch. The double speaks Apple-side
vocabulary only (or our internal mirror of it, pre-beta).

### D4 — OQ3 seam: scripting engine now, conformance adapter at M6
The toolchain is Xcode 26.6 — the iOS 27 SDK's `LanguageModel` /
`LanguageModelExecutor` protocols are not even compilable here, so conformance
is *structurally* impossible until M6 bumps the platform floor. Public WWDC26
coverage pins the rough shape (model = capabilities + executor configuration;
executor = `init(configuration:)` + a respond-into-channel method; channel
phases: metadata → usage → text deltas via `appendText`; optional `prewarm`).
We mirror that shape as an **internal** protocol pair so the M6 adapter is a
thin forwarding layer, but nothing public commits to it. Public API = the
script vocabulary + the engine's observable output; both are beta-independent.

### D5 — On-disk corpus schema mirrors the events table: `(sequence, raw JSON)`
Fixture files store rows exactly as the store would: sequence outside the blob,
blob in ADR-001 tagged-JSON wire form. Gaps are missing sequence numbers —
representable for free. **Scope limit, owned:** §6.6 rows 1–2 are *loader*
behavior (envelope-first two-stage decode), and the loader is M4; the M3 corpus
runner decodes rows with the existing `LedgerEvent.Record` `Codable` and so can
exercise everything *except* raw-undecodable rows — including row 3, whose
tolerant terminals decode **successfully** by design. Row-1/2 coverage stays at
the `LoadedEvent` level in-code (already representable via `Log.undecodable`);
the on-disk schema reserves a `"raw"` row form now and M4's loader tests
exercise it. This is not deferral by laziness: freezing row-1/2 fixtures before
the production loader exists would freeze against a test-side reimplementation,
which is the drift ADR-003 rule 2 exists to prevent.

### D6 — Fuzz generators never violate the ordering precondition
§6.6 (rev 5): reduction *requires* ascending sequence and does not verify it;
only deltas and tool records are non-idempotent under replay. Truncation and
gap generators therefore only ever *remove* rows — never reorder, never
duplicate. `FolderOrderingTests` already pins the precondition's behavior; the
generators inherit its discipline.

---

## 3. Phases

Phases 1–2 are the critical path (they gate M4). Phase 4 is independent of
1–3 and can interleave if a change of pace is wanted.

---

### Phase 0 — Shared harness + coverage audit *(small; no new semantics)*

**Goal:** one place for predicates and fixtures; an honest gap list so Phases
1–2 add exactly what's missing and no duplicate coverage.

- [ ] Promote `invariantProblems(in: FoldedState)` out of `FolderTests.swift`
      (currently `private`) into the shared harness (e.g.
      `Tests/LedgerKitTests/InvariantChecks.swift`, internal — beware the
      CLAUDE.md note about same-named private types colliding).
- [ ] Add the classify-level predicate sibling
      (`invariantProblems(in: Conversation)`): no `.streaming` ever (fold/classify
      can't produce it), user messages always `.complete`, every `.interrupted`
      corresponds to an open generation, `Recoverability` present on exactly the
      `.failed` cases, diagnostics in sequence order.
- [ ] Introduce the `Corpus` registry type (name → fixture + expectations);
      migrate `richLog` / `hostileLog` into it as the first two entries.
- [ ] **Audit:** table of §6.6 rows 1–12 + every non-rule + every rev-5 roadmap
      addition ↔ existing test (file:line) ↔ gap. Record it in §5 below.
      Known already-covered examples: row 3's four shapes at the `Outcome`
      decode level (`WireFormatTests` 261–318), most rows via `hostileLog`,
      P3 down payment, ordering non-rule (`FolderOrderingTests`).
- [ ] Baseline: `swift test --package-path LedgerKit` green before and after.

**Exit:** suites green with zero coverage lost; audit table filled in.
**Review gate:** agree the gap list *is* the Phase 1 work list.

---

### Phase 1 — Fixture corpus: golden + hostile, row-for-row *(the center of gravity)*

**Goal:** §6.6 as executable fixtures with **exact residue** assertions —
every diagnostic's case *and* sequence *and* (non-row-1) populated `eventID`.

Golden fixtures (§10.2 — each also gets a pinned-literal expectation, the
cross-process I1 defense from `determinismGolden`):

- [ ] Ordinary turn; multi-turn linear conversation.
- [ ] Edit-as-branch (incl. **root-message edit** — the rev-2 regression made
      a fixture); regenerate-as-sibling; branch switch; interrupted partial
      surviving as its own branch (the DoD-1 shape).
- [ ] Each terminal kind: completed (with `StopInfo`), failed (each
      `GenerationError` family), cancelled, and open→`.interrupted`.
- [ ] Instructions / title set, cleared (`nil`), last-write-wins.
- [ ] Tool records within bounds (`.metadataOnly`-shaped and `.full`-shaped).

Hostile fixtures — one per §6.6 row where the audit found gaps, each asserting
exact `diagnostics` residue and untouched targets (I2):

- [ ] Rows 4–12 individually (much exists inside `hostileLog`; split into
      per-row fixtures so failures name the row, keep `hostileLog` as the
      integration-style composite).
- [ ] **`MessageID` allocate-once at all three sites** (rows 6, 8, 11) —
      asserted as *one rule at three sites*: same reason case
      (`.messageIDAlreadyUsed`), three introduction events, including the
      nastiest shape: `userMessageAppended` reusing an in-flight assistant
      message's ID (the rev-5 back-door scenario).
- [ ] Cascade fixture: quarantined `generationStarted` orphaning delta + tool
      record + terminal; exact three-diagnostic residue (rows 9, 9, 9 — the
      orphaned terminal is row 9, not 10; rev 5).
- [ ] Row 9 vs row 10 partition: terminal-for-never-started vs second terminal.
- [ ] Mid-log gap fixtures: one contiguous gap = one diagnostic; two gaps = two;
      gap swallowing a terminal ⇒ `.interrupted` (I5 through absence).
- [ ] Non-rules, asserted as **zero residue**: tolerant terminal (fold-level:
      a `generationEnded` carrying `.failed(.unrecognized("undecodable outcome: …"))`
      still terminates the generation); assistant-parent `generationStarted`;
      consecutive user siblings; **duplicate `EventID`** across two rows.
- [ ] Diagnostic identity: a sweep asserting every non-row-1, non-gap
      diagnostic in every corpus fixture carries a populated `eventID`.

**Exit:** every §6.6 row and non-rule maps to a named fixture in §5's table;
suites green.
**Review gate:** read the residue assertions together — they are the spec's
normative table, restated executably; drift here is spec drift.

> *Learn-by-doing option (offered, not imposed):* the cascade fixture or the
> three-site allocate-once family are the densest spec-reasoning pieces —
> good `TODO(human)` candidates with tests pre-written to fail.

---

### Phase 2 — Crash-point fuzzing + sweeps *(the "single highest-value suite")*

**Goal:** the §10.3 suite over the whole corpus.

- [ ] **Suffix truncation sweep:** every corpus fixture × every prefix length —
      fold-level `invariantProblems` empty, no traps, and classify-level
      predicates hold (`Conversation(reducing:)` at every prefix).
- [ ] **I5 sweep:** at every truncation, every started-unterminated generation
      classifies `.interrupted` with partial = concatenation of surviving
      deltas; never `.streaming`; terminals that survived stay terminal.
- [ ] **Interior-gap sweep:** every fixture × every contiguous interior window
      `(start, length)` removed (exhaustive — small-scope enumeration beats
      randomness here; fixture logs are ≤ ~25 rows so O(n³) is trivial).
      Assert: exactly one `sequenceGap` diagnostic per hole (merged with
      adjacent holes correctly), reduction continues, gap-swallowed terminals
      yield `.interrupted`.
- [ ] **Compound sweep:** truncation × single interior gap on the two richest
      fixtures (rich, hostile) — the crash-during-partial-restore shape.
- [ ] **P3 split sweep, corpus-wide:** `fold(resuming: fold(prefix), after:,
      with: suffix) == fold(full)` at every split point of every fixture,
      diagnostics included (generalizes `resumeEqualsReplay`).
- [ ] **I1 repeat + literal goldens:** determinism repeat over the corpus; the
      pinned-literal expectations from Phase 1 are the cross-process half.
- [ ] Runtime guard: keep the whole fuzz suite comfortably under a few seconds
      (it will run on every `swift test` forever; if it creeps, shrink fixture
      count per sweep, never assertion strength).

**Exit:** roadmap's crash-fuzz criterion met in full; suites green.
**Review gate:** review sweep runtimes + any invariant predicate weakened or
special-cased during the phase (there should be none).

---

### Phase 3 — On-disk corpus + version-freeze scaffolding

**Goal:** the §10.2 evolution safety net's machinery, ready for M9 to freeze.

- [ ] Corpus file schema (D5): a fixture document = conversation ID + rows of
      `{sequence, event: <tagged-JSON wire object>}` (+ reserved `raw` form for
      M4); a sidecar expected-state file in the `ConversationDump` format (D2).
      Schema documented in `Tests/LedgerKitTests/Corpus/README.md`.
- [ ] `ConversationDump`: deterministic textual rendering of a reduced
      `Conversation` (sequence-ordered, no dictionary iteration anywhere —
      the I1 discipline applies to test infrastructure too).
- [ ] Writer ("record mode", env-flag- or test-gated): serializes a `Corpus`
      fixture to the file pair. Used to (re)generate the dev corpus; the frozen
      corpus is never regenerated — that is its entire point.
- [ ] Runner: loads every fixture file from the test bundle (`Bundle.module`
      resources), decodes rows via `LedgerEvent.Record`, reduces, compares dump
      output. Wire-level row-3 fixtures (all four shapes as raw JSON *within a
      decodable record*) live here — they complete the `WireFormatTests`
      coverage end-to-end through the fold.
- [ ] Round-trip property: decode(fixture) → encode → decode is identity for
      every dev-corpus file (encoder canonicalization check; note the WireDate
      millisecond rule — fixture timestamps must be born canonical).
- [ ] Directory layout: `Corpus/dev/` (regenerable, tracks HEAD) and
      `Corpus/frozen/` (empty until 0.1.0; CI treats any diff under `frozen/`
      as failure). Document the M9 freeze procedure in the README.

**Exit:** dev corpus generated from the Phase 1 registry; runner green;
freeze procedure documented.
**Review gate:** review the schema and dump format as if they were public API —
frozen files outlive everything else in this repo.

---

### Phase 4 — `ScriptedLanguageModel` (`LedgerKitTestSupport`)

**Goal:** the deterministic double, engine-complete, conformance-deferred (D4).

- [ ] Package topology per D3: no LedgerKit dependency; fix the stale
      `Package.swift` comment.
- [ ] **Script vocabulary** (public, beta-independent): a `Script` is a
      sequence of turns; a turn is steps —
      `.emit(String)` (text delta), `.wait(Duration)`, `.pause(Gate)` (an async
      gate the test opens — the deterministic alternative to clock waits, and
      what M5's cancellation chaos will steer with), `.reportUsage(…)`,
      `.reportMetadata(resolvedModelID: …)`, `.throwError(any Error)`,
      `.complete`. Multi-turn: one script turn consumed per request;
      exhaustion policy explicit (default: fail loudly).
- [ ] **Engine:** consumes a turn, emits into an internal channel abstraction
      mirroring the known beta shape (metadata → usage → deltas; D4).
      Cooperative cancellation checked at every step boundary (throws
      `CancellationError` — ⚠️ verify against beta at M6). Clock injected as
      stdlib `any Clock<Duration>` (default `ContinuousClock`), so `.wait`
      is testable without wall-clock and usable in previews with it.
- [ ] **Cumulative-snapshot view:** helper that accumulates deltas into the
      cumulative stream shape §7.3 says sessions vend — this is what the M6
      driver-facing tests will consume, and scripting it now keeps OQ4 honest.
- [ ] **OQ3 seam:** internal `protocol` pair mirroring model/executor; a doc
      comment mapping each internal requirement to the observed beta surface,
      so M6's binding is a checklist, not archaeology.
- [ ] Test suite in `LedgerKitTestSupportTests`: script playback determinism
      (two runs, identical emission sequences), cancellation at every step
      boundary via `.pause`, exhaustion policy, multi-turn.
- [ ] Doc comment positioning: the "gateway drug" framing — usable by any FM
      app; zero network, zero Apple Intelligence eligibility, CI-safe.

**Exit:** `swift test --package-path LedgerKitTestSupport` green; engine
deterministic; OQ3 checklist written.
**Review gate:** review the public script vocabulary — it is TestSupport's API
surface and should survive the M6 binding unchanged.

---

### Phase 5 — Wrap-up

- [ ] Fill §5 traceability table completely (row ↔ fixture ↔ suite).
- [ ] ROADMAP.md: mark M3 done with the same audit-note style as M1/M2
      (deviations recorded: D3's topology reversal, D5's row-1/2 → M4 handoff).
- [ ] CLAUDE.md status paragraph: M3 done, test counts, next = M4 (+ the
      loader's inherited obligations: raw-row corpus form, row-1/2 fixtures).
- [ ] Confirm no spec amendments accrued; if any did, they are a rev-6 proposal
      *first* (approval before implementation).
- [ ] Full suites green in both packages; do not mark done otherwise.

---

## 4. Explicit handoffs to M4 (recorded so they aren't lost)

1. **Raw-row corpus form** (`"raw"` rows, D5): exercised when the two-stage
   envelope-first loader exists; add frozen row-1/row-2 fixtures then.
2. **Loader ↔ corpus integration:** M4's loader tests should consume the same
   corpus files, producing `LoadedEvent`s the existing sweeps already accept.
3. **P1 timestamp canonicalization:** corpus fixtures are born with canonical
   (millisecond) timestamps; M4's store stamping must match (roadmap ⚠️).

## 5. Coverage traceability (filled during Phase 0, maintained after)

| §6.6 row / non-rule / invariant | Existing coverage (file:line) | M3 fixture / suite | Status |
|---|---|---|---|
| *(fill at Phase 0 audit)* | | | |

## 6. Decision log

| # | Decision | Status |
|---|---|---|
| D1 | Corpus registry in `LedgerKitTests`; sweeps iterate it | Proposed |
| D2 | No third-party test deps; own `ConversationDump` format | Proposed |
| D3 | TestSupport does not depend on LedgerKit (topology one-way door) | Proposed |
| D4 | OQ3: engine now, internal seam, M6 adapter | Proposed (matches roadmap) |
| D5 | On-disk schema `(sequence, raw JSON)`; rows 1–2 defer to M4 | Proposed |
| D6 | Fuzz generators remove-only; never reorder/duplicate | Proposed (per §6.6 rev 5) |

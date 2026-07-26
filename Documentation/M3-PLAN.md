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

### D7 — The classify-level predicate takes the `FoldedState` too *(Phase 0)*
Planned as a standalone `invariantProblems(in: Conversation)`; landed as
`invariantProblems(in:foldedFrom:)`. Forced, then preferred:

- **Forced:** `MessageTree` keeps its `nodes` dictionary `private`, which
  `@testable` cannot reach (private is file-scoped; `@testable` only elevates
  `internal`). The only other enumeration is a walk from `rootChildren` — which
  is structurally unable to notice a node that fell *out* of the tree, the exact
  failure the M2 audit chose a dictionary over a tree walk to keep detectable.
  Adding an internal `allNodes` to production code purely for tests was the
  alternative, and it would have handed the sweeps an unordered dictionary — the
  I1 hazard CLAUDE.md warns about — for less checking power.
- **Preferred:** it asserts the rev-5 three-name correspondence directly
  (`.complete`/`.failed`/`.cancelled` unchanged, `.open ⇒ .interrupted`,
  `.streaming` unreachable), so I5's finalization is verified against every log a
  sweep can build rather than the handful with hand-written expectations. It also
  pins that classification touches *states only* — every other field is
  pass-through, which is what keeps I1's second half honest.

### D8 — The corpus holds logs worth *sweeping*; unit tests name *rules* *(Phase 1)*
Phase 1 originally said "split §6.6 rows 4–12 into per-row fixtures." The Phase 0
audit killed that: rows 4, 5, 7, 8, 10, 11 and 12 already have focused unit tests
in `FolderTests.swift` asserting exact reasons, so per-row corpus fixtures would
have been duplication whose only new coverage was sweeping three-row logs that
explore no state space `hostile` doesn't already cover.

The operating principle instead: **a fixture earns a place in `Corpus` if
mutating it explores something new; a rule earns a unit test if nothing names
it.** Consequences, both acted on in Phase 1:

- The corpus gained *golden* fixtures, which it had none of — every sweep had
  been starting from an already-damaged log, so a reducer bug that only
  manifests on clean input (the likeliest kind, since clean input is what ships)
  had nothing to fail.
- The five audit gaps became focused tests in `QuarantineRuleTests.swift`, named
  after the rule rather than the row, because three of them are *relationships*
  between rules (one rule at three sites; rows 9 vs 10; what must not
  quarantine) that no per-row fixture could have expressed.

One thing the per-row plan would have bought is not lost: residue is asserted in
both dimensions (sequence *and* reason) everywhere the corpus reaches, via
`ExpectedDiagnostic`. The older unit tests still assert `reasons` only; upgrading
them is a low-value mechanical sweep, deliberately not done — their logs are 2–4
rows, so the row being blamed is unambiguous.

### D9 — A sweep's oracle must be simpler than the fold, or it isn't one *(Phase 2)*
A property test whose expectation is computed by the code under test proves
nothing. Phase 2's two oracles are therefore both *strictly simpler* than the
reducer — one walks a sequence run counting contiguous holes, the other
concatenates delta text — and neither reimplements routing, tree-building or
quarantine. Two consequences, both deliberate:

- **The I5 oracle runs on golden fixtures only.** To predict partial content on a
  hostile log it would have to know which deltas were quarantined, which means
  replicating §6.6 — at which point it *is* the fold and asserts a tautology.
  Hostile fixtures are covered by the structural predicates and by monotonicity
  instead, which need no oracle.
- **Where no simple oracle exists, assert a *relation* rather than a value.**
  Monotonicity compares two folds to each other rather than to a predicted
  answer, which is why it applies to every fixture including the hostile ones.
  It is also the stronger property: it constrains the whole reduction history,
  not one endpoint.

Corollary adopted for the rest of M3: **mutation-test any sweep whose failure
mode is subtle.** Three breakages were injected and reverted in Phase 2; the
monotonicity property was verified to fail before it was trusted to pass.

### D10 — Frozen expectations render `FoldedState`, never `Conversation` *(Phase 3)*
The plan said the dump would render "a reduced `Conversation`." That is wrong,
and the reason generalizes: **freeze only what the log alone determines.**

Classification takes a `RecoverabilityMapping` as a second input, and §8
explicitly *wants* mapping fixes to land and retroactively upgrade affordances
on historical failures. A frozen corpus of classified state would therefore turn
every legitimate §8 improvement into a wall of failing fixtures — creating
pressure to "just re-record," which is exactly how a frozen corpus stops meaning
anything. Folded state is what I1's first half promises is stable forever, so it
is what the format commits to. Nothing is lost: `.open` pins the same fact
`.interrupted` would, and I5's synthesis is covered by the in-memory sweeps.

**Corollary, same phase:** the dump renders via explicit exhaustive switches over
*case names* — never `description`, never `String(describing:)`. ADR-001 declares
diagnostic prose non-contractual and free to reword; reflection output is a
compiler implementation detail. A format frozen forever can depend on neither,
and the exhaustive switch additionally forces a compiler error when the §6.6
inventory grows, so a new condition cannot reach a frozen fixture without
someone deciding how it appears.

### D11 — Conform to Apple's real protocols now, availability-gated *(supersedes D4)*
D4 said "stub behind an internal protocol at M3, bind at M6," inherited from the
roadmap's rule that all beta risk lives in M6. That rule was written when the
conformance surface was unknown. It is now **readable in the installed SDK**, so
the stub would be a deliberate imitation of an API the compiler can already
check — a vocabulary validated against a guess, plus reconciliation work at M6,
plus a double no real consumer can use until then.

Split by availability instead: **the vocabulary and engine are 26+** (they run
and are tested today); **the conformance is `@available(macOS 27)`** (it compiles
today, runs when 27 ships or on a 27 VM). The roadmap's principle is honoured in
substance — the conformance touches ~5 symbols, where M6's driver touches
transcript seeding, streaming, tool observation, usage and error normalization.
The blast radius is not comparable.

Owned cost: conformance tests cannot execute on this machine (macOS 26) and are
gated with `.enabled(if:)`. Compile-checking is still strictly more than the stub
would have given.

### D12 — `Script.Step` is a struct with static factories, not an enum *(Phase 4)*
Forced, then preferred. **Forced:** `appendText`'s `tokenCount` has no default,
and Swift enum cases cannot carry default parameter values — an enum would mean
either two cases or a wart at every call site. **Preferred:** steps are written
by consumers and never *read* by them; nobody switches over a script step. So an
enum buys no exhaustiveness anyone uses, while costing source stability every
time a step is added. Apple reached the same conclusion for
`LanguageModelExecutorGenerationChannel.Response.Action`, which is precisely this
shape.

The general rule, worth keeping: **enums for values consumers destructure,
structs-with-factories for instructions consumers construct.**

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

### Phase 0 — Shared harness + coverage audit ✅ *done 2026-07-25 (143 → 151 tests)*

**Goal:** one place for predicates and fixtures; an honest gap list so Phases
1–2 add exactly what's missing and no duplicate coverage.

- [x] Promote `invariantProblems(in: FoldedState)` out of `FolderTests.swift`
      into `Tests/LedgerKitTests/InvariantChecks.swift` (internal). **Widened
      while moving** with checks that were universal all along: role-scoped
      fields (a user message carrying `generationID`/`model`/`stopInfo`/tool
      records, or not `.complete`), `stopInfo` only on `.complete` (§7.7),
      `.open` carrying no `terminalTimestamp` (I5), and §6.6's **diagnostic
      identity** rule — stated one-directionally, because "row 1 ⇒ nil eventID"
      is the *loader's* contract while "gap ⇒ nil" is the fold's.
- [x] Classify-level predicate — see **D7**, it became a *bridging* predicate.
- [x] `Corpus` registry (`Corpus.swift`), with `rich` and `hostile` migrated in
      and their residue pinned as data.
- [x] **Audit** recorded in §5.
- [x] Suites green before (143) and after (151).

**Landed beyond the checklist, deliberately:**

- **Three files, not one.** `Corpus.swift` (fixtures + pinned data),
  `CorpusTests.swift` (each fixture's own expectations), `CorpusSweepTests.swift`
  (generic predicates over `Corpus.all`). Phase 1 grows the middle file and
  Phase 2 the last; `FolderTests.swift` (896 → 671 lines) goes back to being
  unit tests of the fold.
- **Residue assertions are now exact and ordered, in both dimensions.**
  `hostileRowCoverage` asserted `Set.contains` per row, which passes even when a
  diagnostic blames the wrong sequence, duplicates, or brings friends. Replaced
  by `ExpectedDiagnostic(sequence, reason)` lists on the fixture. This is a
  genuine coverage upgrade, not a move — and the hand-traced hostile expectation
  matched the reducer on first run.
- **Meta-tests for the predicates** (`InvariantCheckTests.swift`, 5 tests).
  Phase 2's entire value rests on `invariantProblems` being able to *fail*; a
  vacuous predicate would make the fuzz suite an expensive `#expect(true)` and
  nothing else in the package would notice. Each check is fed a hand-built
  violating state — hand-built on purpose, since several conditions are ones the
  fold is *believed* incapable of producing, and folding a log to test them would
  only re-test that belief.

**Exit:** ✅ suites green, zero coverage lost, audit table filled.
**Review gate:** agree the §5 gap list *is* the Phase 1 work list.

---

### Phase 1 — Fixture corpus: golden + hostile, row-for-row *(the center of gravity)*

**Goal:** §6.6 as executable fixtures with **exact residue** assertions —
every diagnostic's case *and* sequence *and* (non-row-1) populated `eventID`.

**Reshaped by the Phase 0 audit — see D8.** Per-row hostile fixtures were
dropped as duplication; the work is the five real gaps plus the golden fixtures
the sweeps had no access to.

Golden fixtures added to `Corpus` (the audit's most surprising finding: *both*
existing fixtures were hostile, so no sweep had ever seen a healthy log):

- [x] `ordinaryTurn`, `multiTurn` (two turns + a trailing user message with no
      generation — the state between `send` and the first delta).
- [x] `editBranch`, `rootEdit` (the rev-2 regression, made a fixture),
      `regenerateAfterInterruption` (**DoD-1's shape**: interrupted partial
      survives as a sibling branch, reachable via `siblings(of:)`).
- [x] `toolsAndMetadata` (instructions, title set→cleared, in-bounds tool
      records in both `.metadataOnly` and `.full` shapes), `empty`.
- [x] Pinned-literal orderings for the goldens (`goldenOrderings`), the
      cross-process I1 defense.

Gap-closing tests (`QuarantineRuleTests.swift`, three suites):

- [x] **I7 allocate-once as one rule at three sites** — same reason case
      asserted across all three introduction events, plus permanence (an ID
      stays used after its generation terminated).
- [x] **Row 9 vs row 10 partition** in one log, plus first-terminal-wins
      (§7.5's benign cancel/completion race).
- [x] **Duplicate `EventID`** reduces with zero residue; both facts apply.
- [x] **Gap swallowing a terminal** ⇒ `.open` → `.interrupted`, reduction
      continues past the hole (`gapSwallowedTerminal` fixture + assertion).
- [x] **`TODO(human)` #1 — tolerant terminal at the fold** (`NonRuleTests`).
      The audit's most valuable gap: `WireFormatTests` pins the *decoder's*
      half, and nothing asserted what the fold does with the result.
- [x] **`TODO(human)` #2 — the allocate-once back door** (`AllocateOnceTests`).
      Rev 5's motivating scenario: a user append naming an in-flight assistant
      message's ID.

Harness additions: `Log.appendDecoded(_:)` (composes the real decoder with the
real fold — the only honest way to reach row 3), `Log.append(reusingEventID:)`
and `Log.eventID(at:)` (the `EventID` collision non-rule).

**Status:** ✅ **done 2026-07-26 — 160 tests green.** Both handoffs filled
correctly on the first pass. Review found one imprecision (handoff #2's
explanatory comment cited §6.1's `messageEdited` role rule — row 11 — where the
firing rule is row 6's *allocation* check; the values were right) and two
defects in the scaffolding itself, both since removed:

- `firstTerminalWins` duplicated `FolderTests.duplicateTerminal` — a D8
  violation committed while writing D8. Deleted, with a comment at the site
  saying where the coverage lives instead.
- `Corpus.golden` / `Corpus.hostileFixtures` were never referenced. Deleted;
  Phase 2 can reintroduce a filter when a sweep genuinely needs one.

**Follow-up carried into Phase 2:** the `TODO(human)` contract blocks and their
`guard … else { Issue.record }` scaffolding are now dead — both values are
non-nil literals, so the guard cannot fire, and a `TODO` marker in green code
reads as unfinished work. Collapse to plain assertions, keeping the derivation
comments (which are the durable part).

**Exit:** ✅ the two `TODO(human)` branches filled and green.
**Review gate:** read the residue assertions together — they are the spec's
normative table, restated executably; drift here is spec drift.

#### The two learn-by-doing handoffs

Both follow the CLAUDE.md pattern: scaffolding written, the dense spec-reasoning
branch left as `TODO(human)` with a precise contract, and a test that fails with
a legible message until it is filled. Each asks for two values plus one
one-sentence comment explaining *why the rule exists* — the sentence is the part
that does not survive being copied from a failure message.

| # | File | What to derive | Spec |
|---|---|---|---|
| 1 | `QuarantineRuleTests.swift` → `tolerantTerminalTerminatesTheGeneration` | Residue and the terminal `FoldedMessageState` for a `generationEnded` whose outcome kind is from the future; then why quarantining it would forge a crash | §6.6 row 3, §6.1 tolerant-terminal, I5 |
| 2 | `QuarantineRuleTests.swift` → `inFlightAssistantIDCannotBeReused` | Residue (case + sequence, and why not `unknownParent`/`additionalRootMessage`) and the surviving in-flight state | §6.6 row 6, I7, Appendix C bullet 1 |

---

### Phase 2 — Crash-point fuzzing + sweeps ✅ *done 2026-07-26 (160 → 166 tests)*

**Goal:** the §10.3 suite over the whole corpus. All in `CorpusSweepTests.swift`
(`CrashFuzzTests`); enumeration is **exhaustive, not randomised** — fixture logs
are ≤ 22 rows, so every prefix and window fits in milliseconds, and there is no
seed to manage, no flake, and a failure reproduces by re-running.

- [x] **Suffix truncation sweep** (landed Phase 0, both layers, corpus-wide).
- [x] **Truncation monotonicity** — *added beyond the plan, and it is the
      centerpiece:* every prefix must be a state the full reduction genuinely
      passed through. Messages only appear, text only extends, terminals never
      change, diagnostics and sibling order only append. This is the
      crash-recovery guarantee itself rather than a proxy for it — a fold that
      revised an earlier conclusion on later evidence would break this while
      every fixed-point expectation stayed green.
- [x] **I5 exactness sweep** — at every truncation of a *golden* fixture, each
      unterminated generation classifies `.interrupted` with a partial equal to
      the independently-concatenated surviving deltas, and each terminated one
      does not. Restricted to goldens deliberately: on a hostile log the oracle
      would have to replicate the quarantine table to know which deltas counted,
      i.e. become the fold and prove nothing (see D9).
- [x] **Truncating a healthy log cannot manufacture residue** — the property
      that makes the oracle above legitimate, since no quarantine rule consults
      a later row.
- [x] **Interior-gap sweep** — every fixture × every contiguous window removed
      (520 mutations), with an independent oracle counting contiguous holes in
      the surviving sequence run. 437 produce gaps; **393 produce multi-row
      holes**, which is what proves adjacency *merging* is exercised rather than
      merely assumed.
- [x] **Compound sweep** — truncation × interior gap on `rich` and `hostile`
      (3,289 iterations): a log restored with a hole, from a process that then
      died mid-generation.
- [x] **P3 under mutation** — resume-equals-replay at every split of every
      single-row-deleted fixture, extending Phase 0's clean-log P3 sweep to the
      case where a stale checkpoint is likeliest to be resumed from.
- [x] **P3 corpus-wide + I1 repeat + literal goldens** (Phase 0/1).
- [x] **Runtime:** whole package **0.17 s** for 166 tests. No guard needed.

**Non-vacuity guards.** Each sweep tallies its own work and asserts a floor
(`mutations >= 400`, `iterations >= 3_000`, `widened > 0`, `partialsChecked > 0`)
— the `InvariantCheckTests` lesson applied to the sweeps themselves, since a loop
narrowed to nothing passes silently and this is the package's highest-value suite
to lose that way.

**Mutation-tested, not assumed.** Three deliberate reducer breakages, each
reverted (`git checkout`, source tree confirmed clean):

| Mutation | Caught by |
|---|---|
| Gap range narrowed to one row (merging removed) | interior-gap oracle + 2 unit tests |
| Delta accumulation → assignment | I5 oracle, **monotonicity**, 5 unit tests |
| *(the above, re-run to isolate)* | `truncationIsMonotone` specifically |

**Also landed:** the Phase 1 follow-up — `TODO(human)` blocks and their dead
`guard … else { Issue.record }` scaffolding collapsed to plain assertions,
keeping the derivation comments. Zero `TODO(human)` markers remain.

**Exit:** ✅ roadmap's crash-fuzz criterion met in full; 166 green.
**Review gate:** review the two oracles — they are the only place a sweep asserts
something the reducer did not compute, so they are where a wrong expectation
would hide.

---

### Phase 3 — On-disk corpus + version-freeze scaffolding ✅ *done 2026-07-26 (166 → 175 tests)*

**Goal:** the §10.2 evolution safety net's machinery, ready for M9 to freeze.

- [x] **Schema** (D5) in `CorpusFile.swift`, documented in `Corpus/README.md`:
      `{conversationID, rows: [{sequence, event}]}`, mirroring the events table
      so `sequence` sits *outside* the blob exactly as it does in the real key.
      Gaps need no representation — a missing sequence number is a missing row.
      The `raw` row form is reserved and **throws** rather than guessing, per
      D5: synthesising `LoadedEvent`s test-side would freeze fixtures against a
      reimplementation of the decode boundary.
- [x] **`StateDump`** — deterministic rendering, explicit stack rather than
      recursion, no dictionary iteration, and **no `description` or
      `String(describing:)` anywhere** (see D10's second half).
- [x] **Record mode** — `LEDGERKIT_RECORD=1`, gated with `.enabled(if:)`.
      Verified **idempotent**: a second record run leaves zero diffs.
- [x] **Runner** — reads `Bundle.module`; folds *the file*, not the in-memory
      fixture, so decode → fold is exercised as a composition rather than the
      same object being tested twice.
- [x] **Round-trip + canonical timestamps** — value-identity across all three
      directories; every row asserted born-canonical, so M4's store inherits a
      fixture that already fails if it canonicalizes at encode instead.
- [x] **Directory layout** + M9 freeze procedure in `Corpus/README.md`.
- [x] **Wire-surface coverage** — *added beyond the plan:* all ten payload
      discriminators must appear somewhere on disk. A kind absent from the
      corpus is a kind with no evolution safety net, and this is what makes a
      new tag arrive *with* a fixture rather than a year later.

**A third directory, not two (deviation).** The plan had `dev/` and `frozen/`.
Building it surfaced that the corpus must also contain **bytes this version
cannot write** — a future payload kind, an outcome whose discriminator we have
never heard of. Round-tripping those through our encoder would silently rewrite
them into shapes we already understand, which is the one thing a
forward-compatibility fixture must not do. Hence `wire/`: hand-authored once,
never regenerated, only its `.txt` re-recorded.

`wire/tolerantTerminals.json` is the payoff — three generations ending in three
different row-3 shapes (unknown outcome tag, unknown *nested* error tag, absent
outcome field). All three land as `.failed(.unrecognized(…))` with distinct
descriptions, **zero diagnostics**, each with a terminal timestamp. That is the
whole tolerant-terminal story demonstrated from bytes on disk, which is the only
form the forward-compatibility claim actually takes.

**Excluded from disk, by construction:** `rich` and `hostile`, each of which
contains `LoadedEvent.undecodable` rows. Those are *loader outcomes*, not wire
bytes; they join at M4 via the reserved `raw` form. Their coverage is in-memory,
where it is unaffected.

**Mutation-tested.** Semantic drift in a recorded `.txt`, and a wire fixture
whose bytes stop meaning what was recorded — both caught, both restored, suite
back to green. One real bug was caught by *reading* the generated output before
trusting it: `Optional("27.0")` was leaking into the model field, which would
have been frozen into the format forever.

**Exit:** ✅ 8 dev fixtures + 1 wire fixture; 175 green; freeze procedure written.
**Review gate:** review `Corpus/README.md` and one generated `.txt` as if they
were public API — frozen files outlive everything else in this repo.

---

### Phase 4 — `ScriptedLanguageModel` (`LedgerKitTestSupport`)

**Goal:** the deterministic double — a real `LanguageModel` conformer with a
public script vocabulary designed call-site first.

> **Premise changed before this phase started.** The toolchain is **Xcode 27.0
> Beta 4 with the macOS 27 SDK** (CLAUDE.md said 26.6 — corrected), and
> `LanguageModel` / `LanguageModelExecutor` compile against it. **OQ3 is
> therefore answerable by reading, not guessing**, and the design below is
> derived from the SDK's real `.swiftinterface`, not from WWDC coverage. See
> D11. Copy of the interface used: `FoundationModels.swiftinterface`,
> `MacOSX27.0.sdk`, 3,583 lines.

**The real protocol surface (verified, not inferred):**

```swift
public protocol LanguageModel: Sendable {
  associatedtype Executor: LanguageModelExecutor where Self == Self.Executor.Model
  var capabilities: LanguageModelCapabilities { get }
  var executorConfiguration: Self.Executor.Configuration { get }
}
public protocol LanguageModelExecutor: Sendable {
  associatedtype Configuration: Hashable, Sendable
  associatedtype Model: LanguageModel
  func prewarm(model: Self.Model, transcript: Transcript)
  init(configuration: Self.Configuration) throws
  nonisolated(nonsending) func respond(to: LanguageModelExecutorGenerationRequest,
                                       model: Self.Model,
                                       streamingInto: LanguageModelExecutorGenerationChannel) async throws
}
// channel: await channel.send(.response(action: .appendText(_:segmentID:tokenCount:)))
//          … .updateUsage(input:output:metadata:), .updateMetadata(_:)
//          plus .reasoning(…) and .toolCalls(…) event families
```

Three facts from the interface that changed the design (and would each have
produced a wrong API):

1. **`appendText`'s `tokenCount` has no default**, and Swift enum cases cannot
   carry default parameter values → `Step` must be a **struct with static
   factories** (D12). Apple's own `Response.Action` is exactly that shape.
2. **The framework builds the executor from a `Configuration: Hashable &
   Sendable`** — you never hand it your object → the script and the request
   recorder must travel *by reference* through the configuration.
3. **`LanguageModelError` cases carry payload structs**
   (`case rateLimited(LanguageModelError.RateLimited)`) → raw `.fail(…)` call
   sites are verbose and want conveniences.

**Decided by Alexander (2026-07-26):** conform now, availability-gated (D11);
imperative step verbs; `Cue` for the rendezvous.

#### The surface

```swift
// 26+ — platform-agnostic vocabulary and engine, runs and is tested today
public struct Script: Sendable, ExpressibleByArrayLiteral, ExpressibleByStringLiteral {
    public struct Step: Sendable, ExpressibleByStringLiteral {
        public static func emit(_ text: String, tokenCount: Int = 1) -> Step
        public static func wait(_ duration: Duration) -> Step
        public static func waitFor(_ cue: Cue) -> Step
        public static func reportUsage(input: Int, output: Int,
                                       cached: Int = 0, reasoning: Int = 0) -> Step
        public static func reportMetadata(_ values: [String: String]) -> Step
        public static func fail(_ error: any Error) -> Step
    }
}

public final class Cue: Sendable {          // two-sided rendezvous
    public init()
    public func reached() async             // test waits for the model to park here
    public func signal()                    // let it continue
}

public enum ScriptExhaustion: Sendable { case fail, repeatLast, loop }

// 27+ — the real conformance, compile-checked today
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
public struct ScriptedLanguageModel: LanguageModel {
    public init(replying: String)
    public init(script: Script)
    public init(scripts: [Script], whenExhausted: ScriptExhaustion = .fail)
    public init(failingWith: any Error)
    public var requests: [LanguageModelExecutorGenerationRequest] { get }   // spy, sync
}
```

#### Tasks

- [ ] Package topology per D3 (no LedgerKit dependency); fix the stale
      `Package.swift` platforms comment.
- [ ] `Script`, `Script.Step`, `Cue`, `ScriptExhaustion` — 26+, no FM import.
- [ ] Engine: plays a script into a sink; cooperative cancellation checked at
      every step boundary; clock injectable (`any Clock<Duration>`, default
      `ContinuousClock`) so `.wait` is real for previews and controllable in
      tests. `.waitFor(cue)` is the deterministic tool.
- [ ] `ScriptedLanguageModel` + `ScriptedExecutor` conformance, `@available`
      27+, with the recorder carried by reference through `Configuration`.
- [ ] Request spy: `requests` readable synchronously (lock-backed, not `async`)
      so `#expect(model.requests.count == 1)` needs no `await`.
- [ ] Tests in `LedgerKitTestSupportTests`: playback determinism (two runs,
      identical emissions), cancellation at every step boundary via `Cue`,
      exhaustion policy, multi-turn, clock control. Conformance tests gated
      with `.enabled(if:)` — they compile now, run on macOS 27.
- [ ] Doc comments carrying the "gateway drug" framing: zero network, zero
      Apple Intelligence eligibility, CI-safe on any Mac.

**Deliberately not done:** result builder (array literal reads nearly as well
and a builder is a non-breaking addition later); `.reasoning` / `.toolCalls`
channel families (LedgerKit v0.1 records neither — N8, OQ9); conveniences for
every `LanguageModelError` payload (add on demand).

**Exit:** `swift test --package-path LedgerKitTestSupport` green; engine
deterministic; conformance compiles.
**Review gate:** review the public vocabulary as API — it is a long-lived
contract and likely a consumer's first impression of the project.

#### Recorded for M6

- **§7.3 confirmed, with a nuance worth a rev-6 sentence:** the *executor*
  writes deltas (`appendText`); `ResponseStream.Snapshot` reads *cumulative*
  (`content: Content.PartiallyGenerated`). Both true — the framework
  accumulates. §7.3 describes the driver's seat and stands.
- **A free end-to-end property for M6:** script delta → framework accumulates →
  snapshot → driver diffs → `deltaAppended`. The driver's diff must recover
  exactly the deltas the script emitted.
- `LanguageModelError` case inventory (**closes most of OQ5**):
  `contextSizeExceeded`, `rateLimited`, `guardrailViolation`, `refusal`,
  `unsupportedCapability`, `unsupportedTranscriptContent`,
  `unsupportedGenerationGuide`, `unsupportedLanguageOrLocale`, `timeout` —
  each with an associated payload struct. Note **`refusal`**, which §8's
  `GenerationError` does not currently mention.
- `LanguageModelExecutorGenerationRequest` carries `id`, `transcript`,
  `enabledToolDefinitions`, `schema`, `generationOptions`, `contextOptions`,
  `metadata` — the rehydration assertion surface for OQ1.
- `Snapshot` gained `usage` and `transcriptEntries` at 27 (feeds §7.7).

#### Flagged, not acted on

**`LedgerKitTestSupport` is a poor name for the "gateway drug" pitch** — nobody
installs *LedgerKitTestSupport* to get a scripted Foundation Models double.
SPEC §10.1 names the product, so renaming is a rev-6 conversation, not an
implementation decision.

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

## 5. Coverage traceability (Phase 0 audit, 2026-07-25; maintained after)

Baseline at audit: **151 tests green** (143 before Phase 0). `FolderTests.swift`
line numbers are stable — Phase 0 only removed its tail.

### §6.6 quarantine rows

| Row | Condition | Existing coverage | Gap → phase |
|---|---|---|---|
| 1 | Undecodable envelope | `FolderTests:97` `undecodableEnvelope`; hostile seq 16 | on-disk form → **P3**/M4 |
| 2 | Unknown payload kind | `FolderTests:87` `undecodableIsNotAGap` (asserts eventID); rich seq 12, hostile seq 17 | on-disk form → **P3**/M4 |
| 3 | Undecodable outcome — **non**-quarantine | `WireFormatTests:261–318`, all four shapes + `<missing>`/`<unreadable>` | **decode-level only — no test proves a tolerant terminal *terminates the generation* in the fold** → **P1** |
| 4 | Foreign `conversationID` | `FolderTests:49` `foreignConversation`, `:58` `foreignOutranksGenesis`; hostile seq 22 | — |
| 5 | Before genesis / second genesis | `FolderTests:30`, `:40`; hostile seq 1, 3 | — |
| 6 | User append: unknown parent / ID reuse | `FolderTests:231` `unknownParent`, `:240` `duplicateMessageID` | back-door shape (reuse an **in-flight assistant** ID) → **P1** |
| 7 | Second bare nil-parent append | `FolderTests:221` `secondRootMessage`; hostile seq 5 | — |
| 8 | Start: gen-ID reuse / bound msg-ID / unknown parent | `FolderTests:440`, `:449`, `:457`, `:467`, `:474`; hostile seq 6 | — |
| 9 | Delta/tool/**terminal** unknown gen; out-of-bounds | `FolderTests:571`, `:581`, `:601` (delta), `:618` cascade (all three kinds); hostile seq 7, 8, 12 | standalone row-9-vs-10 partition test → **P1** |
| 10 | Second terminal | `FolderTests:591`; `FolderOrderingTests:185`; hostile seq 13 | — |
| 11 | Edit: assistant / unknown / replacement collision | `FolderTests:608`, `:314`, `:321`; hostile seq 14 | — |
| 12 | Path endpoint never existed | `FolderTests:336`; `ClassifyTests:104`; hostile seq 15 | — |

### Non-rules (must reduce **without** residue)

| Non-rule | Existing coverage | Gap → phase |
|---|---|---|
| Tolerant terminal | `WireFormatTests:261–318` | fold-level end-to-end → **P1** |
| Role adjacency (assistant parent, consecutive user siblings, nil-parent start) | `FolderTests:252`, `:421`, `:431` | — |
| Sequence gaps (one per contiguous gap) | `FolderTests:65`, `:77`, `:87` | **gap that swallows a terminal ⇒ `.interrupted`** → **P1** |
| Cascade (start orphans delta + tool + terminal) | `FolderTests:618`, exact residue | — |
| Duplicate `EventID` reduces without residue | **none** | → **P1** |
| Row ordering is a precondition | `FolderOrderingTests:133–204` (6 tests) | — |

### Invariants and sweeps

| Item | Existing coverage | Gap → phase |
|---|---|---|
| I1 literal goldens (cross-process) | `CorpusTests:47` `richGolden` | per-fixture goldens → **P1** |
| I1 repeat / mapping half | `CorpusSweepTests:18`; `ClassifyDeterminismTests` | — |
| I2 totality over prefixes | `CorpusSweepTests:29` — **now both layers, corpus-wide** | interior-gap + compound → **P2** |
| I3 / I4 | rows 9, 10 above | — |
| I5 synthesis | `ClassifyTests:17`; now universal via the bridge predicate | partial-content sweep → **P2** |
| I6 virtual root / clamping | `CorpusSweepTests:54`; `FolderTests:304` root edit | — |
| I7 allocate-once at 3 sites | rows 6, 8, 11 above | assert as **one rule** → **P1** |
| Diagnostic identity (eventID populated) | **universal** in `invariantProblems` (Phase 0) | — |
| P3 snapshot equivalence | `CorpusSweepTests:75`, every split of every fixture | widen with corpus → **P2** |
| Crash-fuzz interior gaps | **none** | → **P2** |
| Version-frozen corpus | **none** | → **P3** |
| `ScriptedLanguageModel` | **none** | → **P4** |

### Golden shapes already covered (no new fixture needed unless pinned as a file)

Ordinary turn, multi-turn linear, edit-as-sibling, **root-message** edit,
regenerate-as-sibling, branch switch, all four terminal kinds, zero-token
failure, instructions/title set–clear–LWW, in-bounds tool records, empty log.
Phase 1 promotes these into named `Corpus` entries so the sweeps reach them;
their assertions exist already and mostly move rather than get written.

## 6. Decision log

| # | Decision | Status |
|---|---|---|
| D1 | Corpus registry in `LedgerKitTests`; sweeps iterate it | **Accepted** · landed Phase 0 |
| D2 | No third-party test deps; own `ConversationDump` format | **Accepted** · applies Phase 3 |
| D3 | TestSupport does not depend on LedgerKit (topology one-way door) | **Accepted** · applies Phase 4 |
| D4 | OQ3: engine now, internal seam, M6 adapter | ~~Accepted~~ · **superseded by D11** |
| D5 | On-disk schema `(sequence, raw JSON)`; rows 1–2 defer to M4 | **Accepted** · applies Phase 3 |
| D6 | Fuzz generators remove-only; never reorder/duplicate | **Accepted** · applies Phase 2 |
| D7 | Classify predicate bridges both layers | **Landed Phase 0** (deviation, reasoned above) |
| D8 | Corpus = logs worth sweeping; unit tests = rules. No per-row duplication | **Landed Phase 1** (deviation, reasoned above) |
| D9 | Oracles must be simpler than the fold; else assert a relation | **Landed Phase 2** |
| D10 | Freeze only what the log determines: dump `FoldedState`, switch on case names | **Landed Phase 3** (deviation, reasoned above) |
| D11 | Conform to the real FM protocols now, availability-gated | **Approved 2026-07-26** (supersedes D4) |
| D12 | `Script.Step` is a struct with static factories, not an enum | **Approved 2026-07-26** |

## 7. Status log

| Date | Phase | Tests | Note |
|---|---|---|---|
| 2026-07-25 | Plan drafted | 143 | D1–D6 approved by Alexander |
| 2026-07-25 | **Phase 0 done** | **151** | Harness + registry + audit; D7 recorded; reviewed and approved |
| 2026-07-25 | **Phase 1 scaffolded** | **161 (159 green)** | 8 fixtures + 8 rule tests; D8 recorded; 2 `TODO(human)` open |
| 2026-07-26 | **Phase 1 done** | **160** | Handoffs filled; review cleanups applied (1 duplicate test + 2 dead accessors removed) |
| 2026-07-26 | **Phase 2 done** | **166** | Crash-fuzz complete: 520 gap mutations + 3,289 compound iterations, 0.17 s; D9 recorded; mutation-tested |
| 2026-07-26 | **Phase 3 done** | **175** | On-disk corpus: 8 dev + 1 hand-authored wire fixture, 3 directories, freeze procedure written; D10 recorded; mutation-tested |
| 2026-07-26 | **SPEC rev 6 drafted + implemented** | **175** | §8 taxonomy reconciled (`contextSizeExceeded`, `refusal`, `unsupported`), §7.3 stream-sides, §10.1 provisional name; ADR-001 gains a reserved-tag table; OQ3 + OQ5 closed. **Ratifies at the M3 boundary.** |

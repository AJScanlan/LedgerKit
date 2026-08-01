# M6 Implementation Plan — `GenerationDriver`: the session seam

**Status:** 🚧 **IN PROGRESS** — drafted 2026-07-28 at the M5 boundary; **Phase 0
landed 2026-07-29** (335 green: 314 `LedgerKit` + 21 `Understudy`, warning-free,
and the 314 also green on the iOS 27 simulator). **Next: Phase 1** — the pure
components. Three items are still awaiting gate sign-off; they are listed under
Phase 0's *Gate state*, and none of them blocks Phase 1.
**Companion to:** [ROADMAP.md](./ROADMAP.md) (M6 section) · [SPEC.md](./SPEC.md) §7 (all of it), §8, §10.4–10.5, §14 (the four residues) · [M4-PLAN.md](./M4-PLAN.md) §2 (the SDK fact table + its correction) · [M5-PLAN.md](./M5-PLAN.md) §7 (the six inherited handoffs)
**Baseline:** M0–M5 done and audited, **331 tests green** (310 `LedgerKit` + 21 `Understudy`), SPEC **rev 8 ratified 2026-07-28**. The M5 boundary audit (2026-07-28) found two store bugs and four contract-surface issues, **all folded into Phase 0 below** — the store must enter M6 clean, because M6 is the milestone where a store regression has to unambiguously point at M6 (M5 handoff 6).
**Spec work:** rev 9 opens with its first amendment and **ratifies at the M6 boundary**. The inventory is §6; SPEC edits require approval first, drafted scratch-first per the standing pattern.

> **How to use this document.** This plan persists across sessions, agents, and
> compactions — it is the working memory for M6. Update the checkboxes and the
> per-phase status lines as work lands; record anything that changes a decision
> in the Decision log (D-numbers continue M5's global sequence at **D30** — a
> bare "D8" means the same thing in every plan); do not silently deviate. Each
> phase ends with a **review gate**: stop, run both packages' suites, and review
> with Alexander before starting the next phase.

> **TL;DR (kept from M5's experiment — it earned its keep).** M6 writes the one
> production `GenerationDriving` conformance: `Session/GenerationDriver`, over a
> real `LanguageModelSession`. It opens with a **hygiene phase** (the M5-audit
> fixes: the delete-vs-reservation race, the rehydration release gap, the stale
> throw-channel docs, public policy construction), front-loads everything
> platform-agnostic (the snapshot differ, error normalization — Phase 1 runs on
> any Mac), and pushes 27-only execution to the back phases behind whatever
> substrate Phase 0's spike finds. The design centers are **D33** (the driver is
> an actor; sessions rebuild per generation first, cache later or never) and
> **D34** (the differ is a pure function the driver merely feeds). The four §14
> behavioural residues are Phase 4's, and only running code answers them.
> **The floor does not move to 27** (D31) — `Session/` is availability-gated,
> exactly like `Understudy`'s conformance.

---

## 1. What M6 is, in one paragraph

M6 is the one OS-coupled module (§7): `Session/GenerationDriver`, conforming to
the `GenerationDriving` seam M5 defined, over `LanguageModelSession`. Its
obligations are §7's, restated by the §7.9 ownership table: **rehydration**
(§7.1 — materialize the request's context and instructions into a seeded
transcript), the **outcome boundary** (§7.2 — every failure after the store's
start append is an `Outcome`, never a throw; the `isResponding` gate),
**snapshot→delta diffing** (§7.3 — segment-aware preferred, fail loud on
non-prefix), **error normalization** (§8 — both error families, per-provider
mapping files, fixture-tested per §10.5), **tool-record observation** (§7.6 —
record, don't orchestrate; `.metadataOnly` default), and **usage/model-identity
capture** (§7.7–7.8 — nil expected on-device, never an error). All iOS-27-beta
risk lives here and nowhere else; every earlier milestone verifies on any Mac,
and this plan is structured so that as much of M6 as possible does too.

**Roadmap exit criteria (the contract for "done"), restated honestly against
the substrate constraint (D36):**

- `GenerationDriver` conforms to `GenerationDriving` — **the protocol does not
  move without a rev 9 conversation first** (M5 handoff 1) — and both packages
  compile warning-free under strict concurrency with the platform floor
  unchanged (D31).
- The **differ and normalization suites are green on macOS 26** (Phase 1 — no
  Foundation Models import anywhere in them).
- **The §7.3 round-trip property holds end-to-end**: scripted fragments →
  real framework accumulation → snapshots → driver diff → `deltaAppended`
  recovers the script exactly (M5 handoff 3). This is the "real stream captured
  & reduced" criterion — real `LanguageModelSession` accumulation, scripted
  provider. Green on the substrate Phase 0 identifies; if no substrate exists,
  the suite is written, compile-verified, `.enabled(if:)`-gated, and the gate
  records that explicitly rather than claiming green.
- §10.5 fixtures pass for the on-device family and the deprecated iOS-26 family;
  the Claude-package family if the package is obtainable (cut line 4 otherwise —
  §12).
- The **four behavioural residues** (§14 head) are answered where hardware
  permits, and written back into the spec where they change anything (§6).
- **Phase 0's audit fixes are all landed with the tests that would have caught
  them.**
- SPEC **rev 9 ratified** at the boundary.

---

## 2. Context that must survive compaction

Facts M6 depends on that live in other documents, in M5's implementation, or in
the M5 boundary audit. Curated, not accumulated — each row is here because some
Phase below acts on it.

| Fact | Source | Consequence for M6 |
|---|---|---|
| **The SDK fact table is already built — do not re-derive it.** Thirteen rows, one corrected (`Transcript.Segment` grew, not `Entry`), each with an interface line number | M4-PLAN §2 | Phase 0's reading session *extends* that table (constructibility questions, session isolation); it does not repeat it. Re-read a citation before anything downstream depends on it — the correction exists because one row was wrong |
| The authoritative interface is the installed 27-SDK `.swiftinterface` (path in CLAUDE.md, 3,583 lines) | CLAUDE.md; M4 lesson | **Read the interface first; a spike evening is for what the interface cannot answer.** Seven of nine OQs closed by reading — the pattern that keeps M6 short |
| **Four behavioural residues, and only running answers them**: is `concurrentRequests` thrown or trapped; do real providers emit `replaceTextSegment`; is `Usage.Input.totalTokenCount` inclusive of cached; the real on-device context budget | SPEC §14 head | Phase 4. Each residue names in advance what changes if the answer is adverse (see Phase 4), so the evening produces spec text, not just notes |
| The dev machine runs **macOS 26**; 27-only code compiles (SDK is 27) and cannot execute as a macOS host test | CLAUDE.md toolchain note | D31 (floor stays 26; gate with `@available` + `.enabled(if:)`) and D36 (three test tiers). Phase 0's substrate spike asks whether the iOS 27 *simulator* runtime can execute the gated tests via `xcodebuild` on this host — the answer shapes every later gate |
| `GenerationDriving` = `var model: ModelDescriptor` + non-throwing `generate(_:streamingInto:) async -> Outcome`; **must not start throwing** | `Store/GenerationDriving.swift`; M5 handoff 1 | Exactly one terminal is the type's grammar. If the seam needs to move, that is a rev 9 conversation *first*, never a silent widening |
| ⚠️ **A cancellation-aware backend cannot record from inside a cancelled task** (M5's headline finding). The store already runs its wind-down outside the cancelled scope | SPEC §7.5 (rev 8); M5 handoff 2 | The driver must not reintroduce the same wall: no cleanup *writes* exist on its side (it only signals), so its whole obligation on cancellation is §7.5's — wind down, return `.cancelled` |
| **`Cue` inverts at M6**: the script *player* parks (internal `park()`), the test drives it through the public `reached()`/`signal()` | M5 handoff 5; `Understudy/Cue.swift` | The first `Understudy` import is M6's (D37). `ScriptedDriver` (test target) remains the store-side double — imitate it, don't replace it (M5 handoff 6) |
| `ScriptedLanguageModel` sits on the **provider** side (writes `appendText` fragments); LedgerKit's driver is a **consumer** (reads cumulative snapshots); the framework accumulates between them | SPEC §7.3 (rev 6) | The round-trip property (Phase 3) is exactly this pipeline asserted end-to-end. The corpus gains its fixture *then*, not before (M5 handoff 3) |
| The store owns the flush cadence and every append; the driver produces deltas, not snapshots | SPEC §7.9 ownership table | The driver never buffers for durability and never waits on a flush; `GenerationChannel.emit` is fire-and-forget |
| The requested `ModelDescriptor` is **app-supplied at driver init** — nothing in FM derives it | SPEC §7.8, OQ8 | The driver init takes a descriptor. §11's sketch line (`GenerationDriver(model:toolRecording:)`) predates OQ8's closure — Phase 2 decides between a required `descriptor:` and a system-model convenience; rev 9 records whichever (§6 item 3) |
| **D33's first stance sidesteps session-cache invalidation entirely**: rebuild-per-generation means no cache, so `deleteConversation` needs no driver notification | D33 below | If a reuse cache lands later in M6, *it* must solve invalidation (the seam has no delete signal — deliberate; sessions are cattle) and bound its size. No seam change either way |
| **M5 audit, finding A1**: `deleteConversation` waits only on `.running`; a `.reserved` slot (start append in flight) lets the DELETE race the start transaction — either ordering leaves genesis-less rows or appends into an erased conversation | Boundary audit 2026-07-28; `ConversationStore.deleteConversation` | Phase 0 fix. Delete must wait for the reservation to *resolve* (confirm or roll back), which converges the reserved case onto the already-correct running case — the verb still returns `.cancelled`, per §9 |
| **M5 audit, finding A2**: the `rehydrationMaterial` read between `commit` and `drive` is outside both `release` guards. Reachable cold (a mid-flight `edit` racing the start commit lands the D29 eviction): a read failure **wedges single-flight forever**; a task-cancel there throws `CancellationError` post-append, violating §7.2's straddle | Boundary audit 2026-07-28; `ConversationStore.run` | Phase 0 fix. Proposed shape: move the rehydration read *inside* the generation task, where `drive`'s `defer { release }` covers it and a cancellation converts to the recorded `.cancelled` wind-down. Also shrinks the reserved window to the commit alone |
| **M5 audit, finding B1**: `LedgerError`'s type doc ("a throw means the log is untouched"), `persistenceFailure`'s ("Nothing was recorded"), the store's headline doc, and `send`/`respond`'s `- Throws:` prose all state the **pre-rev-8** throw contract | Boundary audit; rev 8 §11 ("couldn't record, not only never started") | Phase 0 rewrite. Verification is a grep for the retired phrasing — the mechanism CLAUDE.md's sweep rule now names |
| **M5 audit, finding B2**: SPEC §7.4/§9 promise both cadences configurable; `DeltaFlushPolicy`/`SnapshotPolicy` publicly expose only `.default`. The "price it at Phase 3's gate" moment passed without the decision being recorded | Boundary audit; `Store/Policies.swift` | D32: publish the knobs at Phase 0. Approved 2026-07-28 |
| **M5 audit, finding B3**: `Package.swift`'s "Bump to 27 at M6" comment is wrong — a 27 floor makes the whole suite unlaunchable on this macOS 26 host and forces every consumer to 27 | Boundary audit; `LedgerKit/Package.swift` | D31 records the real strategy (Understudy's pattern); Phase 0 fixes the comment |
| `Understudy` deliberately does not depend on LedgerKit; floor 26; only the conformance is `@available(macOS 27)` | `Understudy/Package.swift` | The import direction is LedgerKitTests → Understudy, necessarily a **path** dependency (D37) — with a consumability consequence flagged to M9 |
| Store determinism under injection: `ScriptedIdentifiers`, `SteppingClock`, `StoreUnderTest.continuing(_:)`, `RecordingStore` (observe writes, not read-backs), `Latch`, `healthyLogProblems` | `StoreFixtures.swift`; M5-PLAN | Phase 3's end-to-end fixtures reuse all of it. Assertions about what was written must observe the write — the wire formatter repairs a bad stamp on the way back out |
| `Log.isStoreReplayable` states which fixtures round-trip through the store | `ReducerFixtures.swift` | The Phase 3 corpus fixture must qualify (gapless, single-stream, no byte-built rows) or state why it is excluded |

---

## 2a. What Phase 0's reading session found (2026-07-29)

Read from the installed 27 SDK interface (path in CLAUDE.md, 3,583 lines) —
**extending** M4-PLAN §2's thirteen rows, not repeating them. Every row below is
here because a later phase acts on it. Re-read the citation before depending on
it; M4-PLAN §2 exists because one row was once wrong.

| Question | Answer | Consequence |
|---|---|---|
| **Are Apple's errors constructible for §10.5 fixtures?** (D35's open item) | **Yes, all nine.** Every `LanguageModelError` payload struct has a public init — `ContextSizeExceeded(contextSize:tokenCount:debugDescription:metadata:)`, `RateLimited(resetDate:debugDescription:metadata:)`, `Timeout(debugDescription:metadata:)`, and so on. `LanguageModelSession.Error` is two bare cases. The deprecated family needs only `GenerationError.Context(debugDescription:)` | **Constructibility was never the binding constraint — availability is**, which is the opposite of what D35 anticipated. `LanguageModelError` is `@available(27)`, so its fixtures are tier 2; the **deprecated `LanguageModelSession.GenerationError` family is `@available(macOS 26)`**, so *those* fixtures are tier 1 and run in every `swift test`. The 26-family normalizer can also live outside an availability gate |
| **What does the deprecated family actually contain?** | `exceededContextWindowSize`, `assetsUnavailable`, `guardrailViolation`, `unsupportedGuide`, `unsupportedLanguageOrLocale`, `decodingFailure`, `rateLimited`, `concurrentRequests` (the only case marked deprecated), `refusal` — each carrying a `Context { debugDescription }` | ⚠️ **Unplanned finding: two cases have no §8 analogue.** `assetsUnavailable` plausibly maps to `modelUnavailable(.modelNotReady)`; `decodingFailure` is guided-generation-only, which v0.1 never requests (N8). Phase 1 must *decide and record* both rather than let them fall through `unrecognized` by accident — the mistake rev 6 caught §8 making with the four `unsupported*` cases. Rev 9 inventory item 8 |
| **`isResponding`'s surface** | `final public var isResponding: Bool { get }` — synchronous, non-async, on the session | §7.2's gate is a plain `if`, no await, no isolation dance |
| **Is `LanguageModelSession` isolated?** | A `final public class`, `@unchecked Sendable`, `nonisolated Observable`. Not an actor, not `@MainActor` | Nothing forces D33's hand: the actor is a choice about owning mutable state, not a requirement of the session. Also means the session offers **no** concurrency protection of its own — `isResponding` plus store single-flight is the whole defence |
| **The streaming call** | `streamResponse(to: Prompt, options:) -> sending ResponseStream<String>` — **neither `async` nor `throws`**; 27 adds overloads taking `contextOptions:` and `metadata:`. `ResponseStream` is an `AsyncSequence` of `Snapshot`, with `collect()` for the non-streaming shape | Phase 2's loop puts the `do/catch` around the `for try await`, **not** around the call. A provider failure therefore arrives mid-iteration, which is exactly where the partial already exists — so §7.2's zero-token case is the *first* iteration throwing, not a separate path |
| **`Snapshot`'s shape** | `{ content: Content.PartiallyGenerated, rawContent, transcriptEntries: ArraySlice<Transcript.Entry> (27), usage: Usage (27) }` | Confirms rev 7. For `Content == String`, `content` is the flat fallback and `transcriptEntries` the segment-aware path |
| **What identifies a segment?** (D34's premise) | `Transcript.Segment` is `Identifiable` with `ID == String`; `TextSegment { id: String, content: String }` | **D34's `(segmentID: String, text: String)` pair *is* a text segment**, so extraction is one `map` and the differ owes nothing to Foundation Models. The design was proposed on a guess; the interface confirms it |
| **Rehydration entry construction** | `Transcript(entries: some Sequence<Entry>)`; `Instructions(id:segments:toolDefinitions:)`; `Prompt(id:metadata:segments:options:responseFormat:contextOptions:)`; `Response(id:metadata:segments:)` — all public | The three entries §7.1 needs are constructible. No API risk left in the ledger→transcript direction |
| **Usage construction** | `Usage(input:output:metadata:)`, `Usage.Input(totalTokenCount:cachedTokenCount:)`, `Usage.Output(totalTokenCount:reasoningTokenCount:)` — all public; plus a computed `Usage.totalTokenCount` | §7.7's 1:1 mapping onto `TokenUsage` is **fixture-testable without a device**, so only the *inclusivity* residue needs hardware |
| **`Refusal`'s asymmetry** | Stores `{ debugDescription, metadata }` but its init takes `explanation:`, and `explanation` is a separate `async throws Response<String>` | Consistent with rev 7's reading: the explanation is generated on demand, not stored. Nothing to project (§8) |

---

## 3. Decisions (made up front; revisit only at a review gate)

### D30 — M6 opens with the audit's hygiene phase; the store enters M6 clean
The M5 boundary audit's findings (A1, A2, B1, B2, B3, and the staleness batch)
are Phase 0, before any Foundation Models code. Two reasons beyond tidiness.
First, M5 handoff 6: every store behaviour is pinned against `ScriptedDriver`,
so a store-side regression at M6 points at M6 — which is only meaningful if the
store is actually correct when M6 starts. Second, both A-findings live in the
reserve→release window that M6's driver work sits directly on top of; fixing
them under the new driver would confound whose bug it was. **Every fix lands
with the test that would have caught it** (the parked-append harness exists;
A1's test is `ParkingStore(parkingFirst: .append)` plus a concurrent delete),
and each gets a mutation run per the standing practice.

### D31 — The platform floor stays 26; `Session/` is availability-gated
`LedgerKit`'s floor remains `.iOS(.v26)/.macOS(.v26)`. Every `Session/`
declaration is gated `@available(macOS 27.0, iOS 27.0, visionOS 27.0,
watchOS 27.0, *)` with `@available(tvOS, unavailable)` — byte-for-byte the
pattern `Understudy` already ships for `ScriptedLanguageModel` — and 27-only
tests are `.enabled(if:)`-gated (M3's pattern). Bumping the floor instead would
(a) make the entire LedgerKit test binary unlaunchable on this macOS 26 dev
machine — all 310 tests, not just the driver's — and (b) force every consumer
to 27 for a library whose core is deliberately 26-clean. The `Package.swift`
comment recommending the bump is corrected at Phase 0. Cost accepted: every
`Session/` declaration carries the availability attribute, which is noise
`Understudy` has already shown to be tolerable.

### D32 — The policy knobs go public *(approved 2026-07-28, from audit B2)*
`DeltaFlushPolicy` and `SnapshotPolicy` gain public construction. The spec has
promised configurability since rev 2 (§7.4 "make both cadences configurable",
§9 "both configurable"); the loop that reads them has existed since M5 Phase 3
and is mutation-tested; and the current halfway state — public init parameters
that accept exactly one value — is API noise pretending to be flexibility.
Exact spelling is a Phase 0 gate item; the candidates, per D12 (structs with
factories for instructions consumers construct):

- Promote the internal memberwise inits to public with audited labels
  (`DeltaFlushPolicy(interval:characterCount:)`,
  `SnapshotPolicy(refreshesAfterEachGeneration:maximumEventsBetweenRefreshes:)`), or
- Named factories (`.flushing(every:orAfterCharacters:)`), keeping inits internal.

Either way `.default` stays, and a `SnapshotPolicy` variant that disables the
per-terminal refresh (floor-only — what a bulk importer wants) should exist or
be constructible. Doc comments carry the §7.4 truth-hierarchy positioning
(these are *disk* cadences, not display cadences).

### D33 — The driver is an actor; sessions are rebuilt per generation *first*
`GenerationDriver` is an `actor` (it owns mutable session state and is called
across isolation; `model` is `nonisolated let`, exactly what the protocol doc
prescribes). **v0.1 ships rebuild-per-generation first**: every `generate`
materializes a fresh session from the request via
`LanguageModelSession(model:tools:transcript:)` (OQ1's confirmed initializer).
This is always correct — §7.1's ownership rule says discard-and-rebuild is
always legal, and correctness never depends on reuse — and it sidesteps cache
invalidation entirely (no cache, nothing for `deleteConversation` to leave
stale). The §7.8 cardinality rule is trivially satisfied: a session is never
shared across conversations because it is never shared at all.

The per-conversation **reuse cache is a later M6 phase, and optional**: it
lands only behind an explicit validity rule (reuse only when this request's
context strictly extends what the cached session last completed — any edit,
branch switch, or interruption on the path invalidates) and ideally a
measurement showing the KV-cache win is real on-device. If M6 runs short, the
cache is the first thing cut — it is an optimization the spec explicitly
declines to depend on. (The ROADMAP's "per-conversation session cache" bullet
describes the §7.8 *cardinality ceiling*, which rebuild-always also satisfies.)

### D34 — The differ is a pure, platform-agnostic component the driver feeds
Snapshot→delta diffing (§7.3) is where the transcript-correctness risk lives,
so it must be testable on any Mac — but `Transcript.Entry` is 27-only. The
resolution is a seam one notch down: the differ is a pure `nonisolated`
function over **LedgerKit-owned values** — ordered `(segmentID: String, text:
String)` pairs per snapshot — returning either the delta suffix or a typed
non-prefix verdict. The 27-gated driver's only diffing job is extraction:
map `Snapshot.transcriptEntries` (segment-aware, preferred) or flat `content`
(fallback, a single anonymous segment) into those pairs.

This is *not* the "internal imitation" M3's D11 retired — nothing here imitates
a protocol conformance; it is factoring pure logic out of platform types, the
same move as `Understudy`'s platform-agnostic engine. On a non-prefix verdict
the driver fails the generation loudly —
`.failed(.unrecognized("driver: non-prefix snapshot"))` — and never emits a
reconstructed delta: a wrong transcript is worse than a dead one, and rev 7
made this path load-bearing rather than defensive (`replaceTextSegment` is
legal provider behaviour).

### D35 — Normalization is per-family pure functions over both error families
One internal mapping per provider family (`Session/Normalize*.swift`), each a
pure `(any Error) -> GenerationError`, recognizing **both** families —
`LanguageModelError` and the deprecated-but-present iOS 26
`LanguageModelSession.GenerationError` (§8, rev 7) — plus the transport tail
(`URLError` → `.transport`), the three `Retry-After` forms (two RFC 9110 forms
and Apple's `resetDate`, all normalized to a duration *at normalization time* —
the clock read is legal here and forbidden in the reducer), and the busy-session
**exclusion** (`concurrentRequests` in either family lands as
`unrecognized("driver: session busy")`, never `.rateLimited`). Fixture-tested
per §10.5. **Open until Phase 0's reading session: whether Apple's error types
are publicly constructible for fixtures.** If they are not, the Apple-family
fixtures move to tier 2/3 (D36) and the gate says so — a fixture suite that
cannot construct its inputs on this machine is dormant, not green.

### D36 — Three test tiers, so "green" stays honest under the substrate constraint
- **Tier 1 — pure, any Mac:** the differ, normalization (constructibility
  permitting), `ToolRecordingPolicy`, transcript-*material* assembly logic that
  stays below FM types. Runs in every `swift test`, no gating.
- **Tier 2 — 27-gated integration:** `GenerationDriver` against
  `ScriptedLanguageModel` through a real `LanguageModelSession` —
  `@available`-gated, `.enabled(if:)`-gated, executed on whatever substrate
  Phase 0's spike finds (candidate: the iOS 27 simulator runtime via
  `xcodebuild test` through the workspace; the spike answers whether that works
  on a macOS 26 host). If no substrate exists, tier 2 is written and
  compile-verified, and every gate that depends on it **records "dormant" in
  this plan rather than claiming green** — the M3 `.enabled(if:)` posture,
  stated up front instead of discovered.
- **Tier 3 — device/manual:** the four §14 residues and anything needing Apple
  Intelligence eligibility. Phase 4; per-beta re-verification per the ROADMAP's
  beta track.

### D37 — The first `Understudy` import is a path dependency; packaging is flagged to M9
`LedgerKit/Package.swift` gains `.package(path: "../Understudy")` with the
product added to **the test target only** — the library target must never
depend on it. Priced consciously: **a path dependency is local-only.** It works
in this repo and the workspace, and it would break any consumer resolving
LedgerKit remotely — which is survivable today because **neither package is
remotely consumable anyway**: the repo root has no `Package.swift`, so a git
URL to this repo resolves nothing. That is an M9/0.1.0 packaging decision
(root manifest with both products vs. split repos), now recorded in §7's
handoffs rather than discovered at tag time. The path dep must be revisited as
part of whichever answer M9 picks.

---

## 4. Public-API ergonomics guardrails for M6

M5's guardrails carry forward (the §11 sketch is the acceptance test for shape;
labels get the M4-audit treatment at birth; no public memberwise inits on
derived state; `Sendable` cleanliness with no `@unchecked` in public API; doc
comments carry positioning). M6 adds:

1. **The public surface is small and named now:** `GenerationDriver` (the
   actor), `ToolRecordingPolicy` (struct-with-factories per D12:
   `.metadataOnly` default / `.full` / `.off` — ungated, it carries no FM
   types), and D32's policy construction. Everything else in `Session/` is
   internal. Anything further must argue its way in at a gate.
2. **Foundation Models never leaks out of `Session/`** — tenet 3's code form:
   no FM type in any signature outside the module's one OS-coupled corner, no
   re-export. Proposed enforcement (cheap, in the registry-test spirit): a
   tier-1 test that walks `Sources/` and asserts `import FoundationModels`
   appears only under `Session/`. Accept or drop at the Phase 1 gate.
3. **`GenerationError.unrecognized` values minted by the driver carry the
   `"driver:"` prefix** (§8's convention) — asserted structurally in tier-1
   tests, never by matching full prose (ADR-001).
4. **Availability attributes are part of the reviewed surface** (D31): a
   `Session/` declaration missing its gate is a build break on the floor we
   deliberately kept.

---

## 5. Phases

Phase 0 gates everything (the store must be clean and the substrate known).
Phase 1 is pure and independent of the SDK's runtime. Phases 2→3 build the
driver and prove it end-to-end; Phase 4 is the empirical evening(s); Phase 5
closes the milestone and ratifies rev 9.

---

### Phase 0 — Hygiene, the substrate answer, and the reading session

**Status:** ☑ **landed 2026-07-29** — 314 `LedgerKit` + 21 `Understudy` green,
both warning-free. Awaiting the review gate below.

**Goal:** the M5 audit's findings are fixed with tests; the two questions that
shape every later phase (execution substrate; Apple-error constructibility) are
answered; no Foundation Models code yet.

**Store fixes (from the boundary audit):**

- [x] **A1 — delete waits for the reservation to resolve.**
      `deleteConversation` currently waits only on `.running`; a `.reserved`
      slot lets the DELETE race the in-flight start append (either ordering
      leaves genesis-less rows or a terminal appended into an erased
      conversation — the exact artifacts the verb's own doc says cannot occur).
      Fix: after `cancelGeneration`, wait until the slot is not `.reserved`
      (the append is bounded — it confirms or rolls back), then take the
      existing `.running` wait. The reserved case thereby *converges* on the
      running case: the starter confirms, the recorded early-cancel fires, the
      terminal lands, the verb returns `.cancelled` (§9's contract, unchanged),
      and only then does the DELETE commit. Exact wait mechanism
      (yield-loop vs. parked continuations) is the implementer's; the test is
      not negotiable: `ParkingStore(parkingFirst: .append)` holds the start
      append open, a concurrent `deleteConversation` runs, and the assertions
      are **no row outlives the DELETE, no genesis-less row ever exists, the
      starter returns `.cancelled`, and the slot is released**. Mutation: revert
      to the `.running`-only wait — the new test must catch it.
      **Landed as specified.** Mechanism: `startWaiters` (per-conversation
      continuations) resolved by `confirm` *and* `release`, so a rolled-back start
      wakes its waiters too; `waitForStartToResolve(in:)` sits between
      `cancelGeneration` and the existing `.running` wait. Chosen over a
      yield-loop because a spin would burn the actor for the duration of the very
      append it is waiting on, *and* would leave the wait unobservable — the test
      must know the delete has reached the window rather than hope so, so
      `conversationsAwaitingStart` is exposed internally beside
      `liveGenerations`. Test:
      `StoreDeletionTests.deleteWaitsOutTheReservationWindow`. Mutation Ⓐ (drop
      the wait) **caught**, as a 60 s time-limit failure — and the pre-existing
      `deleteCancelsFirst` still passed under it, which is the proof that window
      really was uncovered.
      ⚠️ **Found while doing it:** a rendezvous spun on bare `Task.yield()`
      cannot be interrupted, so `.timeLimit` never fires and a broken subject
      wedges the whole run instead of failing one test (the first Ⓐ run had to be
      killed by hand). The harness helper `spin(until:)` checks cancellation for
      exactly that reason, and any future polling loop must too.
- [x] **A2 — close the rehydration gap.** The `rehydrationMaterial` read in
      `run` sits between `generate`'s rollback and `drive`'s
      `defer { release }`: a throw there wedges single-flight forever, and a
      task-cancel during it (reachable when a mid-flight `edit` racing the
      start commit lands the D29 eviction, making the read a real suspension)
      escapes as a **post-append `CancellationError`** — violating §7.2's
      straddle — with the generation left open and no terminal. Proposed fix:
      move the read inside the generation task (ahead of the channel setup in
      `drive`), so the release guard covers it and a cancellation there routes
      through the wind-down — terminal `generationEnded(.cancelled)` recorded
      outside the cancelled scope, verb returns `.cancelled`. A persistence
      failure there throws `persistenceFailure` with the generation left open
      (`.interrupted` on reload) — rev 8's "couldn't record" clause, already
      the contract. Side benefit: the reservation confirms immediately after
      the commit, shrinking D24's window to the append alone. Tests: both
      throw paths, each asserting the slot is released; mutation: restore the
      read to its old position — the wedge test must catch it.
      **Landed as proposed.** The read now sits under `drive`'s
      `defer { release }`, and `drive` takes `from parent:` instead of a
      pre-built request. The two dispositions differ and both are exercised:
      `catch is CancellationError` routes to the wind-down, everything else
      propagates. The wind-down itself is now **one** helper,
      `windDown(_:in:flushing:as:)`, shared with the ordinary terminal path — two
      copies of "flush, then terminal" is exactly how §7.4's non-optional
      pre-terminal flush would get forgotten on the second path. Tests:
      `StoreRehydrationGapTests` (both throw paths, both asserting the slot frees);
      the *only* way to reach a cold read at that moment is to inject D29's
      eviction, since a warm cache reads nothing — racing a real `edit` would
      test the scheduler instead. New double: `ReadHostileStore` (gated `events`
      failures). Mutations: Ⓑ (release guard installed after the read) caught by
      **both** tests, reporting `generationInFlight` — the wedge, named; Ⓒ (drop
      the cancellation conversion) caught with `Caught error: CancellationError()`,
      **which is the evidence GRDB really does throw from a read inside a
      cancelled task** — without it the new branch would have been unreachable
      decoration rather than a fix.
- [x] **B1 — rewrite the throw-channel docs to rev 8's contract.** Four sites:
      `LedgerError`'s type doc ("a throw means the log is untouched" — only
      true pre-append), `persistenceFailure`'s "Nothing was recorded",
      `ConversationStore`'s headline doc, and `send`/`respond`'s `- Throws:`
      prose. The rewritten docs state both halves: pre-append (log untouched)
      and post-start couldn't-record (start and flushed deltas persist, no
      terminal, reduces `.interrupted` — the recovery UX already handles it).
      **Verification: grep `Sources/` for the retired phrasing** ("never
      started", "log is untouched", "Nothing was recorded") — the mechanism the
      CLAUDE.md sweep rule now names.
      **Done; all four rewritten.** The grep found **nine** hits and only four
      were stale — the other five are true statements about other subjects
      (`append`'s all-or-nothing *batch*; a **generation** that never started, in
      `QuarantineReason`; a failing-store test's own log-untouched assertion). So
      the mechanism finds *candidates*; judgement closes them, and the sweep rule
      should be read that way. One refinement worth keeping: the corrections
      **paraphrase** the retired wording instead of quoting it, because a
      correction quoting the sentence it replaces would make every future sweep
      report the very site already fixed.
- [x] **D32 — public policy construction** (shape decided at this gate; doc
      comments carry the disk-vs-display cadence positioning; the two
      `ConversationStore.init` parameters stop being decorative).
      **Landed as named factories, not public memberwise inits** —
      `DeltaFlushPolicy.flushing(every:orAfterCharacters:)` and
      `SnapshotPolicy.refreshing(afterEachGeneration:orAfterEvents:)`, inits
      staying internal. The deciding argument is that the phrasing carries the
      **or** semantics: `init(interval:characterCount:)` leaves a reader guessing
      whether both bounds must be met, where "every 100 ms or after 128
      characters" cannot be misread. `afterEachGeneration: false` covers D32's
      floor-only shape (what a bulk importer wants) without a separate factory.
      The three test sites that vary these now construct through the public
      spelling, so the *behavioural* suites cover it and `APISketchTests`
      only has to assert the shape.
- [x] **D31 — fix the `Package.swift` comment** (floor stays 26; `Session/` is
      gated; bumping would strand the suite on this machine).
      Done, and it now also records the simulator invocation, since that is the
      thing a reader tempted by a floor bump actually needs.

**Staleness batch (audit finding C — mechanical): all done.**

- [x] ROADMAP header line: rev 8 is **ratified** (2026-07-28); amendments open
      rev 9. (The M5 section already says so; the header disagrees.)
- [x] `Store/Persistence.swift`: "Nothing here is wired until M4" (it was, two
      milestones ago); "Maps to … at M4"; the `.sqlite(at:)` doc justifying
      itself against a §11 sketch that rev 8 already fixed. All three replaced
      with what is now true (the one conformance, the queue/pool split, and rev
      8's agreement on the label).
- [x] `Store/Policies.swift`: the two "Phase 3's review gate" forward
      references — resolved by D32 landing. The file header now argues the
      *decision* instead of deferring it, and the two internal-init rationales
      were corrected too: they claimed the inits existed for tests, which stopped
      being true the moment the tests moved to the public factories.
- [x] ADR-001 R-5: "The store's stamping site lands at M5" → landed. Now names
      `ConversationStore.mint(_:in:)` and restates why `append` asserts rather
      than repairs.
- [x] ADR-003's dangling "revisit at M5" (file protection): roll forward
      explicitly to M9 hardening with one sentence, so the deferral is a
      record rather than a memory. Recorded *with the reason M5 changed nothing*:
      both gaps are properties of where the app put the file, not of who opens
      it, so owning creation end-to-end did not touch them.
- [x] SPEC §7.7's `TokenUsage` cross-reference nit → **not** edited now; it is
      §6 inventory item 5 (SPEC edits open rev 9 and need approval). Confirmed
      still deferred; SPEC.md is untouched by this phase.

**The two questions — both answered; see §2a below for the findings.**

- [x] **Substrate spike:** can the iOS 27 simulator runtime execute the
      `.enabled(if:)`-gated tests on this macOS 26 host — e.g. `xcodebuild
      test` against an iOS 27 simulator destination, through the workspace or
      per-package? Record the exact working invocation, or the failure, in this
      plan. This decides whether tier 2 is *live* or *dormant* for the rest of
      M6.
      ### ✅ **TIER 2 IS LIVE.** All 310 tests ran on the iOS 27.0 simulator
      (`** TEST SUCCEEDED **`, 1.7 s) via:
      ```bash
      xcodebuild test -workspace LedgerKit.xcworkspace -scheme LedgerKit \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'
      ```
      The runtime `iOS 27.0 (24A5390f)` is installed; the auto-generated package
      scheme builds the test target with `-sdk iPhoneSimulator27.0.sdk -target
      arm64-apple-ios26.0-simulator`. **The mechanism is why D31 and D36
      reinforce each other rather than trade off:** the *deployment target* stays
      26, so the same sources still launch on the macOS 26 host, while the
      *runtime* is 27, so `#available(iOS 27, *)` succeeds and gated bodies
      execute. One test target serves both tiers, and no gate in Phases 2–3 has
      to be recorded dormant. Invocation duplicated into `LedgerKit/Package.swift`
      beside the floor comment, where someone tempted to bump the floor will see
      it. (`xcodebuild -list` prints "Supported platforms … is empty" — noise from
      the generated scheme, not a failure; ignore it.)
- [x] **Reading session** (extend M4-PLAN §2's table; re-read citations before
      depending on them): Apple error **constructibility** for §10.5 fixtures
      (`LanguageModelError` cases and payload structs; the deprecated 26
      enum); `LanguageModelSession` streaming call signatures and options;
      `isResponding`'s exact surface; `Transcript` entry construction for
      materialization (`Instructions`/`Prompt`/`Response` — rev 7 confirmed
      the tool/reasoning entries; confirm the three M6 actually needs);
      `Sendable`/isolation annotations on session and model types (drives
      D33's actor shape); `LanguageModelCapabilities` interaction if any.
      **Done — findings in §2a.** Every question answered by reading, none by
      running, which is now three milestones of the same lesson.

**Review gate:** both suites green with the new tests (count recorded in §10);
mutations run and caught; D31/D32 signed off with final spellings; the
substrate answer and reading-session findings written into §2; no retired
phrasing greps back.

**Gate state (for review, 2026-07-29):** ✅ 314 + 21 green, both packages
warning-free, and the 314 also pass on the iOS 27 simulator. ✅ Three mutations
run (Ⓐ, Ⓑ, Ⓒ), all caught, all reverted. ✅ Retired-phrase grep clean of stale
sites (nine hits, five legitimately unrelated — see B1). ✅ Substrate and
reading-session findings recorded in §2a. **Awaiting sign-off on:** D32's final
spelling (named factories — the two-line argument is under D32 above); D33–D37
promotion from Proposed to Accepted, all five now with evidence rather than
expectation; and the two rev 9 inventory additions (items 8–9).

---

### Phase 1 — Pure components (tier 1: any Mac, no FM import)

**Status:** ☑ **landed 2026-08-01** — 380 green (359 `LedgerKit` + 21
`Understudy`), warning-free. Four mutations run and caught. **One deviation from
the phase title, recorded below: this phase does import Foundation Models**, and
the reason is a Phase 0 finding rather than a slip.

**Goal:** the two riskiest driver obligations — diffing and normalization —
exist as pure, exhaustively-tested components before a session ever runs.

- [x] **The differ (D34).** Input: consecutive snapshots as ordered
      `(segmentID, text)` pairs (flat-content mode = one anonymous segment).
      Output: the delta suffix per snapshot, or a typed non-prefix verdict.
      Covered shapes: growth within a segment; a new segment opening; **segment
      revision** (the `replaceTextSegment` analogue) → non-prefix; segment
      removal → non-prefix; reordering → non-prefix; interleaved multi-segment
      growth; the empty-snapshot edges. Property: over any well-behaved
      sequence, the concatenated deltas equal the final text — which is
      exactly the store-side half of §7.3's round trip, proved before the
      framework is in the loop.
      **Landed as `Session/SnapshotDiff.swift`** — `StreamSnapshot` (named away
      from `Store`'s `Snapshot`, which is a persisted checkpoint), `SnapshotDelta`
      with a typed `Reason`, and a free `delta(from:to:)`. Nineteen tests; the
      property sweeps all 126 append-only shapes of length ≤ 6 exhaustively.
      **Two findings the plan's shape list did not name:**
      ① ⚠️ **`interiorGrowth` — a fifth non-prefix shape.** A segment growing
      while a *later* segment already holds text is a legal per-segment append
      and an illegal *ledger* one: message content is the concatenation of
      `deltaAppended` rows in order, so that text would have to be **inserted**
      mid-string. The plan listed "interleaved multi-segment growth" among the
      shapes to *support*, and it is supportable only in the tail; the general
      case has to be refused. The flat view reaches the same verdict by a shorter
      route, which is the cross-check that the rule is right rather than
      invented.
      ② ⚠️ **The prefix test must compare UTF-8, not `Character`s.** `hasPrefix`
      compares grapheme clusters under canonical equivalence, so a provider
      emitting `"e"` and then a combining acute reads as having *revised* its
      segment — `"e"` is not a grapheme prefix of `"é"` — and the driver would
      fail a perfectly well-behaved generation. Bytes see the append that
      happened, and they also make `previous + delta == current` an exact
      equality, which is what §7.3's round-trip property needs. Mutation Ⓔ
      (revert to `hasPrefix`) is caught by the combining-mark test.
      Mutation Ⓓ (drop the interior-growth check) is caught **twice** — by its
      unit test and, independently, by the exactness property, which is the
      result worth having: the property catches violations nobody enumerated.
- [x] **Normalization cores (D35)** as pure functions with §10.5 fixture
      suites for everything constructible on this machine today: `URLError` →
      `.transport(…)`; HTTP-shaped provider failures → `providerFailure` with
      the lift rules (429 → `.rateLimited` parsing both RFC 9110 `Retry-After`
      forms; 408 → transport); the `resetDate` instant→duration conversion;
      the busy-session exclusion. Apple-family fixtures per Phase 0's
      constructibility answer — landed here if constructible, tiered honestly
      if not.
      **Landed as two files, split by what needs Foundation Models.**
      `Session/Normalization.swift` is FM-free (the `ProviderFault` lift rules,
      all three `Retry-After` forms including both obsolete RFC 9110 date
      formats, `URLError` bucketing, and `DriverDiagnostic` — one type so §8's
      `"driver:"` prefix has a single enforcement point instead of a literal per
      site). `Session/NormalizeAppleErrors.swift` imports FM and is **un-gated
      with `#available` inside**, which is what puts half of it in tier 1.
      **Every fixture asserts both layers** (§10.5): the normalized
      `GenerationError` *and* the `Recoverability` it classifies to, because a
      plausible-looking normalization can still hand the user the wrong
      affordance — a 429 landing as `providerFailure(status: 429)` classifies
      `retryable(nil)` and silently discards the wait the provider reported.
      ⚠️ **Two more Apple error families, neither mentioned in §8** — found by
      following the deprecated family's own deprecation notes:
      **`SystemLanguageModel.Error`** (`assetsUnavailable`) and
      **`PrivateCloudComputeLanguageModel.Error`** (`networkFailure`,
      `quotaLimitReached` — which carries a `resetDate`, Apple's third
      `Retry-After` form again — and `serviceUnavailable`). With the deprecated
      family's two unaccounted cases that is **four** families and seven mappings
      §8's coverage table does not state, all now mapped by §8's *existing* rules
      and flagged for rev 9 (inventory item 8). Mutation Ⓖ (map
      `concurrentRequests` to `.rateLimited` — the exact historical mistake §8's
      exclusion exists to prevent) caught by all three of its assertions.
- [x] **`ToolRecordingPolicy`** (`Session/ToolRecording.swift`, ungated —
      no FM types): `.metadataOnly` default / `.full` / `.off`, struct with
      factories per D12, doc comments carrying §7.6's privacy rationale.
      Landed with `recordsInvocations` / `recordsPayloads` as the internal
      readers Phase 2 switches on, so the driver never re-derives the policy's
      meaning from its cases.
- [x] **The import-boundary test** (guardrail 2) — accept or drop here.
      **Accepted**, and it grew a second half: one test greps `Sources/` for
      `import FoundationModels` outside `Session/`, the other for *uses* of
      Apple's inference type names in code (comments excluded — §7's design is
      documented in prose that names them constantly). Both carry vacuity guards,
      because a walk that found nothing would satisfy "no offenders" perfectly
      while checking nothing — the `InvariantCheckTests` discipline applied to a
      source sweep. Mutation Ⓕ (add the import to `Core/ToolRecord.swift`)
      caught.

**Review gate:** tier-1 suites green on macOS 26; the differ's property test
swept; fixture inventory reviewed against §10.5's list; no `Session/` file yet
imports FoundationModels except none (nothing 27-gated has landed).

**Gate state (for review, 2026-08-01):** ✅ 359 + 21 green, warning-free, on both
substrates — and on the simulator the six 27-gated tests **execute** rather than
skip, which is D36's tier 2 delivering on its first real use. ✅ Four mutations
(Ⓓ Ⓔ Ⓕ Ⓖ), all caught, all reverted. ✅ §10.5's inventory covered for every
family constructible today, both layers asserted.

**Deviation to sign off:** the gate line above says no `Session/` file imports
FoundationModels in this phase, and one now does. That line was written when tier
2 might have been dormant; Phase 0 found the deprecated 26 family is available at
26 and the simulator runs the rest, so deferring the Apple mappings to Phase 2
would have split §8's "one mapping per family" across two phases and left the
tier-1 half untested for no benefit. The *principle* the line protects —
Foundation Models stays inside `Session/` — is now enforced mechanically by the
import-boundary test rather than by a phase boundary, which is strictly stronger.

---

### Phase 1.5 — The SDK surface sweep, and a tripwire for beta churn

**Status:** ☑ **landed 2026-08-01** — 387 green (366 + 21) on both substrates.
Unplanned; opened because Phase 1 found two error families by accident and the
question "how many more are there?" had no answer.

**Why it exists, stated once because the diagnosis generalizes.** The gaps were
not sloppiness. Rev 6 asked *"what are `LanguageModelError`'s cases?"* and
answered it correctly — but §8 makes a claim one size larger ("a **total**
normalization of Apple's built-in taxonomy"), and totality needs the answer to
*"what can be thrown at a driver?"*. Nobody asked the larger question. **The gap
is exactly the delta between the question asked and the claim it supported**,
which is a repeatable mistake and therefore worth a mechanism rather than more
care.

- [x] **The sweep.** Every public `Error`-conforming type in the interface:
      **nine**, of which §8's coverage table names one. Five are driver-reachable
      and four are not.
      ⚠️ **It found a sixth family within minutes: `LanguageModelSession.ToolCallError`**
      — 26-available, carrying `tool` and `underlyingError`, and thrown when an
      app-supplied tool fails *during* a generation. It is the one unhandled type
      that plainly reaches running code (§7.6 is entirely about tools), and no
      earlier read had any reason to look at it. Normalized by **unwrapping**:
      the wrapper says *where* the failure happened, not what it was, and a tool
      whose network call timed out should give the user a Retry rather than an
      opaque tool-shaped mystery. Nothing is lost, because "a tool failed" already
      has its own channel — §7.6's `toolInvocationRecorded` with a `.failed`
      status. Unwrapping is **bounded**, since the payload is `any Error` and the
      initializer is public.
- [x] **The manifest** (`AppleErrorSurfaceTests.swift`): every error type with
      LedgerKit's **disposition** — normalized, or unreachable *with the reason*.
      Recording the exemptions is the point: "we decided this cannot arrive" and
      "we never noticed this" look identical in a list that holds only what it
      handles. Compared against the installed interface on every run, so **a beta
      that adds an error type fails a test** instead of waiting to be found by
      luck (mutation Ⓗ). Same move as ADR-001 D-3's registry: a rule nobody can
      quietly break beats a rule somebody read once.
- [x] **Pinned declarations** — the sweep's second question, *what does Phase 2
      consume?* `Transcript.Entry` (6), `Transcript.Segment` (4), and the
      channel's response actions (7). `Entry` earns its place by history: the M3
      audit recorded it gaining a seventh case when `Segment` was what grew, and
      that misreading survived into a fact table. The channel actions earn theirs
      because `replaceTextSegment` appearing there is what withdrew §7.3's prefix
      guarantee at rev 7 — a new action is the same class of event (mutation Ⓘ).
- [x] **The SDK build is pinned** (`26A5388f`). The ROADMAP promises "one
      verification evening per beta", which is a discipline, and disciplines get
      skipped in busy weeks. Now the *toolchain moving* is the failing condition,
      so the evening is scheduled by CI rather than by memory. The fix is one line
      **after** re-running the checks — trivial edit, non-trivial re-verification,
      deliberately bundled so the second cannot be skipped while the first is done.

**Landed with the sweep, from the review that followed it:**

- [x] **CI exists** (`.github/workflows/ci.yml`) — **the battery for the smoke
      alarm.** Every tripwire above is useless unless something runs it when
      *nothing in this repo changed*, which is precisely the shape of a beta
      drop. Two jobs (host suites; the whole suite on the iOS 27 simulator), a
      **weekly `schedule:` trigger**, and capability checks that **fail rather
      than skip** — a green run has to mean the suite ran, which is the same
      honesty rule `.enabled(if:)` buys the gated tests. ⚠️ Hosted runners ship
      released Xcodes and may not carry a beta; `vars.CI_RUNNER` switches to a
      self-hosted label, and the dev machine has the toolchain by definition.
      **A bug the first draft had, caught by running the script rather than
      reading it:** selecting Xcode by "does FoundationModels' interface exist"
      matches **Xcode 26 too** — the framework shipped in the 26 SDK; what M6
      needs is the 27 API inside it. Selection is by SDK *version* now.
- [x] **`Understudy` can revise a segment** — `Script.Step.revise(_:segmentID:
      tokenCount:)`, and `emit` gained an optional `segmentID` so a script can
      address one twice. Apple's channel has offered `replaceTextSegment` since
      27 and the double could only ever `appendText`, so **§7.3's fail-loud path
      had no way to be exercised end-to-end** — Phase 3 could not have driven a
      revising stream through a real session. Understudy's own `Step` doc already
      argued the principle for usage ordering ("a double that cannot express a
      misbehaving provider cannot test a driver's response to one"); this applies
      it where the spec actually needs it. `RecordingSink` now models per-segment
      accumulation, because a sink that only appended would report the
      *provider's* history rather than the consumer's view — and a revision is
      exactly the case where those two stop agreeing.
- [x] **Unmapped Apple cases are self-identifying.** The `@unknown default` arms
      mint `unrecognized("unmapped <Type> case: …")` rather than a bare
      description, so a log reaching triage distinguishes "Apple grew a case"
      from "some third-party error nobody has seen" — different owners, different
      fixes, and by then the type is long gone. No `"driver:"` prefix: §8 reserves
      that for LedgerKit's own invariants, and this is a mapping gap rather than a
      defect in how the driver behaves.
- [x] Removed the stale `LedgerKitTestSupport/` directory at the repo root —
      untracked build detritus under the pre-M4 package name.

**Two findings worth carrying:**

1. ⚠️ **`GenerationID` collides with `FoundationModels.GenerationID`, and it
   lands on *consumers*.** `@Generable` expands to code naming `GenerationID`
   unqualified, so any file importing both LedgerKit and FoundationModels fails
   to compile with an error pointing into an expansion the author never wrote.
   `@Generable` is the ordinary way to declare tool arguments, so this is a real
   collision, not a test artifact. Workaround is to keep `@Generable` types in a
   file that does not import LedgerKit (which is what `ToolStub.swift` does, and
   says). **Recorded for M9's naming review** — renaming a core public identifier
   (ADR-002) is not a decision to take in passing.
2. **The simulator tier caught host-only API in *test* code.** `Process` does not
   exist on iOS, so `AppleErrorSurfaceTests` failed to build there — found by the
   substrate run, not by review. Tier 2 is not only where 27-gated tests execute;
   it is the only place this class of mistake fails at all.

**Review gate:** ✅ both substrates green; four mechanisms in place (error
surface, consumed declarations, SDK build, and Phase 1's import boundary); three
mutations (Ⓗ Ⓘ, plus Ⓕ from Phase 1) caught. **The honest limit, stated so it is
not mistaken for coverage:** all of this sees *shape*, never *behaviour*. Thrown
versus trapped, whether real providers revise segments — §14's residues remain
empirical and Phase 4's.

---

### Phase 2 — The driver (tier 2 code: 27-gated, compile-verified always)

**Status:** ☐ not started

**Goal:** `Session/GenerationDriver.swift` — the one production conformance.

- [ ] The actor (D31 gating, D33 shape): holds the `any LanguageModel`, the
      app-supplied descriptor, the `ToolRecordingPolicy`; `nonisolated let
      model: ModelDescriptor`.
- [ ] **Init spelling** (gate item): `init(model:descriptor:toolRecording:)`
      as the general form; decide whether a `SystemLanguageModel` convenience
      may default the descriptor (keeps §11's sketch line true) or the sketch
      moves instead — either way, §6 item 3 records it for rev 9.
- [ ] **Rehydration** (§7.1): `GenerationRequest` → `Transcript` — instructions
      entry (exact), prompt/response entries from `context` in path order,
      **partials included** (what the user saw is what the model sees); tool
      entries and reasoning deliberately absent (N11, §7.1 fidelity classes).
      Fresh session per generation (D33) via the OQ1 initializer.
- [ ] **The outcome boundary** (§7.2): `isResponding` gate before issuing
      (busy ⇒ `.failed(.unrecognized("driver: session busy"))` — a driver
      defect, never a provider signal); every thrown provider error →
      normalize (D35) → `.failed(…)`; zero-token request-time failures land as
      `.failed` with an empty partial already recorded store-side; **the call
      itself never throws** (the protocol's grammar).
- [ ] **The streaming loop** (§7.3): consume the response stream's cumulative
      snapshots; extract differ input (segment-aware via `transcriptEntries`,
      flat-content fallback); `channel.emit(.delta(suffix))` per snapshot;
      non-prefix verdict ⇒ terminal
      `.failed(.unrecognized("driver: non-prefix snapshot"))`.
- [ ] **Cancellation** (§7.5): task cancellation reaches the session call; the
      driver drains what it has, emits nothing after the fact, and **returns**
      `.cancelled`. No cleanup writes exist on this side of the seam to trip
      the M5 wall — assert the shape anyway with a parked cancellation test.
- [ ] **Usage & identity capture** (§7.7–7.8): final usage → `TokenUsage`
      (1:1 table); `stopReason`/`resolvedModelID` from provider metadata
      conventions where present — **nil expected on-device, never an error**.
- [ ] **Tool records** (§7.6): observe `toolCalls`/`toolOutput` transcript
      entries mid-stream, pair them, and emit one `ToolRecord` per completed
      invocation (name, status, duration; arguments/result only under
      `.full`). Record, don't orchestrate.

**Review gate:** both packages compile warning-free under strict concurrency
with the floor unchanged; the conformance reviewed line-by-line against §7.9's
ownership table (nothing store-owned crept driver-side); tier-2 tests written
and gated; executed now if Phase 0's substrate is live, recorded dormant if
not.

---

### Phase 3 — End-to-end: Understudy through a real session

**Status:** ☐ not started

**Goal:** the whole pipeline — scripted provider → framework accumulation →
driver → store → reducer — asserted as one property, plus the driver-side
chaos suite.

- [ ] **The first `Understudy` import** (D37): path dependency, test target
      only.
- [ ] **The §7.3 round-trip property** (M5 handoff 3): scripted fragments →
      `ScriptedLanguageModel` → real session accumulation → snapshots → differ
      → `deltaAppended` rows equal the script's fragments exactly. Under
      injection (`ScriptedIdentifiers` + `SteppingClock`) the whole run is
      byte-stable — the corpus gains this fixture **now** (`Log.isStoreReplayable`
      qualifying, or its exclusion stated), and it inherits truncation/gap/P3
      coverage for free.
- [ ] **Driver chaos via `Cue`** (the inversion): the *player* parks at scripted
      cues; the test drives `reached()`/`signal()`; cancellation at every
      parked point × both stop mechanisms, partial retention asserted at each —
      §10.4's suite, now with the real session between the script and the
      store.
- [ ] **The §11 sketch against the real driver**: a 27-gated sibling of
      `APISketchTests` running the sketch end-to-end with `GenerationDriver` +
      `ScriptedLanguageModel` — the store-double sketch stays as the any-Mac
      version. This is DoD-2's groundwork: the driver-init line is the one
      line a provider swap changes.
- [ ] **The healthy-log property spans driver-produced logs**: every log the
      real pipeline writes reduces with empty diagnostics.

**Review gate:** tier-2 suite green on the substrate (or the dormant record,
honestly); the round-trip property *is* the "real stream captured & reduced"
exit criterion; corpus addition reviewed per `Corpus/README.md`.

---

### Phase 4 — The residues and provider breadth (tier 3)

**Status:** ☐ not started

**Goal:** the four questions only running code answers, plus the second
provider family. Requires hardware/eligibility; every deferral is recorded, not
implied.

- [ ] **Land the residues as an env-flagged *suite*, not as notes** (§10.7's
      "device integration behind an env flag"; added at Phase 1.5's review).
      Each of the four below becomes a test gated on
      `.enabled(if: ProcessInfo.processInfo.environment["LEDGERKIT_DEVICE"] != nil)`
      — skipped everywhere else, honestly, exactly as the 27-gated tier is.
      **The reason is beta churn, not tidiness.** An answer written into a
      document is true on the day it is written and decays silently; an answer
      written as a test re-asks its question every time the suite runs, which is
      what the rest of Phase 1.5 bought for *shape* and this buys for
      *behaviour*. A residue that flips at Beta 6 — `concurrentRequests` becoming
      a trap, say — would otherwise be found by a user.
- [ ] **`concurrentRequests`: thrown or trapped?** (OQ6 residue). Thrown ⇒ the
      gate + normalization exclusion stand as designed. Trapped ⇒ the
      `isResponding` gate is promoted from defence to *the only* protection,
      §7.2's wording changes, and the gate gains a test proving it prevents
      the second issue rather than reporting it.
- [ ] **Do real providers revise segments?** (OQ4 residue). Observe on-device
      output for `replaceTextSegment` on plain text. Either answer feeds §7.3:
      "never observed" keeps the fail-loud path as insurance; "observed" makes
      segment-aware diffing mandatory prose rather than preference.
- [ ] **Is `Usage.Input.totalTokenCount` inclusive of `cachedTokenCount`?**
      (§7.7 residue). Decides whether apps may sum; recorded in §7.7 either
      way.
- [ ] **The real on-device context budget** (N3's ⚠️). Replaces the "~4k
      reported" hedge with a measured number and sizes how soon rehydration
      overflows after process death.
- [ ] **Claude-package normalization family** (§10.5) if the package is
      obtainable in the current beta ring; otherwise invoke cut line 4 (§12)
      explicitly and ship on-device + deprecated-26-family mappings. The
      deprecated-family fixtures land regardless (constructibility permitting —
      Phase 0's answer).

**Review gate:** each residue has an answer or a recorded deferral naming what
unblocks it; anything that changes spec text is in §6's inventory with its
proposed wording.

---

### Phase 5 — Wrap-up: rev 9 ratification + alignment

**Status:** ☐ not started

- [ ] Draft §6's rev 9 items to a scratch file; item-by-item sign-off; land in
      SPEC as Appendix G; **ratify rev 9 at the boundary**.
- [ ] Alignment: ROADMAP M6 struck through against its exit criteria;
      CLAUDE.md status rewritten with the M6 landmarks; the `Sources/**`
      sweep **including the retired-phrase grep for every rev 9 amendment**
      (the mechanism B1 proved necessary); this plan's §8 filled; §9/§10 logs
      closed.
- [ ] Handoffs to M7/M8/M9 (§7) verified against what actually landed.
- [ ] Both suites green, warning-free; counts in §10.

---

## 6. Rev 9 inventory (amendments M6 expects — draft at Phase 5, not from memory)

Collected from the M5 boundary audit (items 1–5) and M6's expected findings.
Extend as phases surface more; the M4/M5 pattern.

1. **§9/§7.5 — delete resolves reservations.** One mechanism sentence, the way
   rev 8 stated the cancellation-recording rule: a verb that erases or
   overrides a generation must wait for a *claimed-but-unconfirmed* start to
   resolve, or the DELETE races the start transaction it cannot see (audit A1;
   Phase 0's fix).
2. **§7.2 — the straddle covers the whole post-append region**, including
   store-side reads between the start append and the driver launch: a
   cancellation there is still "post-append ⇒ returns `.cancelled`" (audit A2;
   Phase 0's fix makes it true).
3. **§11 sketch refresh**: the store's one read verb `conversation(_:)`
   appears; the driver-init line gains its descriptor story (OQ8 made the
   descriptor app-supplied — Phase 2 decides the convenience-vs-required
   spelling).
4. **§7.4/§9 — configurability is now real** (D32): sketch shows the public
   construction if the wording warrants it; otherwise no text change needed —
   the spec already promised it and the code now delivers.
5. **§7.7 — `TokenUsage` cross-reference nit**: the mapping table cites
   "(§6.1)" for a type §6.1 never shows.
6. **§14 — the four residue answers written back** (Phase 4), each into the
   section it changes (§7.2, §7.3, §7.7, N3).
7. Anything Phases 2–4 surface that changes a §7 sentence — logged here as
   discovered.
8. **§8 — Apple ships four error families, and the coverage table names one.**
   Opened by Phase 0's reading session and **widened at Phase 1**, where
   following the deprecated family's own deprecation notes turned up two more
   types. §8 claims *totality* over Apple's taxonomy and states it as a
   checkable table, so every row below is either in that table or a silent
   fall-through to `unrecognized` — which is exactly the defect rev 6 fixed for
   the four `unsupported*` cases. All seven are implemented and fixture-tested as
   of Phase 1, each by an **existing** §8 rule rather than a new one; what rev 9
   owes is the table rows.
   - `LanguageModelSession.GenerationError.assetsUnavailable` (26) and
     `SystemLanguageModel.Error.assetsUnavailable` (27, its named replacement) →
     **`modelUnavailable(.modelNotReady)`**, the landing §8 already gives PCC's
     `systemNotReady`, classifying `recoverableUpstream(.awaitModelDownload)`.
   - `LanguageModelSession.GenerationError.decodingFailure` (26) →
     **`providerFailure(status: nil, code: "decodingFailure")`**, §8's rule-4
     tail. Guided generation is outside v0.1 (N8), so there is no 1:1 home and
     rule 1 does not apply; `terminal` is right because retrying the same
     request cannot fix a decode failure. Apple's `debugDescription` is
     deliberately not carried into `message` — §8 declines to project debug
     detail, and the ledger outlives the session.
   - `LanguageModelSession.Error.transcriptMutationWhileResponding` (27) → the
     **`"driver:"` floor**, beside `concurrentRequests`. §8 already says this is
     "a LedgerKit bug by construction" but gives it no landing.
   - `PrivateCloudComputeLanguageModel.Error` (27) — a family §8 mentions only
     for its *availability* reasons: `networkFailure` →
     **`transport(.connectivity)`**; `quotaLimitReached` →
     **`rateLimited(retryAfter:)`**, since it carries a `resetDate` — the same
     instant-shaped `Retry-After` as `LanguageModelError.RateLimited`;
     `serviceUnavailable` → **`providerFailure(status: nil, code:)`**. The last
     is the one §8 anticipated in prose: "if a provider family turns out to emit
     nil-status transients, that's a mapping override keyed on `code`" — so the
     honest landing is `terminal` with a stable code rather than a 503 the
     provider never sent.
   - **`LanguageModelSession.ToolCallError`** (26, found by Phase 1.5's sweep) →
     **unwrapped to its `underlyingError`**, which is the only family member that
     is a *wrapper* rather than a condition. §8 has no rule for wrappers; the
     rev 9 text should say that a wrapper is transparent to normalization,
     because the fact it adds ("a tool failed") is recorded on §7.6's own channel
     and would otherwise be stated twice, in two vocabularies, with only one of
     them classifiable.
9. **§7.2 — the throw/return boundary covers store-side *reads*, not just
   appends** (audit A2's fix, generalized). The straddle is currently written in
   terms of the start append; Phase 0 made a cancellation during the *rehydration
   read* return `.cancelled` with a recorded terminal. Overlaps item 2 and should
   probably land as one sentence with it.

---

## 7. Explicit handoffs (recorded so they aren't lost)

**To M7 (projection + `overlay_live`)** — unchanged from M5's list, restated so
this plan is self-contained:
1. `ConversationStore.liveGenerations` is the overlay's input (keyed by
   `GenerationID`; P2's live ⊆ open already tested). M7 passes the real
   overlay to `ProjectionChecks.swift` and changes no assertion.
2. `conversationList` via the seam's `conversationSummaries` + GRDB value
   observation surfaced as an `AsyncSequence`.
3. Display cadence ≠ flush cadence; the app's `RecoverabilityMapping` override
   rides the projection.
4. The Playground still hand-builds a tree and needs `@testable` — fix in
   Xcode at M7 (inherited M4 → M5 → here).

**To M8 (the demo):** DoD-2's one-line provider swap is the
`GenerationDriver` init line — Phase 3's 27-gated sketch test is its proof
shape. Kill-mid-stream (DoD-1) needs only what M6+M7 ship.

**To M9 (tag `0.1.0`):**
1. ⚠️ **The packaging question, now load-bearing** (D37): the repo root has no
   `Package.swift`, so neither package is consumable from a git URL today, and
   M6 adds a local path dependency (LedgerKitTests → Understudy) that must
   dissolve into whatever 0.1.0 ships — a root manifest exposing both products,
   or split repos. Decide deliberately; the path dep is the forcing function.
2. ADR-003's file-protection revisit (rolled forward from M5 at Phase 0).
3. ADR-001 ratifies at M9 as planned; nothing M6 does should touch the wire.
4. The ENHANCEMENTS backlog (`MessageTree` traversal, DocC, third-party driver
   testability) remains priced and parked.

---

## 8. Coverage traceability (fill at Phase 5)

| Obligation | Suite / evidence | Status |
|---|---|---|
| A1: delete during the reservation window | `StoreDeletionTests.deleteWaitsOutTheReservationWindow` + mutation Ⓐ (caught as a time-limit failure) | ☑ |
| A2: rehydration gap (wedge + post-append cancel) | `StoreRehydrationGapTests`, both throw paths + mutations Ⓑ and Ⓒ | ☑ |
| B1: throw-channel docs match rev 8 | four sites rewritten; grep clean of stale hits (five unrelated, triaged in Phase 0) | ☑ |
| D32: policy knobs publicly constructible | `APISketchTests.policiesAreConfigurable` for shape; `StoreFlushTests` / `StoreSnapshotRefreshTests` now construct through the public factories, so behaviour is covered by the suites that already assert it | ☑ |
| Differ: prefix property + non-prefix verdicts | `SnapshotDiffTests` — 19 tests; exactness swept over well-behaved *and* hostile pairs; 126-shape exhaustive property; mutations Ⓓ Ⓔ | ☑ |
| Normalization: §10.5 fixtures, both families, lift rules, busy-session exclusion | `NormalizationTests` (tier 1: rules, `URLError`, the deprecated 26 family) + `AppleErrorNormalizationTests` (tier 2: all four 27 families, **executed** on the simulator). Both layers asserted per fixture; mutation Ⓖ | ☑ |
| §7.3 round-trip: script ≡ recovered deltas | tier-2 property, corpus fixture | ☐ |
| §11 sketch runs against the real driver | 27-gated sketch test | ☐ |
| Cancellation chaos through the real session | `Cue`-parked suite × both stop mechanisms | ☐ |
| `isResponding` gate; "driver:" prefix convention | tier-1/2 per surface | ☐ |
| Four §14 residues answered or deferred-with-reason | Phase 4 record + §6 items | ☐ |
| FM import boundary (guardrail 2) | `ImportBoundaryTests` — imports *and* type names, both with vacuity guards; mutation Ⓕ | ☑ |
| Healthy-log property over driver-produced logs | Phase 3 suites | ☐ |

---

## 9. Decision log

| # | Decision | Status |
|---|---|---|
| D30 | M6 opens with the audit hygiene phase; every fix lands with its test | **Accepted** 2026-07-28 · **discharged** 2026-07-29: A1/A2/B1/D32/D31 + staleness all landed, three mutations caught |
| D31 | Floor stays 26; `Session/` availability-gated (Understudy's pattern); Package.swift comment corrected | **Accepted** 2026-07-28 · comment corrected 2026-07-29, and the substrate answer **strengthens** it: a 26 deployment target is what lets one test target serve both tiers |
| D32 | `DeltaFlushPolicy`/`SnapshotPolicy` gain public construction; spelling at Phase 0 gate | **Accepted** 2026-07-28 (audit B2, approved) · **spelling landed** 2026-07-29 as named factories `.flushing(every:orAfterCharacters:)` / `.refreshing(afterEachGeneration:orAfterEvents:)`, inits internal. Awaiting gate sign-off |
| D33 | Driver is an actor; rebuild-per-generation first; reuse cache later-or-never behind a validity rule | **Accepted** 2026-08-01 · evidence: the session is a `final class`, `@unchecked Sendable`, not an actor, so the actor shape is a free choice and the `nonisolated let model` the protocol wants is unobstructed |
| D34 | Differ is a pure component over `(segmentID, text)` pairs; driver extracts; fail-loud on non-prefix | **Accepted** 2026-08-01 · evidence: `TextSegment { id: String, content: String }` *is* the pair, so the seam needs no invention |
| D35 | Normalization: per-family pure functions, both error families, §10.5 fixtures; Apple-error constructibility is a Phase 0 read | **Accepted** 2026-08-01 · read done: all nine constructible, so the open item closes — but the tiering flips from what D35 assumed (deprecated family = tier 1, current family = tier 2), and two deprecated cases need a §8 decision (§2a) |
| D36 | Three test tiers; gates record live vs. dormant honestly; substrate spike at Phase 0 | **Accepted** 2026-08-01 · **substrate is LIVE** (iOS 27 simulator, invocation in Phase 0). No gate in M6 should need the dormant wording; if one does, that is a finding |
| D37 | Understudy joins as a path dep, test target only; packaging flagged to M9 | **Accepted** 2026-08-01 · untouched by Phases 0–1; lands at Phase 3 |

## 10. Status log

| Date | Phase | Tests | Note |
|---|---|---|---|
| 2026-08-01 | **Phase 1.5 landed** (unplanned) | 389 (366 + 23) | The SDK error-surface sweep, its tripwires, **CI to run them**, and `Understudy.Script.Step.revise` so §7.3's fail-loud path is reachable end-to-end at Phase 3. Opened because Phase 1 found two error families by accident. **Nine `Error` types exist where §8 names one**; the sweep found a sixth *reachable* family in minutes — `ToolCallError`, thrown when an app-supplied tool fails mid-generation. Now mechanised: an error-surface manifest with per-type dispositions, three pinned declarations (`Transcript.Entry`/`Segment`, the channel's actions), and the **SDK build string pinned** so a toolchain bump *fails* rather than relying on someone remembering the ROADMAP's verification evening. Mutations Ⓗ Ⓘ caught. Two findings: `GenerationID` collides with Apple's inside `@Generable` expansions (**a consumer-facing hazard**, M9 naming review), and the simulator tier caught `Process` — host-only API — in test code |
| 2026-08-01 | **Phase 1 landed** | 380 (359 + 21) | The differ, both normalization files, `ToolRecordingPolicy`, and the import-boundary test. Four mutations (Ⓓ Ⓔ Ⓕ Ⓖ), all caught. **Tier 2 stopped being theoretical:** six 27-gated tests skip on the host and *execute* on the simulator, constructing real `LanguageModelError` / `SystemLanguageModel.Error` / PCC values. Three findings: a fifth non-prefix shape (`interiorGrowth` — a per-segment append that an append-only ledger cannot express), grapheme-vs-UTF-8 prefix comparison (a combining mark would have failed a well-behaved generation), and **two further Apple error families §8 does not mention**. One recorded deviation: this phase imports Foundation Models, which the phase title said it would not — see the Phase 1 gate |
| 2026-07-29 | **Phase 0 landed** | 335 (314 + 21) | Audit fixes A1/A2/B1 + D32/D31 + the whole staleness batch. Three mutations (Ⓐ Ⓑ Ⓒ), all caught, all reverted. **Both questions answered: tier 2 is LIVE** (iOS 27 simulator — 314 tests also green there), and all nine Apple error payloads are constructible, though the *tiering* flips from D35's assumption. Two unplanned findings: the deprecated error family has two cases §8 does not account for (rev 9 item 8), and a `Task.yield()` spin defeats `.timeLimit`, so the harness's `spin(until:)` checks cancellation. Warning-free |
| 2026-07-28 | Plan drafted | 331 (310 + 21) | Drafted at the M5 boundary from the boundary audit + M5-PLAN §7 handoffs + M4-PLAN §2 fact table. D30–D32 accepted (audit-approved); D33–D37 proposed for the Phase 0 gate. Rev 9 opens on its first amendment and ratifies at this milestone's close |

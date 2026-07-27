# M5 Implementation Plan — `ConversationStore` actor + turn verbs

**Status:** 🚧 **IN PROGRESS** — opened 2026-07-27 at the M4 boundary. **Phase 0 reviewed and committed; Phase 1 landed 2026-07-27, awaiting its review gate.**
**Companion to:** [ROADMAP.md](./ROADMAP.md) (M5 section) · [SPEC.md](./SPEC.md) §6.5, §11, §7.2, §7.4, §7.5, §9, §10.4 · [M4-PLAN.md](./M4-PLAN.md) §7 (the five inherited handoffs)
**Baseline:** M0–M4 done and audited, **266 tests green** (245 `LedgerKit` + 21 `Understudy`), both packages warning-free. **SPEC rev 8 open** (Appendix F — post-M4-audit amendments); it accumulates M5's items and **ratifies at this milestone's boundary** (agreed 2026-07-27).
**Spec work:** rev 8 is already open, so M5 amendments *extend Appendix F* rather than opening a new revision. The inventory is §6 of this plan; SPEC edits require approval first, drafted scratch-first per the standing pattern.

> **How to use this document.** This plan persists across sessions, agents, and
> compactions — it is the working memory for M5. Update the checkboxes and the
> per-phase status lines as work lands; record anything that changes a decision
> in the Decision log (D-numbers continue M4's global sequence at **D21** — a
> bare "D8" means the same thing in every plan); do not silently deviate. Each
> phase ends with a **review gate**: stop, run both packages' suites, and review
> with Alexander before starting the next phase.

> **TL;DR (experiment — if you read nothing else).** M5 builds the `ConversationStore`
> actor: ten verbs, single-flight per conversation, the two-channel error contract,
> `LedgerError`, the driver *protocol* (implemented at M6), the live set, and the
> snapshot-refresh trigger. The two design centers are **D21** (what the store asks
> of a driver) and **D24** (how the §6.5 critical section survives actor reentrancy).
> The test center is **deterministic cancellation chaos via `Cue`** (D26) plus a new
> standing property: *a store-written log always reduces with empty diagnostics.*
> Still zero Foundation Models — the dev machine runs macOS 26 and nothing here
> may need 27 to execute.

---

## 1. What M5 is, in one paragraph

M5 is the concurrency boundary and the public **write** API (§6.5, §11): an actor
that owns all writes, folds forward on its own appends (M4 handoff 4), stamps
identity and canonical timestamps at birth (handoff 1), enforces single-flight and
target eligibility, triggers snapshot refresh (handoff 2), and translates driver
signals into ledger events at flush cadence. It also *designs* two things the
project has deliberately deferred until the callers existed: **`LedgerError`**
(handoff 3) and the **driver seam** — the protocol `Session/`'s `GenerationDriver`
will implement at M6, which M5 exercises end-to-end with a scripted test driver.
The read side stays deliberately thin: one async read verb; the observable
projection is M7's.

**Roadmap exit criteria (the contract for "done"):**
- The §11 API sketch **compiles and runs** against a scripted driver — every
  line of it, including the exhaustive-switch consumer shape.
- **Single-flight and start atomicity have chaos tests** (§10.4): a losing
  `send` racer records *nothing*; exactly one terminal per generation under
  cancellation racing natural completion; the §7.2 Task-cancel straddle behaves
  (pre-append throws `CancellationError`, post-append returns `.cancelled`).
- Target eligibility enforced (respond→user, regenerate→assistant, edit→user).
- The two-channel contract holds verb-by-verb: `try` guards *did it start*; the
  return value answers *how it ended*.
- **New standing property:** every log produced by store verbs reduces with
  **empty `diagnostics`** — the store can never write an event the reducer
  would quarantine.
- SPEC **rev 8 ratified** at the boundary with M5's amendments (§6).

---

## 2. Context that must survive compaction

Facts M5 depends on that live in other documents or in M4's implementation.
Curated, not accumulated — each row is here because some Phase below acts on it.

| Fact | Source | Consequence for M5 |
|---|---|---|
| `append` returns the assembled tail (same order, sequences attached); P1 proves return-value ≡ re-read | M4 handoff 4; `Persistence.swift` | The actor **folds forward** — it never re-reads after its own append. `last?.sequence` drives the snapshot floor |
| `append` *debug-asserts* timestamps arrive canonical; it never repairs them | ADR-001 R-5; `SQLitePersistenceStore.append` | The actor is the **stamping site**: `WireDate.canonical(now())` at Record-mint time, nowhere else |
| `fold(resuming:after:with:)` is the one reduction path; `foldedState(of:)` composes it above the seam | `Store/Snapshots.swift` | Cold-loading a conversation into the cache is one call; the actor adds no reduction path of its own |
| Snapshot refresh is *triggered by nobody* as of M4 | M4 handoff 2; §9 | The actor owns the trigger: best-effort async after each `generationEnded` append, 500-event floor for pathological logs, both configurable |
| A snapshot save failure is a missed optimization; a snapshot *read* failure is swallowed; an `events` failure propagates | `Snapshots.swift` | The actor wraps `saveSnapshot` in the shrug (§9's "best-effort" is caller policy); it never converts an `events` failure into an empty conversation |
| **Swift actors are reentrant at every `await`** | Swift concurrency semantics | §6.5's "one actor-isolated critical section" cannot be a lock held across the append's `await`. D24 is the resolution — read it before writing any verb |
| The dev machine runs **macOS 26**; `ScriptedLanguageModel` and everything touching `LanguageModelSession` is 27-only and **cannot execute here** | CLAUDE.md toolchain note | M5's test driver is a **store-level double in `LedgerKitTests`** conforming to D21's protocol — no Foundation Models import anywhere in M5. The script→snapshot→diff end-to-end property stays M6's |
| `Understudy.Cue` is platform-agnostic (26+), public, and purpose-built for parking a generation mid-flight | `Understudy/Cue.swift` | LedgerKit's test target takes its **first Understudy import** at M5 — for `Cue` in the chaos suites. This is the import CLAUDE.md has promised since M3 |
| `Log.records` gives every reducer fixture its wire form; `Log.timestampsAreCanonical`, `Log.isStoreReplayable` exist | `ReducerFixtures.swift` | Store suites replay the same logs the reducer suites fold. Verb tests extend this: verb sequence → captured records → reducer fixture equivalence |
| Only `deltaAppended` coalesces; **everything else appends synchronously before the verb proceeds** — a `generationStarted` in an unflushed tail is the vanishing-turn hole | §7.4 | The generation loop flushes deltas on policy and *always* flushes before the terminal append |
| The requested `ModelDescriptor` is **app-supplied at driver init** — nothing in FM derives it | §7.8, OQ8 | The driver seam must *expose* the descriptor; the store copies it into `generationStarted`. The store never invents one |
| `deleteConversation` cancels first, then deletes; both sequence through the actor so the terminal-vs-DELETE race cannot occur | §9, §6.5 | Delete is a two-step actor routine, not a passthrough to the seam verb |
| Index divergence non-rule: `updateIndex` trusts the writer (a hostile second genesis could skew the index title) | `SQLitePersistenceStore.updateIndex` doc (M4 audit) | Moot once M5 lands: the store actor never appends a second genesis. The healthy-log property (§1) is what makes this class of divergence unreachable in production |
| Rev 8 is open; M5's amendments extend Appendix F and ratify at the M5 boundary | SPEC header; 2026-07-27 agreement | Phase 5 drafts §6's items scratch-first, gets item-by-item sign-off, ratifies |

---

## 3. Decisions (made up front; revisit only at a review gate)

### D21 — The driver seam: a public protocol at M5, one conformance at M6
The store cannot take a concrete `GenerationDriver` (it doesn't exist until M6
and would drag `Session/` into every M5 test), and it must not take
`any LanguageModel` (tenet 3 — the inference boundary is Apple's, and the store
has no business seeing it). So M5 defines the seam: a small **public** protocol
(the verbs are public and generic over it) that `Session/GenerationDriver`
conforms to at M6 and the test double conforms to now. **Final shape is Phase
0's deliverable and review-gate item**; the constraints it must satisfy are
decided here:

1. **The store owns every append.** The driver produces *signals* — text
   deltas, tool records, a terminal outcome — and never touches persistence.
   (§11's isolation sketch: the actor owns all writes.)
2. **Signals cannot be skipped, structurally** (tenet 4). The shape should make
   "exactly one terminal" the type's grammar, not a runtime promise. Recommended
   sketch: an `AsyncStream` of `.delta(String)` / `.toolRecord(ToolRecord)`
   elements with a **terminal `Outcome` as the return value** — the stream ends,
   then the outcome exists; two terminals are unrepresentable. Post-start
   failures arrive *as* `Outcome.failed`, never as a throw (§7.2 — normalization
   is the M6 driver's job; the protocol's async call does not `throws` after
   signals begin).
3. **The driver exposes its requested `ModelDescriptor`** (§7.8) — the store
   reads it when composing `generationStarted`.
4. **The store hands the driver reduction output, not the log**: the active-path
   messages and current instructions (rehydration material, §7.1). What the
   driver does with them (build a `Transcript`, hit a session cache) is M6's.
5. **Cancellation flows through structured concurrency.** The store runs the
   driver inside the verb's task; `cancelGeneration` cancels that task via the
   live set. The driver's obligation on cancellation is §7.5's: wind down and
   return `.cancelled`.

Naming candidate: `GenerationDriving` — bikesheddable at the gate; the
constraints are not.

### D22 — `LedgerError` is a destructurable enum, 1:1 with §11's throw conditions
D12's rule cuts the *other* way from the config types: consumers **switch over
errors** (that is what a typed error is for), so `LedgerError` is a public
`enum`, not a struct with factories. Its cases are exactly the pre-append
failure conditions §11 enumerates — `unknownConversation`, `unknownMessage`
(respond/regenerate/edit/switchBranch naming an ID the tree lacks),
`ineligibleTarget` (right ID, wrong role — carries the role expectation so the
message is actionable), `generationInFlight`, and `persistenceFailure`.
Two rules, both already paid for elsewhere:
- **GRDB never leaks** (ADR-003 rule 1): `persistenceFailure` wraps an opaque
  description or a LedgerKit-owned payload — never the underlying error type.
- **Prose is non-contractual** (ADR-001 precedent): a `CustomStringConvertible`
  for log lines, asserted never.

Exact case payloads are designed against the real verbs during Phases 1–3 and
recorded in rev 8 (§6); the shape and the inventory above are settled now.

### D23 — The actor folds forward on a per-conversation state cache
Per M4 handoff 4: on append the actor takes the returned tail and
`fold(resuming:after:with:)`s it into an in-memory `FoldedState` per
conversation — it never re-reads its own writes (P1 is the license). Cold load
goes through `foldedState(of:)` (the snapshot fast-path). Reads (`conversation(_:)`,
eligibility checks, endpoint lookups for auto-extend/path decisions) hit the
cache. `deleteConversation` evicts. **No eviction policy otherwise in v0.1** —
the cache is bounded by conversations actually touched in a session, a
`FoldedState` is small, and an LRU nobody measured is complexity nobody asked
for. Revisit only with a measurement in hand (the `WireJSON` rule).

### D29 — The cache is dropped, never repaired, when reentrancy makes it untrustworthy
**Proposed at Phase 1; awaiting the gate.** D23 says the actor folds forward on a
per-conversation cache. Both of the cache's operations sit behind an `await`, and
an actor is reentrant at every one, so both have a hazard D23 does not name:

1. **A cold load that resumes late.** Another verb may have populated *and*
   advanced the entry while the read was in flight; publishing the older fold
   would rewind the cache behind a completed write, and the next append would
   then fold its tail onto a state missing an event. Guard: **publish only if
   newer** (`current.lastSequence >= loaded.lastSequence` ⇒ keep current). Sound
   because the log only grows and this actor is its only writer.
2. **A tail that does not continue the cache.** Two writes to one conversation
   both await the database and nothing orders their resumptions, so the
   later-sequenced tail can arrive first. Folding it would raise a `sequenceGap`
   diagnostic *in memory* against a log that has no gap. Guard: **drop the
   entry** rather than fold a hole into it.

The shared principle is the one §9 already applies to snapshots: **a derived
cache may be discarded at any time, so the safe response to any doubt about it is
to discard it.** The worst an eviction costs is the replay it was avoiding; the
worst a repaired-but-wrong cache costs is state diverging from disk while both
halves look right alone — which is P1's whole subject. This does not weaken D23's
"no eviction policy in v0.1": there is still no *policy*, only two correctness
drops.

### D24 — Start atomicity under actor reentrancy: reserve → append → confirm-or-rollback
§6.5 requires the single-flight check, the verb's appends, and in-flight
registration in "one actor-isolated critical section" — but the append awaits
the database, and **an actor is reentrant at every await**: a second `send` can
interleave exactly there. The resolution is that the *reservation* is the
critical section, and it is fully synchronous:

1. **Reserve** (sync, no await): check the live set; if occupied, throw
   `generationInFlight`; otherwise register the reservation *before* any await.
2. **Append** (await): the verb's whole batch in one seam transaction.
3. **Confirm or roll back**: on append success the reservation becomes the live
   generation; on *any* throw the reservation is removed and the error
   propagates — the log was untouched (the seam's all-or-nothing promise), so a
   losing racer still records **nothing** and a failed starter leaves no trace.

A second racer in step 2's window sees the reservation and throws — which is
the §6.5 behavior, achieved by ordering rather than by a lock the language
doesn't offer. This pattern is load-bearing and mutation-testable: delete the
rollback and the chaos suite must catch a conversation wedged in-flight forever.

### D25 — The flush loop lives store-side; policies are structs with factories
§7.4 attributes delta coalescing to "the driver," written before the seam split
existed. The *loop* — consume signals, buffer deltas, flush every ~250 ms / N
chars, always flush before the terminal — belongs to the store's generation
routine: the store owns writes and the flush is a *persistence* cadence.
(The driver still controls what §7.4 really cared about: producing deltas, not
snapshots — the diffing is M6's, on the other side of the seam.) The cadence is
a `DeltaFlushPolicy`-shaped struct-with-factories (D12: constructed, never
destructured; certain to grow), with the §7.4 default. Snapshot refresh gets
the same treatment (`SnapshotPolicy`: after-each-terminal + 500-event floor,
§9). Where they attach — store init beside `PersistenceConfiguration` — is a
Phase 3 gate item; rev 8 records the §7.4 attribution clarification (§6).

### D26 — Cancellation chaos is deterministic: `Cue`-enumerated points, not randomized timing
§10.4 says "cancel at randomized points." The project has twice replaced
randomized with exhaustive (P1/P3 splits, crash-point fuzzing) for the same
three reasons — no seed, no flake, failures reproduce by re-running — and the
concurrency version of that discipline is **parking, not sleeping**: the test
driver scripts a `Cue` at each step boundary, the test cancels *at* a parked
point it chose, and the enumerable cancellation points are exactly the step
boundaries plus the §7.2 straddle (pre-reserve, post-reserve/pre-append,
post-append). One genuinely racy case remains — `cancelGeneration` racing a
natural terminal — and it is asserted by *outcome invariant* (exactly one
terminal, I3; first append wins) rather than by timing. Rev 8 amends §10.4's
wording the way rev 7 amended §10.6's (§6).

### D27 — The store is deterministic under injection (tenet 5)
The actor takes an `IDGenerator` and a `now: () -> Date` at init, defaulting to
`.live()` and the wall clock. Chaos and golden tests inject the seeded generator
and a fake clock, so a verb sequence produces **byte-stable logs** — which is
what lets verb tests assert against reducer fixtures (`Log.records` equivalence)
instead of against "roughly this shape." Same design as `IDGenerator` itself;
the store just plumbs it.

### D28 — One async read verb; the projection stays M7's
§11: the store exposes **no synchronous reads** — but `createConversation`
returns a `Conversation`, so an async read exists in all but name. M5 makes it
honest: `conversation(_ id:) async throws -> Conversation` (classify over the
cached fold, default mapping — the app's mapping override rides the projection
at M7). Nothing else: no list (the index read serves M7's `conversationList`),
no synchronous accessors, no `AsyncSequence` of changes (M7, via the value
observation noted in `Persistence.swift`).

---

## 4. Public-API ergonomics guardrails for M5

M5 is the milestone that *is* public surface, so the guardrails are the review
standard for every diff:

1. **The §11 sketch is the acceptance test for shape.** If a landed signature
   makes a §11 line unwritable as sketched, either the signature is wrong or
   rev 8 records why the sketch moved. Never silently diverge.
2. **Verb naming follows the sketch** (`send`, `respond(to:)`, `regenerate`,
   `edit`, `switchBranch(to:)`, `cancelGeneration(in:)`); parameter labels get
   the M4-audit treatment *at birth* — full grammatical call sites, no
   abbreviations, prepositions in labels.
3. **No public memberwise inits on anything derived** (M4 Phase 0's rule
   stands). The store's new public types are `ConversationStore`, `LedgerError`,
   the D21 protocol + its signal/request types, and the two policy structs.
4. **GRDB never leaks** — now enforced at two layers: the seam (M4) and
   `LedgerError.persistenceFailure` (D22).
5. **`Sendable` cleanliness with no `@unchecked` in public API** (tenet 6) —
   the actor boundary makes this mostly free; the D21 signal types must be
   values.
6. **Doc comments carry positioning** — every public symbol says *why it is
   shaped this way*, in the `Store/Persistence.swift` register. The two-channel
   contract gets stated on every generation verb, not once in a type comment.

---

## 5. Phases

Phase 0 gates everything (every later phase constructs its types). Phases
1→2→3→4 are sequential — each verb family builds on the previous one's actor
machinery. Phase 5 closes the milestone and ratifies rev 8.

---

### Phase 0 — The surface: driver seam, `LedgerError`, verb signatures

**Status:** ✅ **code landed 2026-07-27; review gate open.** 269 tests green
(248 `LedgerKit` + 21 `Understudy`), both packages warning-free.

**Goal:** every public shape exists, compiles, and is signed off before any
behavior lands — the D21/D22 designs made concrete.

- [x] D21 protocol + signal/request types in `Store/` (doc comments carrying
      the five constraints), named at the gate. → `Store/GenerationDriving.swift`:
      `GenerationDriving` (`model` + `generate(_:streamingInto:)`),
      `GenerationRequest`, `GenerationSignal`, `GenerationChannel`.
- [x] `LedgerError` with the D22 case inventory; `CustomStringConvertible`
      (non-contractual, stated). → `Store/LedgerError.swift`.
- [x] `ConversationStore` actor skeleton: init (persistence config, D27
      injection), all ten verb signatures + `conversation(_:)`, bodies
      `fatalError("Phase N")` (the one permitted use — they are compile
      scaffolding and no test may reach them). → `Store/ConversationStore.swift`,
      plus the internal `IdentifierSource` erasure.
- [x] Policy struct skeletons (`DeltaFlushPolicy`, `SnapshotPolicy` — names
      bikesheddable) with defaults only. → `Store/Policies.swift`.
- [x] A compile-only rendition of the §11 sketch in the test target (the
      acceptance test for shape, guardrail 1) — commented assertions, no
      behavior yet. → `Tests/LedgerKitTests/APISketchTests.swift`.

**Review gate:** signatures + doc comments read as the finished API; D21/D22
finalized (names, payloads); both suites green (unchanged counts).

**Gate items raised by the implementation** (decide here, not later):

1. **`GenerationChannel` is a fourth seam type the plan did not name.** D21
   sketched "an `AsyncStream` of signals with the terminal `Outcome` as the
   return value"; handing the driver a raw
   `AsyncStream<GenerationSignal>.Continuation` would also hand it `finish()`,
   and a driver finishing the stream truncates the store's loop while the driver
   is still producing. The wrapper narrows the driver's surface to `emit(_:)`;
   `makeStream()` and `finish()` are **internal**, so the store alone owns the
   stream's lifetime. Shape confirmed against the 27 SDK rather than assumed:
   `LanguageModelExecutor.respond(to:model:streamingInto:)` is request-plus-channel,
   one layer down.
2. **Construction of `GenerationRequest` / `GenerationChannel` is internal**,
   consistent with M4 Phase 0's derived-state rule. Consequence, accepted: a
   *third-party* driver author cannot call `generate` in isolation, because they
   cannot build a request. In-package drivers (M6) and the Phase 3 double are
   unaffected. Reopening this is additive, so it is not urgent — but it is the
   one place M5 narrows what v0.2 might want.
3. **Test count moved 266 → 269, against the gate's "unchanged counts".**
   Deliberate: three Phase 0 declarations have real behaviour rather than being
   scaffolding — the public init, the `LedgerError`-wrapping of a backend
   failure (guardrail 4's only testable instance today), and the channel's
   ordering/delivery. Leaving those untested to protect a predicted number would
   invert the test rhythm.
4. **The policy structs' memberwise inits are `internal`, not `private`.** The
   *public* surface is `.default` alone, as planned; the module needs to vary
   them (a flush-every-character policy is how "always flush before the
   terminal" gets a failing case at Phase 3).

---

### Phase 1 — Actor core + lifecycle verbs

**Status:** ✅ **code landed 2026-07-27; review gate open.** 285 tests green
(264 `LedgerKit` + 21 `Understudy`), both packages warning-free.

**Goal:** the actor exists as a correct single-conversation machine —
cache, stamping, and the verbs with no tree or generation semantics.

- [x] Fold-forward cache (D23): cold load via `foldedState(of:)`, advance on
      append, evict on delete. → `CachedFold` + `existingFold(of:)` /
      `foldForward(_:in:)` / `evict(_:)`. Cold load goes through a new
      `PersistenceStore.loadedFold(of:)`, which is `foldedState(of:)` **plus the
      sequence it stopped at** — `foldedState(of:)` is now expressed in terms of
      it, so there is still exactly one composition of the snapshot fast-path.
      `evict` is exercised directly; Phase 4's `deleteConversation` calls it.
- [x] Stamping site (M4 handoff 1): mint `Record`s with injected IDs +
      `WireDate.canonical(now())`. The corpus's `timestampsAreCanonical` and
      `append`'s debug assertion are the safety net; a store-level test asserts
      it directly anyway (the assertion is debug-only; the test is not).
- [x] `createConversation(title:)` → genesis append, returns `Conversation`.
- [x] `setInstructions(_:in:)`, `setTitle(_:in:)` — nil clears (§6.1);
      `unknownConversation` on a missing stream. **`FoldedState.hasGenesis` is
      the existence predicate**, which is a happy consequence rather than a
      design: the flag exists for P3, and "has a valid `conversationCreated`" is
      exactly what a caller means by "exists".
- [x] `conversation(_:)` (D28).
- [x] **Healthy-log property, first instance:** every verb-produced log
      re-reduces from disk with empty `diagnostics` and equals the cached state
      (fold-forward ≡ re-read — P1's discipline applied to the actor). →
      `healthyLogProblems(_:in:backedBy:)` in `StoreFixtures.swift`, in the
      `InvariantChecks.swift` returns-problems idiom so Phases 3–4 can sweep it.

**Review gate:** lifecycle verbs land events matching a hand-written
`Log`-fixture equivalent byte-for-byte under injection (D27); mutation test:
break the cache advance (skip one tail fold) and the healthy-log property must
catch the cache/disk divergence.

**Gate items raised by the implementation:**

1. **Two reentrancy hazards in the cache that D23 does not name — see D29.**
   Both are guarded and both are mutation-tested.
2. **Mutation results.** ① Cache advance skipped entirely → caught, but by
   `unknownConversation` (the genesis never reaches the cache), so it was
   re-run as ① *b* — fold the genesis, skip every tail after it — which is
   caught by the healthy-log property exactly as the gate predicts. ② Remove
   the publish-if-newer guard → caught by the late-cold-load test alone.
   ③ Remove the sequence-continuity check → caught by the out-of-order test
   alone. ④ Remove `WireDate.canonical` → see item 3.
3. **⚠️ Mutation ④ exposed a real hole in the stamping test, now fixed, and the
   lesson generalizes.** The first version read rows back from SQLite and
   asserted they were canonical — and it **passed** with canonicalization
   removed, because the wire formatter *rounds* on the way out, so the re-read
   repairs the stamp. R-5's bug lives precisely in the gap between the in-memory
   event and the re-read one, so a test that only looks at one side cannot see
   it. Fixed with a `RecordingStore` double capturing records **as written**,
   plus an explicit `rows == asWritten` comparison. **Standing note for later
   phases: any assertion about what the store wrote must observe the write, not
   the read-back** — the codec is not a neutral observer.
   (In *debug* this mutation trips M4's `append` assertion and takes the process
   down before any test runs; the store-level test is the release-build net,
   which is why the plan asked for it.)
4. **Test count 269 → 285** (16 new). Suites: lifecycle verbs, the stamping
   site, the fold-forward cache, cache reentrancy.
5. **`Latch` + `ParkingStore` + `RecordingStore` + `FailingStore` land in
   `StoreFixtures.swift`** as the store-side harness, alongside
   `ScriptedIdentifiers` (identifiers matching `Log`'s own scheme, so store
   output compares against hand-written fixtures) and `SteppingClock`.
   **`Latch` is deliberately not `Understudy.Cue`:** `Cue.park()` is internal to
   that package, so a `PersistenceStore` double cannot park on one. The planned
   first Understudy import therefore stays at Phase 3, where the parking happens
   inside the script player and only `reached()`/`signal()` are needed.

---

### Phase 2 — Tree verbs: `edit`, `switchBranch`, eligibility

**Goal:** the ledger-only verbs, with §6.4/§6.5's path semantics exact.

- [ ] `edit(_:content:in:)` → `messageEdited` + `activePathChanged`, one
      transaction; returns the replacement `MessageID`; eligibility: target is
      a **user** message (`ineligibleTarget` otherwise, `unknownMessage` if
      absent). Editing a root message works (I6's virtual-root case — fixture
      exists reducer-side; the verb test replays it through the store).
- [ ] `switchBranch(to:in:)` → bare `activePathChanged`; `unknownMessage` on a
      never-existent endpoint (the *store* throws where the reducer would
      quarantine row 12 — same fact, correct channel per layer).
- [ ] Eligibility checks read the cache — one shared internal
      `target(_:expecting:)` helper so respond/regenerate/edit agree.
- [ ] Mid-stream legality *stub*: `edit` and `switchBranch` do **not** check
      the live set (§6.5 allows them mid-flight) — asserted now with a
      hand-registered live entry, exercised for real in Phase 3.

**Review gate:** §6.4's three explicit-path cases have verb-level tests; the
healthy-log property covers every new verb; both suites green.

---

### Phase 3 — Generation verbs: `send`, `respond`, `regenerate` + the loop

**Goal:** the heart — single-flight, start atomicity, the generation loop, and
the two-channel contract, against a scripted test driver.

- [ ] **Test driver double** in `LedgerKitTests` conforming to D21: scripted
      signals (deltas, tool records, outcome) with `Cue` parking between
      steps — LedgerKit's first `Understudy` import (for `Cue`; the full
      `ScriptedLanguageModel` integration is M6's).
- [ ] Reserve → append → confirm-or-rollback (D24). `send` =
      `userMessageAppended` + `generationStarted` in one transaction;
      `respond`/`regenerate` add `activePathChanged` when the parent is off
      the endpoint (§6.4 — a requested generation never streams invisibly).
- [ ] `regenerate` is *exact* sugar: resolve the assistant target's parent,
      delegate to `respond` internals. One implementation, two entries.
- [ ] The generation loop (D25): consume signals; buffer deltas; flush on
      `DeltaFlushPolicy`; tool records and the terminal append synchronously;
      **always flush before the terminal**. Suspend the verb until the terminal
      is durable; return the `Outcome`.
- [ ] Single-flight: a second starter throws `generationInFlight`;
      cross-conversation concurrency is *tested*, not just permitted (two
      conversations, two parked drivers, both complete).
- [ ] Two-channel contract per verb: every §11 throw condition has a test
      proving the log untouched afterward (re-read, count rows).
- [ ] `ModelDescriptor` flows driver → `generationStarted` (D21 constraint 3).

**Review gate:** the §11 sketch runs (§1 exit criterion) minus cancellation
lines; start-atomicity mutation test (D24: delete the rollback → chaos suite
must catch the wedged conversation); healthy-log property now spans streaming
logs, including a flush landing mid-generation.

---

### Phase 4 — Cancellation, deletion, snapshot refresh, chaos

**Goal:** everything that interrupts a generation, and the §10.4 suite.

- [ ] `cancelGeneration(in:)` — canonical path via the live set; **no-op if
      none** (per §11: not throwing); winds the driver down through task
      cancellation; the loop appends `generationEnded(.cancelled)`; the
      suspended verb returns `.cancelled`.
- [ ] §7.2 straddle: Task-cancel **pre-append** throws `CancellationError`
      (nothing started, nothing recorded — verified); **post-append** returns
      `.cancelled` (the recording succeeded). Both points enumerated via D26's
      parking, not timing.
- [ ] Cancel racing natural terminal: benign — first append wins, exactly one
      terminal (I3), asserted by outcome invariant.
- [ ] `deleteConversation(_:)` — cancel-first sequencing through the actor
      (§9), then the seam's transactional delete; cache evicted; in-flight
      verb returns `.cancelled`, never a persistence error.
- [ ] Snapshot refresh (M4 handoff 2): best-effort async after each terminal
      append; 500-event floor; failures shrugged (`try?` *here*, per the
      `Snapshots.swift` division of labor); a test proves a cold reopen after
      refresh replays ≤ one generation's suffix (the M4 criterion, now
      exercised through the actor's own trigger).
- [ ] **Chaos suite (§10.4):** cancellation at every parked point of every
      scripted shape × {cancelGeneration, Task-cancel}; partial-content
      retention asserted; empty-diagnostics property throughout; live set
      always ⊆ open generations (P2's store-side half, feeding M7).

**Review gate:** full §11 sketch runs end-to-end including the stop-button
lines; mutation tests: remove the pre-terminal flush (partial-loss window) and
remove the cancel-first in delete — each must be caught; both suites green.

---

### Phase 5 — Wrap-up: rev 8 ratification + alignment

**Goal:** close the milestone the way M3/M4 closed — docs aligned, spec
ratified, handoffs recorded.

- [ ] Draft §6's rev 8 items to a scratch file; item-by-item sign-off; land in
      SPEC Appendix F; **ratify rev 8 at the boundary** (header flips to
      ratified; subsequent amendments open rev 9).
- [ ] **Alignment checklist** (codifying what M4 Phase 5 did ad hoc):
      ROADMAP M5 strike-through + exit criteria + M6/M7 section touch-ups;
      CLAUDE.md status + new landmarks (store actor, driver seam, chaos
      suites, first Understudy import); **`Sources/**` doc-comment sweep for
      claims rev 8 just made stale** (the standing rule added at the M4
      audit); this plan's §8 traceability + §9/§10 logs.
- [ ] Handoffs to M6 and M7 (§7 below) verified against what actually landed.
- [ ] Both suites green, warning-free; counts recorded in §10.

**Review gate:** milestone-complete review with Alexander; ROADMAP M5 exit
criteria all check.

---

## 6. Rev 8 inventory (amendments M5 expects to add — draft at Phase 5, not from memory)

Rev 8 already carries the M4-audit items (Appendix F). M5 adds, subject to
approval:

1. **`LedgerError` recorded in §11** — the case inventory and the two-channel
   contract stated against real signatures (was "designed at M5" forward
   reference).
2. **The driver seam recorded in §7** — the D21 protocol shape, and which §7
   obligations sit on which side of it (store: appends, flush cadence, live
   set; driver: normalization, rehydration, diffing, `isResponding` gate).
3. **§7.4 attribution clarified** (D25): the coalescing loop is the store's;
   the driver produces signals. Behavior unchanged; the sentence "driver
   coalesces disk flushes" predates the seam.
4. **§10.4 wording**: deterministic `Cue`-enumerated cancellation points
   replace "randomized points," with the one honest race (cancel vs. natural
   terminal) asserted by invariant — the §10.6 exhaustive-not-randomized
   amendment's concurrency sibling.
5. **The healthy-log property stated** (likely §6.5 or §10): store verbs
   cannot produce quarantining events; diagnostics on a store-written log are
   always empty. Implied today, load-bearing once apps read `diagnostics` as
   a corruption signal.
6. Anything Phases 1–4 surface that changes a §6.5/§11 sentence — logged here
   as discovered, the M4 pattern.

---

## 7. Explicit handoffs (recorded so they aren't lost)

**To M6 (`GenerationDriver` — the session seam):**
1. **The D21 protocol is the contract.** M6 implements it over
   `LanguageModelSession`: rehydration (§7.1) from the request material the
   store hands over, snapshot→delta diffing (§7.3, segment-aware preferred),
   error normalization (§8, both error families), the `isResponding` gate
   (§7.2), tool-record observation (§7.6). If the protocol needs to move, that
   is a rev 9 conversation *first*, not a silent widening.
2. **The end-to-end round trip becomes assertable**: scripted fragment →
   framework accumulation → snapshot → driver diff → `deltaAppended` recovers
   the script exactly (§7.3). M5's store chaos + M6's driver = the whole
   pipeline; the corpus should gain the fixture then, not before.
3. **The four behavioural residues** (§14 head) are unchanged and still M6's:
   thrown-or-trapped `concurrentRequests`, real-provider segment revision,
   usage-total inclusivity, the on-device context budget.
4. `ScriptedLanguageModel` first *executes* under a 27 runtime — M6 inherits
   the `.enabled(if:)` gating pattern for anything that runs a real session.

**To M7 (projection + `overlay_live`):**
1. **The live set is the overlay's input** — M5 ships it actor-side with the
   invariant (live ⊆ open) already tested; M7 surfaces it into
   `overlay_live` and completes P2 by passing the real overlay to the
   existing harness (`ProjectionChecks.swift` — change no assertion).
2. **`conversationList`** reads the index via the seam's
   `conversationSummaries` + GRDB value observation surfaced as an
   `AsyncSequence` (the deliberate omission noted in `Persistence.swift`).
3. **Display cadence ≠ flush cadence** (§7.4): M5's `DeltaFlushPolicy` is disk;
   the ~frame-rate main-actor hop is M7's own knob. The app's
   `RecoverabilityMapping` override also lands projection-side (D28 kept the
   store read on `.default`).

---

## 8. Coverage traceability (fill at Phase 5)

| Obligation | Suite / evidence | Status |
|---|---|---|
| §11 sketch compiles and runs against scripted driver | | ☐ |
| Start atomicity: losing racer records nothing | | ☐ |
| Single-flight per conversation; cross-conversation freedom | | ☐ |
| Two-channel contract, per verb, log-untouched proofs | | ☐ |
| Target eligibility (respond/regenerate/edit) | | ☐ |
| §7.2 straddle (pre-append throws, post-append returns) | | ☐ |
| Cancel vs. natural terminal: one terminal (I3) | | ☐ |
| Only deltas coalesce; flush-before-terminal | | ☐ |
| Healthy-log property over every verb + chaos run | | ☐ |
| Snapshot refresh trigger + cold reopen ≤ one suffix | | ☐ |
| Delete cancels first; cache evicted | | ☐ |
| Timestamps born canonical at the actor | `StoreStampingTests` — asserted on records **as written**, plus `rows == asWritten` (the read-back alone cannot see it) | ☑ |
| Live set ⊆ open generations (P2 store half) | | ☐ |
| Mutation tests: D24 rollback, cache advance, pre-terminal flush, cancel-first delete | | ☐ |

---

## 9. Decision log

| # | Decision | Status |
|---|---|---|
| D21 | Driver seam: public protocol at M5, five constraints; concrete conformance at M6 | **Accepted** 2026-07-27 · shape **proposed** at Phase 0: `GenerationDriving` = `var model` + non-throwing `generate(_:streamingInto:) async -> Outcome`, with `GenerationRequest` / `GenerationSignal` / `GenerationChannel`. Awaiting gate |
| D22 | `LedgerError`: destructurable enum, §11's throw inventory, GRDB-opaque, non-contractual prose | **Accepted** 2026-07-27 · payloads **proposed** at Phase 0: `unknownConversation(_)`, `unknownMessage(_)`, `ineligibleTarget(message:expected:found:)`, `generationInFlight(_)`, `persistenceFailure(description:)`. Awaiting gate |
| D23 | Fold-forward per-conversation cache; no eviction policy in v0.1 | **Accepted** 2026-07-27 |
| D24 | Reserve → append → confirm-or-rollback; reservation is the synchronous critical section | **Accepted** 2026-07-27 · mutation-test the rollback |
| D25 | Flush loop store-side; `DeltaFlushPolicy`/`SnapshotPolicy` as structs-with-factories | **Accepted** 2026-07-27 · attachment point at Phase 3 gate; rev 8 clarifies §7.4 |
| D26 | Chaos is deterministic: `Cue`-parked cancellation points; the one honest race asserted by invariant | **Accepted** 2026-07-27 · rev 8 amends §10.4 |
| D27 | Store takes injected `IDGenerator` + clock; byte-stable logs under test | **Accepted** 2026-07-27 |
| D28 | One async read verb `conversation(_:)`; no sync reads; projection stays M7 | **Accepted** 2026-07-27 |
| D29 | Cache dropped, never repaired, on reentrancy doubt: publish-only-if-newer on cold load, drop on a non-continuing tail | **Proposed** 2026-07-27 at Phase 1 · both mutation-tested · awaiting gate |

## 10. Status log

| Date | Phase | Tests | Note |
|---|---|---|---|
| 2026-07-27 | Phase 1 landed | 285 (264 + 21) | Cache, stamping site, `createConversation` / `setInstructions` / `setTitle` / `conversation`, healthy-log property. New: `Store/Snapshots.swift` gains `loadedFold(of:)`; tests gain `StoreFixtures.swift` + `ConversationStoreTests.swift`. **D29 proposed.** Four mutations run; ④ found a real hole in the stamping test (read-back repairs a bad stamp) — fixed, and the standing lesson is recorded under Phase 1 gate item 3. Warning-free |
| 2026-07-27 | Phase 0 landed | 269 (248 + 21) | Five files: `Store/{GenerationDriving,LedgerError,Policies,ConversationStore}.swift` + `Tests/APISketchTests.swift`. §11 sketch type-checks line-for-line against the landed signatures, with one recorded substitution (M6's concrete `GenerationDriver` → `some GenerationDriving`). Four gate items listed under Phase 0. Warning-free |
| 2026-07-27 | Plan drafted | 266 (245 + 21) | Sourced from the M4 boundary audit + M4-PLAN §7 handoffs; D21–D28 accepted; rev 8 open, ratifies at this boundary. TL;DR block is a deliberate experiment (M4 audit process feedback) — keep it if it earns its keep, drop it at Phase 5 if not |

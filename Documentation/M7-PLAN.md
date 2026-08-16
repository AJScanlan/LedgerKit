# M7 Implementation Plan — Observable projection + `overlay_live`

**Status:** ☑ **M7 COMPLETE 2026-08-16 — 452 tests green** (429 `LedgerKit` + 23
`Understudy`, warning-free, both substrates), the `Projection` app target builds and
runs, and **SPEC rev 10 is ratified** (Appendix H, thirteen items, five batches,
nothing touching the wire). All four phases done; D38–D49 Accepted. D38–D49 are **Accepted**; **D44 resolved as `guard`, adopted alone**;
D46–D49 were taken at the Phase 0 gate and fix gaps in D39/D41/D42 rather than
merely confirming them. `Projection/` is no longer empty: it holds
`overlay(_:live:)`, `LiveSet`, and both public types. The store has its feed
(`StoreNotification`, `notifications()`, `shownPartials`) and two new internal read
verbs (`foldedState(of:)`, `liveSet(of:)`, `conversationSummaries()`).

**Companion to:** [ROADMAP.md](./ROADMAP.md) (M7 section) · [SPEC.md](./SPEC.md)
§6.2 (derived state), §6.3 (the three-name table), §7.4 (two cadences, one truth
hierarchy, one overlay), §10.6 (P2), §11 (isolation sketch) ·
[M6-PLAN.md](./M6-PLAN.md) §7 (the four inherited handoffs) · the **M6 boundary
audit** (2026-08-13), whose findings A1–A4 are Phase 0 and whose rev 10 items
seed §6.
**Baseline:** M0–M6 done and audited; **429 tests green** as of Phase 0
(406 `LedgerKit` + 23 `Understudy`, warning-free, both substrates), from 420 at
plan time. SPEC **rev 9 ratified 2026-08-02**.
The M6 boundary audit (2026-08-13) found one contract gap (A1: failed tool
invocations leave no ledger trace), one wire-field defect (A2: `argumentsJSON`
built from a debug rendering), one store race (A3: delete versus a *new*
starter), and one speculative cancellation door (A4) — **all folded into Phase 0
below and all now fixed**, because M7 is the milestone where the projection reads
the store's every surface, and it must read a store that is actually correct.

⚠️ **A3's remedy changed before Phase 0 started, and A2's diagnosis changed
during it.** A TLA+ model of the store's delete-versus-start interleavings
(2026-08-15, [`Formal/`](../Formal/README.md)) reproduced A3 and then **falsified
the tombstone the audit had proposed** — it covers the wrong interval, and
clearing it on completion re-opens the window. Two alternatives verified;
**D44 chose `guard` and dropped the tombstone entirely.** Rev 10 items 8–9 follow
from it. Separately, A2's stated mechanism turned out to be wrong in a way that
made the test this plan specified **pass against the bug** — the field held JSON
all along; what it did not hold was *stable* JSON (see Phase 0's A2 item). The
same date as the model added bounded-exhaustive generated-log sweeps to the
reducer suite (+5 tests, hence the 420 above).
**Spec work:** amendments open **rev 10**, which ratifies at the M7 boundary.
The inventory is §6 — seeded from the audit, including one item **already
decided** (DoD-2's restatement, owner sign-off 2026-08-13). The standing
pattern applies: draft to a scratch file, sign off item by item, land in
batches, and run the `Sources/**` retired-phrase sweep **after each batch**.

> **How to use this document.** The plan is working memory across sessions,
> agents and compactions: checkboxes and per-phase status lines are updated as
> work lands; anything that changes a decision goes in the Decision log
> (D-numbers are global — a bare "D33" means the same thing in every plan, and
> this plan continues the sequence at **D38**); deviations are recorded rather
> than silent. Each phase ends with a **review gate**: stop, run both packages'
> suites, and review with Alexander before starting the next.

> **TL;DR.** M7 fills `LedgerKit/Sources/LedgerKit/Projection/` — the
> `@MainActor @Observable` read side (§11's isolation sketch) and the real
> `overlay_live` (§7.4). It opens with a **hygiene phase** (the audit's A1–A4,
> plus the Playground rewrite inherited since M4). The design center is **D38**:
> the store currently has *no surface* that can feed a projection — the
> unflushed tail is a local variable, `liveGenerations` is a bare `Set`, and
> nothing observes changes — so the store→projection feed is the one genuinely
> new architectural surface, and it is decided up front rather than improvised
> mid-milestone. The overlay itself is small and lands against a harness that
> has been waiting for it since M4: **`ProjectionChecks.swift` must accept the
> real `overlay_live` with no assertion changed** — if an assertion has to
> change, stop and review. Everything here is pure Swift over the store; **beta
> risk is zero** (no Foundation Models import anywhere in `Projection/` —
> `ImportBoundaryTests` already enforces it).

---

## 1. What M7 is, in one paragraph

M7 is the read side (G7): a `@MainActor @Observable` projection fed by the
`ConversationStore`, applying §7.4's liveness overlay so a streaming generation
renders `.streaming` at display cadence while the log fills at durability
cadence — and so a crash recovers by the overlay *disappearing*, never by a
recovery pass. Three deliverables: **`overlay_live`** (the pure function §6.3's
pipeline names, completing P2), **the projection types** (per-conversation view
+ the conversation list, §11), and **the store→projection feed** that carries
deltas to the main actor at display cadence, independent of the disk flush
(§7.4's two cadences). The reducer stays pure and never learns what "live"
means; the store stays the only writer; the projection is derived, rebuildable,
and deletable — tenet 2 applied to its own read side.

**Roadmap exit criteria (the contract for "done"):**

- **P2 green**: the real `overlay_live` passed into `ProjectionChecks.swift`'s
  predicate, swept as the harness already sweeps, **changing no assertion**
  (M6-PLAN handoff 1). An assertion that has to change is a stop-and-review
  signal, not an edit.
- **Streaming renders smoothly in a preview driven by `ScriptedLanguageModel`**
  — the preview lives app-side (D43 decides where), since the library ships no
  view components (N6/G7).
- **Recovery = overlay vanishing, no recovery pass**: kill-shaped test — a
  projection rebuilt over the same store with an empty live set shows
  `.interrupted` where the live one showed `.streaming`, with no repair step
  anywhere.
- **Phase 0's audit fixes all landed with the tests that would have caught
  them.**
- SPEC **rev 10 ratified** at the boundary (§6's inventory).

---

## 2. Context that must survive compaction

Facts M7 depends on that live in other documents, in M5/M6's implementation, or
in the M6 boundary audit. Curated, not accumulated — each row is here because a
phase below acts on it.

| Fact | Source | Consequence for M7 |
|---|---|---|
| **The store has no projection-facing surface today.** The unflushed tail is a **local variable** inside `ConversationStore.consume()`; `liveGenerations` is an internal `Set<GenerationID>` with no partials; nothing observes changes | Audit finding; `ConversationStore.swift` | D38/D39 design the feed *first*. Nothing in M7 works until the projection can learn that something happened |
| §7.4's formula: `projection = overlay_live(reduce(persistedLog ++ unflushedTail, mapping))`; the overlay maps `.interrupted → .streaming` for exactly the live `GenerationID`s, identity otherwise; **no fold ever yields `.streaming`** | SPEC §7.4, §6.3 | The buffered text is *reduction input* in the formula, but it is not events (deltas gain sequence only at append) — so the practical decomposition is: classified-from-persisted + the live text carried per generation (D40 states this precisely, because two wrong shapes pass a sloppy reading) |
| **P2's harness exists and is mutation-tested**: `projectionProblems(in:overlaying:foldedFrom:live:)`, `LiveSet = [GenerationID: String]` (the value is the **full shown partial**), `LiveOverlay` typealias, `identityOverlay`, `referenceOverlay` (a *control* — never promote it) | `ProjectionChecks.swift`; SPEC §10.6 | Phase 1 passes the real overlay in and changes no assertion. Clause 1 pins `shown == live[generation]` exactly; clause 2 pins everything else to the fold; clause 3 pins live ⊆ open |
| The three-name table: folded `.open` → classified `.interrupted` → overlaid `.streaming`. Reading right-to-left is the crash | SPEC §6.3 | The kill-shaped test (Phase 3) is this table executed. `.streaming` is projection-only — the store's `conversation(_:)` can never return it |
| **Display cadence ≠ flush cadence** — deltas hop to the main actor at ~a frame, independent of disk (§7.4's truth hierarchy); `DeltaFlushPolicy` is the *disk* knob and says so in its doc | SPEC §7.4, §11; `Policies.swift` | The projection has its own cadence knob (D42), injected for tests exactly as `DeltaFlushPolicy` is — `.zero` makes application immediate and deterministic |
| The app's `RecoverabilityMapping` override **rides the projection**, not the store (`conversation(_:)` deliberately uses `.default`) | M6-PLAN handoff 3; SPEC §8 provenance rule | Projection init takes a mapping; a mapping fix retroactively upgrades historical failures on next reduction, which the projection is where an app observes |
| `conversationSummaries()` exists on the seam; ADR-003 rule 4 *anticipated* GRDB `ValueObservation` joining "at M7 as an `AsyncSequence`" — anticipated, not decided | ADR-003; M6-PLAN handoff 2 | D41 decides — and proposes **not** doing it (the store is the only writer, so store-side notification suffices and the seam stays six verbs). A deviation from two documents' sketches; flagged for gate sign-off |
| **Audit A1**: a failed tool invocation leaves no `toolInvocationRecorded` — `ToolObservation` emits only on `toolOutput` (always `.succeeded`), and the driver's catch normalizes `ToolCallError` away, discarding `tool.name`. §8's "two facts, two events" is unimplemented; `ToolRecord.Status.failed` is dead wire surface. **Owner decision 2026-08-13: fix the code, not the spec** | Audit; `GenerationDriver.swift`, `NormalizeAppleErrors.swift` | Phase 0. The peek lives in the driver's catch arm (normalize is pure and has no channel); `ToolCallError.tool` is public, so the name is available at the catch site |
| **Audit A2**: `argumentsJSON` records `String(describing: call.arguments)`; `GeneratedContent.jsonString` exists | Audit; `GenerationDriver.swift` | Phase 0, one line |
| **Audit A3**: `deleteConversation`'s cancel-and-wait is not atomic with its DELETE — a *new* starter interleaving at delete's awaits appends into an erased conversation (`MAX(sequence)+1` restarts at 1 → genesis-less rows). Owner decision 2026-08-13 was a deletion tombstone; **superseded 2026-08-15 — TLC shows the tombstone insufficient** (`Formal/`, D44) | Audit; TLA+ model `Formal/LedgerStore.tla`; `ConversationStore.swift`, `SQLitePersistenceStore.swift` | Phase 0, remedy now an open choice. "An atomicity argument is only as good as its unit" (rev 9, batch A) — M6's A1 widened the wait's unit, A3 widened it again, and the model's answer is that **no in-memory flag is the right unit at all**: the only place that can decide is the write transaction |
| **Audit A4** (speculative): a stop landing while a tool executes can plausibly surface as `ToolCallError(underlyingError: CancellationError)` → generic catch → normalize → **`.failed`** for a user's stop | Audit | Phase 0: `Task.isCancelled` check in the generic catch arm before normalizing. The cancelled side may be end-to-end unreachable (like §7.3's fail-loud path); test the reachable half, record the honest limit |
| The Playground hand-builds a tree and needs `@testable`; rewrite to `Conversation(reducing:)` requires Xcode (playgrounds are invisible to `swift build`) | Inherited M4 → M5 → M6 → here | Phase 0 — M7 is the first milestone that is in Xcode anyway (previews, the demo app target) |
| `Projection/` must never import FoundationModels; the boundary is enforced mechanically, imports *and* type names, with vacuity guards | `ImportBoundaryTests` (M6 Phase 1) | Zero beta risk in this milestone is a *tested* property, not an intention. Tier 1 throughout except the Phase 3 pipeline test |
| Store determinism under injection: `ScriptedIdentifiers`, `SteppingClock`, `StoreUnderTest.continuing(_:)`, `RecordingStore`, `Latch`, `ScriptedDriver`, `ParkingStore`, `spin(until:)` (checks cancellation — a bare `Task.yield()` spin defeats `.timeLimit`) | `StoreFixtures.swift`; M5/M6-PLAN | Phase 2's projection tests drive the store with `ScriptedDriver` at tier 1; Phase 0's A3 test parks the DELETE |
| The on-device budget is **4096 tokens, two ~2k turns** (rev 9) | SPEC N3, §7.1 | Not M7's to solve, but M7 hands M8 the demo constraint: the demo script needs short turns or the `.reduceContext` affordance wired into demo UI |
| **DoD-2 is restated (decided 2026-08-13):** one-line swap demonstrated against a **second real provider** — PCC — Claude-package if a later ring carries it | M6 audit; ROADMAP M8 | §6 item 4 (rev 10 lands the §13 wording). M8 plans against PCC |

---

## 3. Decisions (made up front; revisit only at a review gate)

### D38 — The store notifies; the projection subscribes (the feed's direction)

The projection learns about changes through a **store-vended `AsyncStream` of
per-conversation notifications**, fed synchronously at the two points the store
already owns every change: signal receipt (deltas and tool records, *before*
the flush buffer — this is what makes display cadence independent of disk) and
append commit (everything else — starts, terminals, edits, path changes,
metadata). The projection consumes at its own pace.

Rejected: the projection as a registered delegate/sink (couples the actor to
`@MainActor` types and inverts who owns cadence); the projection polling
`conversation(_:)` per frame (§11 forbids exactly this reading — and a store
read can never see the unflushed tail). The `AsyncStream` shape is the same
choice `GenerationChannel` already made one seam over, for the same reasons,
including **unbounded buffering** with the same argument: a dropped
notification is a stale screen, and staleness that heals on the next
notification is tolerable only if the next notification is guaranteed — which
dropping breaks.

**The stream is infrastructure, not API**: internal, like `liveGenerations`.
Consumers see the projection types (D42), never the feed.

### D39 — What crosses the feed: deltas by value, everything else by invalidation

Two notification shapes, matching the two cadences:

- **`.delta(GenerationID, String)`** — the suffix, forwarded as it crosses the
  driver channel. The projection *accumulates* text per live generation and
  applies it to observable state on its display tick. Carrying the text avoids
  a store read per frame during streaming — the hot path costs a string append.
- **`.changed(ConversationID)`** — a non-delta event landed (start, terminal,
  edit, switch, metadata), or the live set moved. The projection re-pulls
  `classify(fold)` through the store (cheap: the fold cache makes it a
  dictionary read + classify) and rebuilds its base conversation. Rare by
  construction — §9's index argument, one layer up: non-delta events are the
  ~once-per-turn events.

On a terminal: the store's fold catches up (the pre-terminal flush + terminal
append), the projection receives `.changed`, re-pulls, and drops that
generation's accumulator. The overlay then has nothing to overlay — the message
is terminal in the base — which is P2's clause 3 holding by construction.

Deliberately **not** a third shape for tool records: they are non-delta
appends, so they already arrive as `.changed` with the re-pull carrying
`Message.toolRecords`. A live "using tool…" signal remains a session concern
v0.1 declines to surface (§7.6) — the feed must not become a side channel that
re-opens that decision.

### D40 — The overlay flips state; the projection supplies the full partial

`overlay_live` is a pure `@Sendable` function in `Projection/`, exactly
`ProjectionChecks.LiveOverlay`'s shape: `(Conversation, LiveSet) ->
Conversation`, where `LiveSet = [GenerationID: String]` and the value is the
**full partial to show** — the folded partial (persisted deltas, already in the
base conversation) plus the display accumulator (unflushed text, D39). The
overlay maps `.interrupted → .streaming(partial: liveSet[generation])` for
messages whose `generationID` is in the live set, and is the identity
everywhere else — state flipped, nothing else touched (P2's "more than its
state overlaid" clause).

Stated this precisely because two wrong shapes pass a sloppy reading of §7.4:
an overlay that *ignores* the live set's text and merely flips the case shows
stale text (the unflushed tail never renders — display cadence collapses into
flush cadence); an overlay that treats the live value as a *suffix* to append
double-counts everything already flushed. The live value is the whole partial;
assembling it is the projection's job (base partial + accumulator), and P2's
clause 1 (`shown == live[generation]`, exact) is the equality that keeps the
assembly honest.

### D41 — `conversationList` via store notification; the seam stays six verbs

The list projection re-pulls `conversationSummaries()` on `.changed`
notifications (the index updates on exactly the non-delta appends, §9 — the
same events D39 already forwards) plus deletes. **GRDB `ValueObservation` is
deliberately not wired**, which deviates from two documents' sketches (ADR-003
rule 4's "observation joins at M7"; M6-PLAN handoff 2) and needs gate
sign-off. The reasoning: the store actor is the **only writer** in the process,
so database-level observation would watch for changes that can only originate
one actor-hop away — a second, heavier mechanism to learn what the store
already knows at the moment it does the writing. Not wiring it keeps ADR-003
rule 4 intact ("six verbs; anything else must argue its way in" — nothing now
argues its way in), keeps the in-memory/test double trivial, and removes a GRDB
feature from the dependency surface. If v0.2+ ever admits a second writer
(widgets, extensions, sync), `ValueObservation` is the escape hatch and joins
*then*, with the argument it deserves. ADR-003 gets a one-paragraph amendment
recording that rule 4's anticipated exception was considered at M7 and
declined.

### D42 — Two public projection types; the mapping and cadence ride the init

- **`ConversationProjection`** — `@MainActor @Observable public final class`,
  one per conversation being displayed: `var conversation: Conversation`
  (rebuilt per D39/D40), created from a store + `ConversationID` + an optional
  `RecoverabilityMapping` (default `.default` — handoff 3's override point) +
  a display cadence (`Duration`, default ~16 ms; `.zero` = apply immediately,
  which is what tests inject — the D32 pattern of policy-as-parameter, without
  a policy type until a second knob exists).
- **`ConversationListProjection`** — `@MainActor @Observable public final
  class`: `var conversations: [ConversationSummary]`, sorted as the index
  sorts (last-event-at descending).

Names bikesheddable at the gate (per §6.1's standing rule); the *count* is the
decision — exactly two, nothing else public in `Projection/`. The §11 sketch's
`projection.conversationList` spelling is honoured by the list type; whether
one facade type should wrap both is a gate question, defaulting to **no** (a
facade would hold projections for conversations nobody is displaying, or grow a
cache policy nobody asked for). Derived-state rules carry over: no public
memberwise inits, nothing constructible that a store didn't produce.

### D43 — The exit-criterion preview lives in the `Projection` app target

"Streaming renders smoothly in a preview driven by `ScriptedLanguageModel`"
(ROADMAP M7 exit) needs a host, and the library must not ship views (N6). The
preview lands as a **debug view in the `Projection` app target** (which exists,
builds from the workspace, and is otherwise empty until M8): a minimal
`switch message.state` view over a `ConversationProjection`, driven by
`GenerationDriver` + `ScriptedLanguageModel`. M8 replaces it with the real UI —
this is deliberately M8's skeleton, not a throwaway: the exhaustive-switch
showpiece written here is the one M8 polishes. The Playground (post-rewrite,
Phase 0) stays a *reducer* example and does not gain a projection dependency —
one teaching artifact per concept.

---

## 4. Public-API ergonomics guardrails for M7

M5/M6's guardrails carry forward (the §11 sketch is the acceptance test for
shape; labels get the M4-audit treatment at birth; no public memberwise inits
on derived state; `Sendable` cleanliness with no `@unchecked` in public API —
note `@Observable` classes are reference types on the main actor, which is
their `Sendable` story; doc comments carry positioning). M7 adds:

1. **The public surface is two types** (D42) and whatever §11-sketch lines they
   imply. The feed, the accumulator, the live-set assembly are internal.
2. **`Projection/` never imports FoundationModels** — already enforced by
   `ImportBoundaryTests`; stated here so nobody "temporarily" does it.
3. **The overlay changes message state and nothing else** — P2's predicate is
   the enforcement; any projection convenience that re-derives or re-orders
   tree data is out of scope (the `Conversation` value is already the API).
4. **Doc comments carry the truth hierarchy**: display cadence is not
   durability; the projection is derived and deletable; `.streaming` exists
   only here (§6.2's "projection-only in a stronger sense").

---

## 5. Phases

Phase 0 gates everything (the store must be correct before the projection
mirrors it). Phase 1 is the overlay against the waiting harness. Phase 2 is the
feed and the types. Phase 3 proves it end-to-end and hosts the preview. Phase 4
closes the milestone and ratifies rev 10.

---

### Phase 0 — Hygiene: the M6 boundary audit's findings

**Status:** ✅ **done 2026-08-15 — 429 tests green** (406 `LedgerKit` + 23
`Understudy`, warning-free). All four A-findings fixed with mutation-verified
tests; D44 resolved as **`guard`, adopted alone**; four further decisions
(D46–D49) taken at the Phase 0 review and recorded below. Two of the audit's
characterisations were **corrected by measurement** — see the status log.

**Goal:** the audit's code findings fixed with the tests that would have caught
them (the D30 pattern), plus the Playground rewrite. No projection code yet.

- [x] **A1 — failed tool invocations reach the ledger.** In
      `GenerationDriver.stream`'s generic catch arm, peek before normalizing:
      if the thrown error is a `LanguageModelSession.ToolCallError` (outermost
      wrapper — its `tool` names the tool that failed), emit
      `channel.emit(.toolRecord(...))` with `status: .failed`, name from
      `error.tool.name`, duration from the observation's `firstSeen` where a
      pending observed call matches, `argumentsJSON` per policy where captured
      — then return `.failed(normalize(...))` as today. Gated on
      `policy.recordsInvocations`, like every record. I4 holds (the record
      precedes the terminal; the channel is FIFO and the store's consume loop
      appends it before the wind-down's terminal). This makes §8's "two facts,
      two events" sentence *true*; §6's item 1 records the obligation in §7.6.
      **Test (the probe the claim never had):** register a throwing tool stub,
      drive it with `Script.Step.callTool` (+ `capabilities: [.toolCalling]`) —
      the framework executes the real registered tool, so the throw reaches the
      stream on the simulator tier — and assert **both** facts: the
      `.failed` record (name, no payloads under `.metadataOnly`) landing in
      `Message.toolRecords` through store and reducer, and the terminal
      carrying the *unwrapped* error. Mutation: drop the emission — the new
      test must catch it; the existing suites must not (that is the hole being
      closed).

      **Landed**, with the duration rule decided rather than discovered:
      Apple's entries key on a call *id* while its error names a *tool*, so a
      duration is attributed only when exactly one observed-but-uncompleted
      call carries that name; otherwise nil ("not reported", the rule
      everywhere else). **Two framework behaviours were measured and both are
      now tested:** a tool call that is the model's *first* action produces
      **no snapshot at all** before the throw, so nothing about the call is
      ever observed and the record carries name + status only; a call preceded
      by text lands a `toolCalls` entry in a snapshot, and duration *is*
      attributed (3 ms, canonicalized per R-5 — asserted). The record lands
      either way, which is A1's actual claim.
      Mutation run: dropping the emission failed **only** the three new tests
      and no pre-existing one — the hole, confirmed as a hole.
- [x] **A2 — `argumentsJSON` is JSON.** `String(describing: call.arguments)` →
      `call.arguments.jsonString`, in `ToolObservation` and in A1's new path.
      Assert under `.full` that the recorded value parses as JSON — the test
      the field's name always implied.

      ⚠️ **The audit's characterisation was wrong, and the corrected one is
      worse.** "Holds a debug description" is literally right — `GeneratedContent`
      conforms to `CustomDebugStringConvertible` and *not*
      `CustomStringConvertible`, so `String(describing:)` resolved to
      `debugDescription`. The implied consequence — that the field therefore held
      unparseable text — is **false**: Apple's debug rendering emits JSON, so the
      test this item asked for (assert it parses) **passes against the bug**, and
      was observed doing so. The real defect is **byte instability**:
      `debugDescription` renders keys in *dictionary* order, so the same arguments
      recorded in two processes produce different bytes — measured directly, three
      runs, three orderings. That is the per-process hasher seed `Reduce/` is
      forbidden from leaking, arriving through Apple's API into a durable audit
      field, where a record that disagrees with itself across launches is worse
      than one that fails to parse. `jsonString` is order-preserving and was
      stable across the same three runs. The test therefore asserts **key
      order**, and that assertion does catch the mutation.
      *Generalizable lesson, and it is the §8 `emptyResponse` lesson again from
      the other side: an audit finding is an empirical claim too. This one named
      the right line for a reason that would not have held up.*
- [x] **A3 — resolved: `guard`, adopted alone (D44).** Model-checked
      2026-08-15; the model, its four variants and the counterexample traces are
      in [`Formal/`](../Formal/README.md).

      **What was proposed** (owner decision 2026-08-13): `deleting:
      Set<ConversationID>` on the store actor, set synchronously at
      `deleteConversation`'s entry before its first await, checked by
      `reserve(_:)` / `record(_:in:)`, **cleared on completion and on
      failure**.

      **Why it fails.** The tombstone covers *[delete entry, delete
      completion]*. The interval that needs covering is *[starter's existence
      read, starter's append]*. `send` resolves `existingFold` **before** a
      suspension and calls `reserve` **after** it, with no re-check — so a
      starter that read while the conversation existed, and reserves after the
      delete finished and cleared the flag, meets no guard at all. Its stale
      read says the conversation exists; the tombstone says no deletion is in
      progress; both are true about moments that never overlapped. TLC produces
      the trace with `deleting = FALSE`, `convExists = FALSE`, deleter
      terminated.

      Two facts carry the damage past every in-memory check, both verified in
      source rather than assumed: **`events` has no foreign key to
      `conversations`**, and **`append` validates only that each record's own
      `conversationID` matches its target** — never that the conversation
      exists or has a genesis.

      **Reachability, honestly.** The trace needs the starter's `existingFold`
      to suspend (cold fold cache) and its continuation to be scheduled after
      the deleter completes. Swift guarantees no FIFO across continuations
      resumed from different sources — a GRDB callback versus an actor hop — so
      this is *permitted*, not forced. The window is as wide as a
      snapshot-plus-suffix load, comfortably wider than a single DELETE. And
      the objection survives the caveat: under the tombstone the invariant
      holds only when the scheduler cooperates, and nothing in the code
      requires it to.

      **Two remedies verify** (state space exhausted, both):
      - **`guard`** — inside the same write transaction that computes
        `MAX(sequence)+1`, refuse a batch that would be a conversation's first
        row without being its genesis. Interleaving-independent, because the
        write transaction is the one place where "does this conversation have
        rows" and "am I adding rows" are answered together under SQLite's write
        lock. Also makes §6.5's healthy-log property *enforced* rather than
        *maintained* (rev 10 item 8).
      - **`sticky`** — the tombstone, never cleared. Costs an unbounded set of
        poisoned identifiers for the process's lifetime.

      **Decided 2026-08-15: `guard`, and the tombstone is dropped entirely** —
      not even retained as a cheap early `unknownConversation`. The argument that
      settled it goes past "interleaving-independent": **`guard` is a claim about
      the log, both tombstones are claims about one process's memory.** The
      property being protected is §6.5's healthy-log property, which is a property
      of *logs*, so enforcement belongs where logs are written. A tombstone
      protects nothing against a second process, a crash-restart, or v0.3 import
      tooling; `guard` protects against all three without knowing they exist. And
      keeping one as an affordance would leave a second mechanism that the next
      reader reasonably mistakes for the protection — which is precisely the
      misreading this finding already cost an audit cycle to correct.

      **As landed:** the check is inside the same write transaction that computes
      `MAX(sequence)+1` and costs only a comparison, since that value is already
      fetched. The batch-shape half (`first.payload.isGenesis`) is answered
      *outside* the transaction, where it needs no lock; only the conjunction
      refuses. The error is a **seam-level** `PersistenceRefusal.missingGenesis`,
      defined in `Persistence.swift` rather than inside the GRDB conformance, so
      `ConversationStore` translates a seam error and never a backend one
      (ADR-003 rule 1 intact). It translates to
      **`LedgerError.unknownConversation`** — the error the caller would have
      received had the race not happened; reporting `persistenceFailure` would
      hand an app a broken-disk affordance for a conversation that was simply
      deleted. `conversationMismatch` moved to the same type and is deliberately
      *not* translated: it means the store passed records it had no business
      passing, and there is no caller-facing recovery for a LedgerKit bug.

      **Tests (three, all landed) plus two seam-level unit tests.**
      `ParkingStore` gained the `.delete` parking point it lacked. ① A starter
      racing a *committed* DELETE is refused, no genesis-less row survives, and
      the store stays usable. ② A starter arriving during delete's
      cancel-and-wait — kept because "the guard covers it" is the *wrong* lesson:
      the DELETE has not committed there, so single-flight is what covers it, and
      conflating the two would leave one of them untested. ③ **The interleaving
      that falsified the tombstone** — existence read before the delete, `reserve`
      after it completed, reached via an explicit `evict` so the read must suspend.
      `RecordingStore` gained `attemptedAppends` for ③, because a *refused* batch
      writes nothing and `written` therefore cannot distinguish a verb that
      reached the write boundary from one that never got that far — which is the
      whole content of the interleaving.

      ⚠️ **The mutation taught something the test nearly missed.** With the guard
      removed, `send` *still* throws `unknownConversation`, by a longer route: the
      append lands at sequence 1, `foldForward` drops the diverged cache (D29), the
      rehydration read reloads cold, and the reloaded log has no genesis. Same
      error, junk rows on disk. **A test asserting only the throw passes against
      the bug** — the empty-rows assertion is the one with teeth. Three tests
      caught the mutation; the throw assertion caught nothing.

      A fourth structural exclusion was added to `Log.isStoreReplayable`
      (a genesis-less log is now unwritable), derived from the log's own first row
      rather than named per fixture. `PrewrittenStore` is a new double for the
      read-side claim the guard makes unwritable: a genesis-less log **already on
      disk** still reads as `unknownConversation`, which is reachable by partial
      restore, tampering, or a pre-guard build.

      ⚠️ **Do not treat the model as the verification.** It says the shipped
      code is wrong and that two candidate remedies close *this* property under
      *these* abstractions (one conversation, no fold cache, no persistence
      failures — the head of `LedgerStore.tla` lists them). The Swift tests are
      still the evidence that the chosen remedy is what got written.
- [x] **A4 — the wrapped-cancellation door.** In the same catch arm, before
      A1's peek and the normalize: `if Task.isCancelled { return .cancelled }`.
      Defensive, per §7.5's "never assume a stream reports its own
      cancellation" — a stop surfacing as any thrown error must not be recorded
      as a failure. **Honest limit, recorded like §7.3's:** the cancelled side
      may be end-to-end unreachable (the stream tends to end silently first);
      test the reachable half — an *uncancelled* `ToolCallError(underlying:
      CancellationError)` still lands `.failed` (a provider throwing spurious
      cancellation is not a user's stop) — and the check's unit is the
      already-proven silent-stream test's sibling.
      *Ordering note: A4's check, then A1's peek, then normalize — a genuine
      stop should not also mint a failed tool record for a tool that was merely
      interrupted.*

      **Landed in that order.** The reachable half is tested: an *uncancelled*
      `ToolCallError(underlyingError: CancellationError)` lands `.failed` on §8's
      floor **and** still emits its `.failed` tool record, so A1 and A4 compose
      rather than compete. The mutation that matters is not *removing* the check
      (whose cancelled side is unreachable, so nothing could catch it) but
      **writing it wrong** — keying on the error's type instead of on task state,
      which is exactly the implementation A4 warns against. That mutation was run
      and is caught by this test alone.
- [x] **Playground rewrite** (inherited M4 → here): drop `@testable`, build a
      short log, `Conversation(reducing:loadedFrom:)`, keep the tree/branch
      rendering.

      **Verified better than the bar this item set.** Rather than
      compile-checking in Xcode, both files were compiled *and run* as a scratch
      SwiftPM executable depending on `LedgerKit` by path — so the check is that
      the **public** API admits the example, which `@testable` in Xcode could not
      have told us. Output: `diagnostics: []`, a 3-message active path, 1 sibling
      branch. Three real defects surfaced that a visual read would not have: no
      public initializer takes a `sequence` (it is `LedgerEvent(record:sequence:)`,
      because nothing above the seam may choose one); the file relied on `UIKit`
      re-exporting Foundation; and top-level `var`s are `@MainActor`-isolated
      under Swift 6 while a free `func` is not, so the log builder had to become a
      value type. `ConversationView` also became the **exhaustive** `switch` §11
      calls the showpiece — it had a `default: "NOT HANDLED"`, which the new log's
      `.failed` branch would have rendered. *Only the three-line
      `PlaygroundSupport` live-view tail remains CLI-unverifiable.*
- [x] **Comment truth pass:** `NormalizeAppleErrors`' unwrap comment and
      `ToolObservation`'s status comment gain the one clause A1 makes true
      ("the driver emits the `.failed` record from its catch path"). *(The
      audit's B5/B6 comment fixes landed 2026-08-13 with batch B, ahead of
      this plan.)* Both done, each stating what was *aspirational* before A1
      rather than only what is true now — the paraphrase-don't-quote rule, so the
      next retired-phrase sweep does not re-report a fixed site.

**Review gate:** ✅ **passed 2026-08-15.** Both suites green with the new tests
(**429**: 406 + 23, warning-free) **on both substrates** — `swift test` on the
macOS 27 host and `xcodebuild` on the iOS 27 simulator. Five mutations run, five
caught, all reverted. D44 resolved; D38–D43 reviewed and **promoted to Accepted**;
four new decisions taken (D46–D49) — three of which correct gaps in D39/D41/D42
rather than merely confirming them. A-findings closed, with **two of the audit's
characterisations corrected by measurement** (A2's mechanism, and A1's duration
attribution). Rev 10 items 1–3 confirmed accurate; item 8 is now determined by
D44's choice.

---

### Phase 1 — `overlay_live` against the waiting harness (tier 1)

**Status:** ✅ **done 2026-08-15 — 435 tests green** (412 `LedgerKit` + 23
`Understudy`, warning-free, both substrates, deep tier included).
**The no-assertion-changed criterion is met and verified by diff:**
`ProjectionCheckTests.swift` is **untouched**, and the only edit to
`ProjectionChecks.swift` deletes its now-duplicated `LiveSet` typealias. Three
mutations run; **one was not caught, and finding out why closed a coverage hole
two milestones old** — see the A-note below.

**Goal:** the pure half of the milestone — the overlay function, P2 completed
over the corpus, no assertion changed.

- [x] **`Projection/Overlay.swift`**: `overlay_live` per D40 — flip
      `.interrupted → .streaming(partial: liveSet[generation])` for live
      generations, identity otherwise. Pure, `@Sendable`, no clocks, no I/O —
      §6.3's third stage, finally written.

      **Landed as `overlay(_:live:)`** — a free `nonisolated` function beside
      `fold` and `classify`, since it is the third seam of the same pipeline and
      §6.3 names the seams; the Swift spelling drops `_live` the way the other two
      drop the pipeline notation, and `live:` carries it at every call site.
      `LiveSet` moved into `Projection/` as the production type, so the harness now
      speaks the production vocabulary instead of a parallel copy.

      Two decisions inside it worth recording. **The empty live set returns its
      argument** rather than running a no-op transform — §7.4's
      `overlay_live(…, ∅) ≡ …` stated structurally, and it is also the hot path
      (every cold open, every launch after a crash). And a live generation is
      **flipped unconditionally**, not only from `.interrupted`: for a well-formed
      live set the question never arises (clause 3 ⇒ live ⊆ open ⇒ `.interrupted`),
      and declining to flip would make the projection silently disagree with the
      live set it was handed, so P2 would report a clause-1 mismatch *as well as*
      clause 3's — two fingers pointed at the overlay for a defect one layer up.
      Flipping leaves exactly one failure, naming the store. Asserted:
      `problems.count == 1` on that input.
- [x] **D49 landed as `MessageTree.updateStates(_:)`** — internal, `mapValues`-based,
      so the key set is preserved *by construction* and the overlay cannot drop or
      invent a message however it is written. It sits in `Core/MessageTree.swift`
      rather than beside its caller, breaking the `Payload.updatesIndex` placement
      pattern for a reason with no alternative: `nodes` is `private`, so only that
      file can offer a mutation this narrow, and widening `nodes` to internal to
      relocate one method would hand the whole module the tree-rebuilding power the
      method exists to withhold.
- [x] **P2 completed:** every existing `ProjectionChecks` sweep re-run with
      `overlay_live` in the seat `identityOverlay` and `referenceOverlay`
      occupied — empty-live-set sweeps unchanged (the degenerate case is the
      cold open), plus live-set sweeps: for every corpus fixture truncation
      with open generations, construct live sets from subsets of the open set
      (full partial = folded partial + a synthetic unflushed suffix) and
      assert `projectionProblems` returns empty. **The criterion is that no
      assertion in `ProjectionChecks.swift` changes** (M6-PLAN handoff 1); if
      one has to, stop and review — either the harness was wrong for two
      milestones or the overlay is.
      **Done, and the criterion held.** `OverlayTests.p2OverTheCorpus` sweeps every
      fixture × every truncation × **every subset of that truncation's open
      generations** (bitmask over the sorted open set, so the empty subset — the
      cold open — is included). Live partial = folded text + a synthetic unflushed
      tail, the shape D47 says the store computes. Measured: **132 projections, 38
      with something live, 2 concurrent live generations reached.** Non-vacuity is
      pinned in four dimensions using the *measured* values rounded down, including
      that both ends of the three-name table were reached (`.streaming` seen,
      `.interrupted` seen). *The first draft guessed `checks >= 200` and failed
      against the real 132 — the small version of the same lesson twice in one
      milestone: bound on what you measured.*
- [x] **Negative sweeps:** the overlay refuses nothing (it is total), so the
      hostile inputs are *live sets that lie* — a live generation the fold
      says terminated (clause 3 must flag it), a live partial shorter than the
      folded text (clause 1 must flag the mismatch when the projection
      mis-assembles).

      ⚠️ **The second is no longer reachable by an input, and D47 is why.** The plan
      wrote it against D40's original shape, where the *projection* assembled the
      shown partial from folded text plus an accumulator — so a bad assembly was an
      input-level possibility. D47 moved that computation into the store, so the
      overlay shows `live[gen]` verbatim and `shown == live[gen]` holds **by
      construction**. Clause 1 now polices the store's arithmetic rather than the
      overlay's, and is reachable here only as a mutation — which is how it is
      exercised. Not a gap: D47 doing exactly what it was chosen for, turning a
      checked property into an unrepresentable one.
      Clause 3's **two** branches are both swept by input instead — a live
      generation the log says terminated, and one naming no message at all.
- [x] **Mutations:** overlay also rewrites `terminalTimestamp` (P2's
      more-than-state clause must catch); overlay applies to `.failed`
      messages (clause 2); overlay keeps the folded partial and ignores the
      live set (clause 1 — this is D40's first wrong shape, and the mutation
      proves the harness distinguishes it).

      **All three run, and one of them mattered:**
      - *Ignores the live set's value* → caught by clause 1, on all 38 live sweep
        cases plus the unit test.
      - *Rewrites `terminalTimestamp`* → caught by three tests (44 issues). Worth
        recording that **it could not be written at all** through `updateStates`:
        expressing it required first widening `MessageTree` to the general
        `updateMessages(_: (Message) -> Message)` that D49 declined. A mutation
        needing an act of API widening before it can even be typed is the strongest
        available evidence that D49 earned its keep.
      - *Applies to `.failed` messages* → **NOT caught.** The whole suite passed
        with every `.failed` message flipped to `.streaming`. See the A-note.

- [x] **A-note (Phase 1): the corpus had never contained a failure.** The uncaught
      mutation was not a weak clause 2 — it was clause 2 having nothing to look at.
      `Corpus.all` held **eight `.completed` outcomes, two `.cancelled`, and zero
      `.failed`**, so no sweep anywhere in the package had ever seen the most
      complicated state a message can be in: three payloads, the only one carrying
      `Recoverability`, and the entire subject of §8. Not the P2 sweeps, not
      crash-fuzz, not P1/P3, not the invariant predicates.

      This is **the same finding M3 Phase 1 made about healthy logs**, one
      milestone later and by the same route — the golden section's own note reads
      "before Phase 1 the corpus held `rich` and `hostile` alone, so every mutation
      sweep started from a log that was already damaged." That note should be read
      as a standing instruction rather than a historical remark: *ask what the
      corpus cannot express, not only what it does.*

      Fixed the designed way — a new golden fixture, `failedGenerations`, which
      inherits every sweep for free. Two failures, because they are two shapes:
      `genA` fails **with a partial** under `rateLimited(retryAfter:)`, the one
      affordance whose display math reads `terminalTimestamp + retryAfter` (§6.2,
      §8), so this is now the only fixture where that pairing exists to be got
      wrong; `genB` fails with **nothing** — §7.2's zero-token request-time failure
      on a 401, the case §7.2 says would be *unreachable through observation*
      without the outcome boundary, since §11's reauth bubble can only render if the
      error reached the log as an `Outcome`. `dev/` regenerated. With the fixture in
      place, the mutation is caught by clause 2.

**Review gate:** ✅ **passed 2026-08-15.** Tier-1 suites green (412 + 23),
warning-free, **plus** the iOS 27 simulator tier (412/412) and the
`LEDGERKIT_DEEP=1` sweep (38 s). The no-assertion-changed claim verified **by diff,
not memory**: `ProjectionCheckTests.swift` untouched, one duplicated typealias
deleted from `ProjectionChecks.swift`. Mutation results recorded above, including
the one that was not caught and what it exposed. `ImportBoundaryTests` green, so
`Projection/`'s zero beta risk stays a tested property rather than an intention.

⚠️ **One flake worth knowing, because CI runs this substrate.** The first Phase 1
simulator run reported `** TEST FAILED **` with **zero individual test failures**:
the harness logged "Restarting after unexpected exit, crash, or test timeout"
between two suites, and every test after that point was listed as failing because
it never ran. The named suite passed in isolation, and a clean re-run passed
412/412. So the signature to recognize is *a long "failing tests" list with no
`✘` lines anywhere in the log* — that is the simulator harness dying, not a
regression. Recorded rather than dismissed, since a weekly CI run that hits it
will look alarming and is not.

---

### Phase 2 — The feed and the projection types (tier 1)

**Status:** ✅ **done 2026-08-16 — 447 tests green** (424 `LedgerKit` + 23
`Understudy`, warning-free, both substrates). `Projection/` now holds the overlay
and both public types; the store has its feed. **Two of the three planned
mutations turned out to be unfalsifiable, and finding out why produced the
phase's most useful test** — see the mutation notes.

**Goal:** D38/D39's notifications exist store-side; D42's two types consume
them; everything driven by `ScriptedDriver` on any Mac.

- [x] **Store-side feed (D38/D39):** the internal notification stream —
      `.delta` forwarded at signal receipt (in `consume`, *before* the flush
      buffer decision), `.changed` at non-delta append commit, terminal, and
      delete. One stream per subscriber or a broadcast — implementer's call,
      recorded; the D24-style constraint is that notifying is **synchronous
      with the actor's own state change** (no detached hop between the append
      landing and the notification existing, or a `.changed` could describe a
      state a re-pull cannot yet see).

      **As landed:** `StoreNotification` with **three** cases — `.delta`,
      `.changed`, `.deleted`. Delete earns its own case because a reader that
      answered it with a re-pull would have `unknownConversation` thrown at it and
      have to infer a lifecycle fact from an error.
      **Fan-out per subscriber**, keyed by token, with `onTermination` hopping back
      onto the actor to deregister — a conversation view and a list are two
      subscribers and `AsyncStream` has one consumer each.
      **`.changed` is published from exactly one place: `foldForward`.** It is where
      all five write paths converge (`createConversation`, `edit`, `switchBranch`,
      `generate`, `append`), and none can advance the cache without passing through
      — so the alternative was five call sites and a sixth waiting to forget, which
      is how §7.4's pre-terminal flush would have been lost had the wind-down been
      written twice.
      **`shownPartials` is new actor state** (D47): every delta the driver emits
      accumulates there, so the store — and only the store — can say what the whole
      partial is. That is what the plan meant by the feed being the milestone's one
      genuinely new architectural surface: before this, what the user was looking at
      was a local variable inside `consume`.
- [x] **`ConversationProjection` (D42):** subscribe; on `.changed` re-pull
      through the store and rebuild; on `.delta` accumulate and schedule the
      display tick (D42's cadence; `.zero` applies immediately); assemble the
      live set (folded partial + accumulator) and apply `overlay_live`.
      `conversation` is the only published property.

      **Three deviations from D42, all deliberate, all worth confirming at the gate:**
      1. **`async throws` init.** Attaching reads the log (so it suspends) and the
         conversation may not exist (so it can fail). A synchronous initializer would
         have to publish a `Conversation` that is not yet a reduction of anything, and
         the only honest spelling of that is an `Optional` whose `nil` conflates
         "loading" with "deleted" with "the disk failed" — three conditions with three
         responses. Paying once at construction keeps `conversation` non-optional,
         which is what D42 asked for.
      2. **A second published property, `isDeleted`.** Deletion is irreversible and
         out-of-band; the projection freezes its last view and says so. `conversation`
         stays non-optional (a frozen last view serves a screen that is navigating
         away better than a sudden absence), and the app is not left inferring a
         lifecycle fact from a thrown read.
      3. **No accumulator** — D47 removed it, so `.delta` handling is one idempotent
         assignment.
      Also added because it is a real case the plan did not name:
      **`store.liveSet(of:)`**, read at attach. A projection created *mid-generation*
      (list → detail navigation) would otherwise render `.interrupted` for something
      still streaming. ⚠️ **P2 would not have flagged it** — the predicate checks the
      projection against the live set it was handed, and an empty live set is
      self-consistent. Only a person looking at the screen would have noticed, which
      is the class of bug worth naming.
- [x] **`ConversationListProjection` (D41):** subscribe; re-pull
      `conversationSummaries()` on `.changed`/delete. Landed with D46's internal
      `ConversationStore.conversationSummaries()` underneath it — the verb D41
      assumed existed. `.delta` is handled as an explicit no-op case rather than
      falling through a `default`, so a future notification kind has to be decided.
- [x] **Tests, all tier 1 via `ScriptedDriver`:** streaming shows `.streaming`
      with the exact concatenation at cadence `.zero` (P2 clause 1, live);
      terminal flips to `.complete` and the accumulator drops (clause 3 by
      construction); mid-stream `edit`/`switchBranch` re-pulls without
      disturbing the stream (§6.5's legality, now visible); the mapping
      override changes a `.failed` affordance projection-side while
      `store.conversation(_:)` still reports `.default`'s (handoff 3); list
      ordering tracks `last_event_at` and does **not** churn during delta
      flushes (§9's index rule, observed from above); delete removes the row
      and ends the conversation projection coherently.

      All landed, plus mid-generation attach and D48's cadence measurement.
      The no-churn test is bounded on **both** sides: an upper bound alone would
      pass if the list never refreshed at all.

      ⚠️ **Three of these were flaky as first written, and the full parallel suite
      is what found it.** They spun on `projection.live.count == 1` before asserting
      the *complete* text — but that condition goes true after the **first** delta,
      not the last. A driver reaching its pause means it *emitted* three deltas; it
      says nothing about whether the store's consume loop and the projection's feed
      have drained them. Filtered runs passed every time; the parallel suite failed
      two of them. Fixed by spinning on the awaited **content** rather than on
      liveness. Generalizable: *a spin condition must be the assertion's actual
      precondition, not a proxy that happens to precede it* — and a filtered green
      run is not evidence of an async test's soundness.
- [x] **The P2 pipeline test:** a live store mid-generation, `projectionProblems`
      run against the projection's actual output with the store's actual live
      set — the predicate's first contact with fully real inputs on the live
      side.

      ⚠️ **And clause 1 is *tautological* here, which is a limit of P2 rather than of
      the test.** The predicate asserts `shown == live[generation]`, and the overlay
      builds `shown` *from* `live[generation]` — so against a live store the two
      agree by construction **even when the live set is wrong**. Measured, not
      argued: the accumulate-instead-of-assign mutation left this test green and was
      caught only by the test that compares against the script. §10.6's own wording
      is the stronger one — the partial equals *the concatenated deltas*, a claim
      about the **log** — so the test now carries the script's text as an independent
      oracle, and the mutation is caught by three tests instead of one. What the
      predicate still buys here is clauses 2 and 3 and the not-more-than-state checks
      against inputs nobody constructed.
- [ ] **Mutations:** drop the pre-buffer forwarding (deltas only render at
      flush cadence — the display-cadence test must catch the collapse); apply
      a delta twice (clause 1 exactness); notify `.changed` before the fold
      cache advances (the re-pull races — the synchronous-notification
      constraint's test).

- [x] **Mutations:** drop the pre-buffer forwarding (deltas only render at
      flush cadence — the display-cadence test must catch the collapse); apply
      a delta twice (clause 1 exactness); notify `.changed` before the fold
      cache advances (the re-pull races — the synchronous-notification
      constraint's test).

      **Results — and two of the three were not falsifiable as written:**
      - *Deltas forwarded only at flush cadence* → **caught** by three tests, two of
        them via `.timeLimit` expiry, which is what those limits are for. §7.4's two
        cadences collapse into one and the screen simply stops advancing.
      - *Treat the cumulative partial as a suffix* (D47's hazard; "apply a delta
        twice" restated, since assignment is idempotent and cannot be applied twice)
        → **caught**, but initially by only **one** test. See the P2 tautology note
        above; after adding the independent oracle, three.
      - *Notify before the fold cache advances* → **NOT caught, and cannot be.**
        `yield` does not run the subscriber inline, and a subscriber must hop to the
        actor to read — which it cannot do until the store suspends. Since nothing
        suspends between the two statements, no reader can observe the intermediate
        state, so their **order is genuinely unobservable**. D38's constraint is
        therefore satisfied by something stronger than statement order: *the absence
        of a suspension point*. The `defer` placement remains good hygiene against a
        future `await` appearing between them, but it is not what makes the property
        hold, and pretending a test proves it would be theatre.

      **So the constraint was re-derived and then tested properly.** The reorder that
      would *not* self-heal is a **`.delta` arriving after its generation's terminal
      `.changed`**: the projection has pruned the live entry, the delta puts it back,
      and the overlay sits on `.streaming` forever with no further notification to
      correct it. A late `.changed`, by contrast, is harmless — its handling is
      "re-read the latest", which is idempotent. `StoreFeedTests.feedOrderingIsCausal`
      collects the feed directly and pins the whole sequence, and **it does catch the
      detached-hop mutation** (`["changed", "changed", "delta", "delta", "delta",
      "changed"]` — the terminal's notification jumping the queue), which is D38's
      actual prohibition rather than its proxy.

**Review gate:** ✅ **passed 2026-08-16.** Suites green (424 + 23), warning-free,
both substrates, and the parallel suite run three times to confirm the flakes are
gone rather than hiding. Mutations recorded above, including the one that is
unfalsifiable and why. **Still owed at review:** the two types' API against §11's
sketch (which gains its projection lines — §6 item 6, Phase 4); D41's
no-ValueObservation deviation signed off with ADR-003's amendment drafted; and the
three `ConversationProjection` API deviations listed above (`async throws` init,
`isDeleted`, `store.liveSet(of:)`), none of which D42 anticipated.

---

### Phase 3 — End-to-end, the kill-shaped test, and the preview (tier 2 + app)

**Status:** ✅ **done 2026-08-16 — 452 tests green** (429 `LedgerKit` + 23
`Understudy`, warning-free, both substrates) **plus the app target building and
running**. The tier-2 pipeline test found a **real projection bug on its first run**
— see the A-note.

**Goal:** the full pipeline under the projection, recovery demonstrated as the
overlay vanishing, and the exit-criterion preview.

- [x] **Pipeline test** (the `DriverPipelineTests` pattern, one layer up):
      script → `ScriptedLanguageModel` → real session → `GenerationDriver` →
      store → **projection** — `.streaming` grows with the script's text,
      terminal lands, `P2` predicate green throughout. 27-gated, executes on
      host and simulator.

      Landed as `projectionFollowsARealStream`, parked with a `Cue` so the
      mid-stream assertion happens at a point the test chose.

      ⚠️ **What it asserts mid-stream had to be weakened, and the measurement is the
      reason.** At a parked provider the framework has often vended **no snapshot at
      all**, so no delta has crossed the seam and the partial is empty. The demand is
      therefore "`.streaming`, carrying a **prefix**" rather than any particular text
      — the same posture §7.3 already takes for fragment boundaries, for the same
      reason: exact mid-stream text would be asserting Apple's snapshot cadence.
      Exact text is asserted at tier 1, where `ScriptedDriver` hands the store its
      deltas directly. Also: P2's four inputs are read in **one** `MainActor.run`,
      because four separate `await`s are four hops and the predicate would otherwise
      be handed a fold from one instant and a live set from another.
- [x] **A-note (Phase 3): the projection flashed `.interrupted` at the start of
      every generation.** Found by the test above on its first run: at the parked
      point the projection reported `.interrupted(partial: "")` for a generation that
      was *actively running*.

      The cause: the projection read the store's live set **only at init** and
      populated it from `.delta` notifications thereafter — and a generation that has
      started but produced no text yet has no delta to announce it. So for the whole
      window between the start append and the first snapshot, the read side showed
      the one state whose entire job is to mean *this is not running*. Against a real
      model that window is however long the provider takes to say its first word.
      **P2 could not have caught it**: the predicate checks the projection against
      the live set it was handed, and an empty live set is self-consistent.

      Fixed by having a re-pull take the **store's** live set rather than only pruning
      the accumulated one, which splits the work at the generation's two ends: the
      store's view makes a *just-started* generation live before any delta exists, and
      the prune retires a *just-finished* one (the store cannot help there — it still
      holds the slot `.running` between appending the terminal and releasing it).
      What it renders is `.streaming(partial: "")`, which is §6.2's deliberate refusal
      to have a `.pending` state distinct from an empty `.streaming` — that sentence's
      case, finally reachable. Regression test at tier 1
      (`startedButSilentGenerationIsStreaming`), mutation-verified.

      ⚠️ **And the fix introduced a second bug, which the parallel suite caught.**
      Reading the store's live set on re-pull means two sources disagree about *when*:
      the store's view is read **now**, while a queued `.delta` was enqueued
      **earlier**. A re-pull that suspends while deltas pile up behind it returns a
      newer partial than the notifications still waiting — so applying those
      afterwards walked the text **backwards** on screen. Fixed with one rule,
      `record(_:for:)`: a shown partial never shortens. Sound rather than heuristic,
      because a generation's partial is append-only (§7.3), so of two values the
      longer is always the later.
- [x] **The kill-shaped test (the roadmap's "recovery = overlay vanishing"):**
      mid-generation, tear down the projection; rebuild a fresh projection
      (and a fresh store over the same database — the D29-style honest cold
      open); assert the same message now reads `.interrupted` with the
      *flushed* partial — the three-name table read right-to-left, with no
      recovery pass anywhere to point at. The delta between what streaming
      showed and what recovery shows is exactly the unflushed tail — §7.4's
      documented recovery granularity, now asserted rather than described.

      Landed as `RecoveryTests`, **tier 1 rather than tier 2** — a crash is modelled
      by dropping a projection and reopening a store over the same database, and
      neither needs a real session, so it is worth strictly more on any Mac. Three
      tests: the recovery itself (with the unflushed-tail delta asserted as
      arithmetic), P2's degenerate case as **value equality** (`projection ==
      classified`), and **DoD-1's second half** — the interrupted partial survives as a
      sibling and Regenerate works over it.

      Two harness findings, both recorded in `reopened`'s doc:
      **`reopened()` restarted the identifier stream**, which is right for a read-only
      reopen and wrong the moment the reopened store *writes* — it re-mints
      identifiers the first store used, and the new events quarantine. ⚠️ The failure
      did **not** look like a collision: the regeneration's `generationStarted`
      quarantined while its paired `activePathChanged` survived, naming an endpoint
      that happened to be the *user* message, so the active path silently got
      **shorter** instead of growing. It now takes identifier seeds.
      Separately, the flush-bound arithmetic was misread as cumulative: the buffer
      **resets after every flush**, so the bound applies per accumulation, not per
      generation. The fixture spells the split out rather than assuming it.
- [x] **The preview (D43):** the debug view in the `Projection` app target —
      the exhaustive `switch message.state` showpiece over a
      `ConversationProjection`, driven by `GenerationDriver` +
      `ScriptedLanguageModel`. Built from the workspace; a human confirms
      "renders smoothly" at the gate (the cadence *tests* are Phase 2's; the
      preview is the eyeball check the roadmap asked for).

      Landed as `Projection/Projection/StreamingPreview.swift`. **The app target had
      no dependency on either package** — Xcode's default template, empty
      `packageProductDependencies` — so the project file was patched to link
      `LedgerKit` and `Understudy` from the workspace. Verified by building
      (`** BUILD SUCCEEDED **`, warning-free) rather than by inspection.
      **Launched in the iOS 27 simulator and driven**: the full pipeline renders —
      user message, assistant response, the exact scripted text. Script pacing raised
      to 900 ms per fragment because at 400 ms the whole generation finished inside
      one screenshot round trip, which is a fair proxy for "too quick for a human to
      watch".
      ⚠️ **The mid-stream frame is the human's check, not mine**: screenshot latency
      (~2–3 s) outruns the script, so the settled frame is what a screenshot catches.
      The panel is open and `Send` is bottom-left. Streaming itself is asserted by
      tests at both tiers.
- [x] **§11 sketch extended and its 27-gated sibling updated** — the projection
      lines run against the real driver, completing the sketch-as-acceptance-
      test through the read side.

      `apiSketch` is now `@MainActor` (which *is* §11's isolation sketch, not an
      accommodation of it) and constructs both projections, the mapping override, and
      the exhaustive switch over `projection.conversation`. The 27-gated sibling in
      `DriverPipelineTests` gained the same lines.
      ⚠️ **One divergence recorded rather than glossed:** §11 sketches the list as
      `projection.conversationList`, implying one facade owning both. D42 declined the
      facade, so the spelling is two types. Rev 10 item 6 lands the wording.

**Review gate:** ✅ **passed 2026-08-16.** Tier-2 suite green on both substrates
(429 + 23, warning-free); the app target builds and runs. The kill-shaped test is
DoD-1's automated sibling and M8 inherits it directly. Healthy-log property green
over every log this phase wrote, including the crashed ones — an interrupted
generation is a *well-formed* log, which is why recovery needs no repair.
**Still owed at review:** the preview's mid-stream smoothness (a human tapping
Send), and Phase 2's outstanding items (D41's ADR-003 amendment, the three D42
deviations).

---

### Phase 4 — Wrap-up: rev 10 ratification + alignment

**Status:** ✅ **done 2026-08-16 — rev 10 ratified.** The inventory is finalized at **13 items in
five batches** and drafted to a scratch file; every retired sentence was
**re-verified against `SPEC.md` before drafting** (the rule M4-PLAN §2 exists for),
and all 13 citations were confirmed accurate. Awaiting item-by-item sign-off — nothing
in `SPEC.md` is touched until then. ROADMAP alignment and the handoff verification are
done; CLAUDE.md waits for ratification so it does not have to claim a rev that has not
landed.

- [x] §6's inventory finalized; draft to a scratch file; item-by-item
      sign-off; land in batches with the per-batch `Sources/**` retired-phrase
      sweep; **rev 10 ratified 2026-08-16** (Appendix H).

      **Batches:** A (§7.6's tool obligations — items 1, 11) · B (the read side —
      6, 7, 10) · C (enforcement points and TLC's real layer — 8, 9) · D (P2's
      clause 1 — 13) · E (housekeeping — 2, 3, 4, 5).

      ⚠️ **Nothing in rev 10 touches the wire** — no event kind, payload shape or
      discriminator — confirmed item by item.

      **The code-side sweep was run *before* drafting**, which is the reverse of the
      usual order and paid for itself: it says which batches drag code edits along,
      and it found one item where the *code is already right and the spec is wrong*.
      - `GenerationDriver.swift:32` already describes the session cache as headroom
        rather than as shipped — so **item 2 aligns the spec to the code**, and no
        code edit rides along. (A pleasant inversion of the usual failure, where prose
        outlives the behaviour it described.)
      - `Policies.swift:43` quotes §7.4's retired "renders smoothly" wording — rides
        with batch B.
      - `ProjectionChecks.swift:10` and `ProjectionCheckTests.swift:127` both quote
        §10.6's "concatenated deltas" — ride with batch D. ⚠️ Both are **comments**;
        the no-assertion-changed criterion is untouched.
- [x] ADR-003's D41 amendment landed beside batch B (ADR edits are not spec edits,
      but the same sweep discipline applies). It records the **trigger that would
      reopen** the decision — a second writer — because "we declined it" and "we
      declined it *given one writer*" are different decisions and only the second is
      true.
- [x] **Alignment (ROADMAP + handoffs done; CLAUDE.md waits for ratification).**
      ROADMAP M7 struck through against its exit criteria — **and
      the header line checked explicitly** (the M5 and M6 audits both caught
      it stale; it is now a named checklist item, not a hope); CLAUDE.md
      status rewritten with the M7 landmarks (`Projection/` no longer empty,
      the feed's existence, the two public types, new test counts, **the
      `Formal/` models and the two test-side landmarks `LogGenerator.swift`
      / `GeneratedLogSweepTests.swift` with its `LEDGERKIT_DEEP` gate**); this
      plan's §8 filled; §9/§10 logs closed.
      ✅ **The header line was accurate this time** — it already said rev 10
      "ratifies at the M7 boundary", which is still true. Named as a checklist item
      because the M5 and M6 audits both caught it stale; this is the first boundary
      where it needed nothing.
- [x] Handoffs to M8/M9 (§7) verified against what actually landed — with four
      corrections and three additions, including one instruction discharged: the
      projection was asked to report whether it wanted whole-tree traversal, and it
      **did not**, which is pricing evidence *against* ENHANCEMENTS entry 1 rather
      than for it.

---

## 6. Rev 10 inventory (amendments M7 expects — draft at Phase 4, not from memory)

Seeded from the M6 boundary audit (2026-08-13); extend as phases surface more.
Item 4 is **already decided** and awaits only the wording pass.

1. **§7.6 — the failed-invocation recording obligation** (pairs with Phase 0
   A1; owner-approved direction 2026-08-13). §7.6 describes the record and §8
   asserts the channel fires; nobody states the driver obligation. One
   sentence: a failed invocation is recorded with `status: .failed` before the
   terminal — name from the wrapper, duration where the call was observed,
   payloads per policy — which is what makes §8's "two facts, two events"
   literally true.
2. **§7.8 — the cardinality parenthetical describes headroom as if shipped.**
   "(an internal cache keyed by `ConversationID` — the §7.1 KV-cache
   optimization)" reads as implementation; v0.1 rebuilds per generation (D33)
   and no cache exists. Reword to allowance-plus-reality: v0.1 rebuilds per
   generation; a reuse cache is legal headroom that must carry its own
   validity rule.
3. **§12 — cut line 4's text versus its invocation.** The line still reads
   "ship on-device + Claude-package mappings only"; the invocation shipped
   no Claude package and *wider* Apple-side breadth (§8's second table).
   Annotate invoked-with-outcome. *(ROADMAP's copy already annotated,
   2026-08-13.)*
4. **§13 DoD-2 — restated (decided 2026-08-13).** "Swap `SystemLanguageModel`
   → Claude provider package" becomes: **one-line driver-init swap
   demonstrated against a second real provider** — `PrivateCloudComputeLanguageModel`,
   the genuinely non-on-device Apple provider §8 already maps — with the
   Claude package as the demonstration of choice if a later beta ring carries
   it. The product claim is the one-line swap, not the vendor. *(ROADMAP M8
   already carries the restatement; §13 lands it at ratification.)*
5. **§8 — a watch-note on `emptyResponse` vs `decodingFailure`.** Apple's
   deprecation chain names `GeneratedContent.ParsingError` as
   `decodingFailure`'s replacement; LedgerKit lands the two on different
   `code`s. Correct for v0.1 (plain-`String` only, so a 27 `ParsingError` *is*
   an empty response); when v0.2 requests guided generation, `ParsingError`
   will conflate two conditions under a code that names one. One sentence now
   prevents a confused triage later.
6. **§11 — the sketch gains its projection lines** once D42's shapes are real
   (Phase 2 gate): constructing the two projections, the mapping override
   riding the projection, the exhaustive switch shown against
   `projection.conversation`.
7. **§7.4 — record the feed's shape if the wording warrants it** (the way D32
   earned its §11 lines): the spec already says "fed by the store" and "deltas
   hop at display cadence"; if D38/D39 add anything a *consumer* can observe,
   say it — otherwise no text change, and the spec stays implementation-silent.

   **Phase 2's answer: two things are consumer-observable and one is not.** The
   notification shapes and their ordering are internal and stay unsaid. But
   **attaching mid-generation shows the live partial** — a projection created while
   a generation streams renders `.streaming`, not `.interrupted` — and that is a
   promise an app depends on when it navigates from a list into a streaming
   conversation. And **deletion is surfaced rather than thrown** (`isDeleted`),
   which §9's "irreversible, out-of-band" prose does not currently reach the read
   side to say. One sentence each, in §7.4 and §9 respectively.
13. **§10.6 — P2's clause 1 needs its scope stated, because the harness implements
    something weaker than the wording** (found at Phase 2 by a mutation that
    survived). §10.6 says the projection shows "`.streaming` with partial equal to
    the concatenated deltas" — a claim about the **log**. The predicate compares the
    shown partial against the **live set** instead, which is the only thing available
    when the live set is synthetic (the M4→Phase 1 sweeps) but is *tautological*
    against a live store, since the overlay builds the shown partial from the live
    set. So clause 1 as implemented polices the overlay's fidelity to its input, and
    the wording's stronger claim — that the input itself equals the log's deltas plus
    the unflushed tail — is a **store** obligation needing an independent oracle.
    Say which is which, because a reader checking "is P2 green?" would otherwise
    reasonably conclude the stronger property is under test.
8. **§6.5 / §9 — the healthy-log property needs a stated enforcement point.**
   Rev 8 established "store-written logs never quarantine" and rev 9 left it a
   claim about store *discipline*. A3 shows discipline is not enough: an
   **interleaving**, not a coding slip, can make the store write a log that
   quarantines under row 5 forever — and an app is invited by §6.5 to read
   non-empty `diagnostics` as evidence of damage or of a newer writer, which is
   only sound if the store genuinely cannot contribute noise. **D44 adopted
   `guard`, so the amendment is the larger of the two options:** §9 gains one
   sentence for the write-boundary rule (a batch that would be a conversation's
   first row must *be* its genesis, refused inside the append transaction) and
   §6.5's property cites it — turning a maintained property into an **enforced**
   one, which is tenet 1 applied to the persistence seam. Worth landing with the
   reason D44 turned on: the property is about *logs*, so an in-memory guard could
   never have been the right unit however carefully it was written.
9. **§6.3 — the TLA+ aside points at the wrong layer, and there is now
   evidence.** The section says I1–I7 "are a page of TLA+/PlusCal if you want
   the formal version… model-checking I5 against random truncation is exactly
   what TLC is for." Both halves were testable claims and both came out the
   other way. The reducer is pure, total and single-threaded, and is already
   swept exhaustively *in the real code* — every fixture, every truncation,
   every interior gap, and since 2026-08-15 generated logs as well — so a model
   of it would restate the reducer, add an abstraction gap, and buy only shape
   diversity that bounded-exhaustive Swift generation buys without one. Where
   TLC actually paid is the layer §6.3 does not mention: the store's
   concurrency, where it reproduced A3 in ten states in under a second and then
   **falsified the remedy the audit had proposed**. Reword to point at
   §6.5/§9's interleavings rather than §6.3's invariants, and record the
   encoding that makes it cheap — *a PlusCal label is an `await`*, so Swift
   actor reentrancy transcribes into PlusCal rather than being interpreted into
   it. Appendix A's "Model-checking a chat app" line gains a better subject at
   the same time.
10. **§7.4 — "deltas hop to the main actor at display cadence (~a frame)" needs
    one clause** (from D48, Phase 0). The wording reads as though the projection
    must run a timer, and it should not: `@Observable` + SwiftUI already coalesce
    invalidations per frame, so a timer buys no smoothness — it buys less
    projection *work*. Say that the cadence is a work-reduction knob whose default
    is immediate application, and that "~a frame" is the observation system's
    guarantee rather than the projection's. Only land it if Phase 2's measurement
    supports the default; otherwise D48 is revised instead and this item drops.
11. **§7.6 — a note that a failed invocation's *duration* is often unreportable**
    (from A1's measurement, Phase 0). §7.6 says the record carries duration, which
    is true of a completed invocation and frequently false of a failed one: when a
    tool call is the model's first action the framework vends no snapshot before
    the throw, so nothing about the call is ever observed and only its *name* is
    recoverable. One sentence, because an app reading `duration == nil` should know
    it means "not observed" rather than "instantaneous". Pairs with item 1.
12. Anything Phases 1–3 surface — logged here as discovered.

---

## 7. Explicit handoffs (recorded so they aren't lost)

*Verified against what actually landed, 2026-08-16.*

**To M8 (the demo):**
1. ✅ **The skeleton exists and runs:** `Projection/Projection/StreamingPreview.swift`
   — the exhaustive `switch message.state` showpiece over a `ConversationProjection`,
   driven by `GenerationDriver` + `ScriptedLanguageModel`. M8 styles it and adds the
   branch switcher and kill/relaunch flow. Two things M8 inherits that are *not*
   obvious: the app target's project file was patched by hand to link both packages
   (it had no dependency at all), and the preview's script needs its **pacing** —
   without the `.wait` steps the framework coalesces everything into one snapshot and
   nothing appears to stream.
2. **DoD-2 runs against PCC** (decided 2026-08-13; rev 10 item 4): the
   one-line swap is `GenerationDriver(model:descriptor:)` with
   `PrivateCloudComputeLanguageModel` and an explicit descriptor. Claude
   package if a later ring carries it. The preview's `driver()` method is
   deliberately the only line in that file which names a provider.
3. ⚠️ **The demo script must respect the 4096-token budget** (rev 9): two ~2k
   turns exhaust it, so the demo either keeps turns short or wires
   `.reduceContext` into its error affordance — decide at M8 planning, not
   after the demo hits it live.
4. ✅ **The kill-shaped test is DoD-1's automated sibling** (`RecoveryTests`), and it
   covers *both* halves: `.interrupted` with the flushed partial, and the partial
   surviving as a sibling with Regenerate working over it. The GIF is the same flow
   with a hand on the camera. ⚠️ One thing the demo needs that the test fakes: the
   preview is `.inMemory`, so **it cannot show recovery** — swapping that one line to
   `.sqlite(at:)` is what makes DoD-1 demonstrable.
5. **New:** the projection's `isDeleted` is the signal a demo needs to navigate away
   from a deleted conversation. It exists because inferring a lifecycle fact from a
   thrown read is the pattern tenet 1 replaces.

**To M9 (tag `0.1.0`):**
1. The packaging question (root `Package.swift` vs split repos) — inherited,
   and now with **three** things leaning on it: the path dependency, the app target,
   and (new at M7) the app's hand-patched `packageProductDependencies`, which a split
   would have to re-point.
2. `GenerationID` collides with `FoundationModels.GenerationID` inside
   `@Generable` expansions — naming review (ADR-002 territory, not a passing
   decision).
3. ADR-001 ratifies at M9; ADR-003's file-protection revisit; the
   ENHANCEMENTS backlog. ✅ **Checked at Phase 2 as instructed: the projection did
   *not* want whole-tree traversal.** It needs keyed lookup (`generationID` →
   message) and the active path, both of which exist. That is pricing evidence
   *against* entry 1 rather than for it — the one consumer most likely to need a
   traversal did not.
4. DocC (ENHANCEMENTS entry 2) — the recovery-story article's spine is §6.3's
   three-name table, which Phase 3's kill-shaped test now executes; write the
   article against the test. Its best single figure is the unflushed-tail
   arithmetic: what streaming showed *minus* what recovery shows *is* the flush
   policy, asserted in `killMidStreamRecoversAsInterrupted`.
5. **New:** `MessageTree.updateStates` and `Message.visibleText` are both internal
   and both live in slightly odd places — the first in `Core/` (forced: `nodes` is
   private), the second in `Session/` despite having nothing to do with Foundation
   Models. Worth one look during M9's API review; neither is public, so neither is
   urgent.

---

## 8. Coverage traceability (fill at Phase 4)

| Obligation | Suite / evidence | Status |
|---|---|---|
| A1: failed tool invocation recorded (`.failed`, name, unwrapped terminal) | `GenerationDriverTests.failedToolInvocationIsRecorded` | ✅ 2026-08-15 |
| A1: the record lands even when the call was never observed (no fabricated duration) | `GenerationDriverTests.unobservedFailedCallIsStillRecorded` | ✅ 2026-08-15 |
| A2: `argumentsJSON` is **order-stable** JSON — the audit's "parses as JSON" test passes against the bug | `GenerationDriverTests.argumentsAreOrderStableJSON` | ✅ 2026-08-15 |
| A3: delete vs new starter — no genesis-less rows, under D44's `guard` | `StoreDeletionTests.starterRacingTheDeleteIsRefused` | ✅ 2026-08-15 |
| A3: a starter during delete's cancel-and-wait (covered by single-flight, *not* the guard) | `StoreDeletionTests.starterDuringTheWindDownLeavesNothing` | ✅ 2026-08-15 |
| A3: the interleaving that falsified the tombstone — starter's existence read *before* the delete, its `reserve` *after* completion | `StoreDeletionTests.staleExistenceReadIsRefused` | ✅ 2026-08-15 |
| A3: the write boundary refuses a non-genesis first row, and needs no genesis on a later batch | `PersistenceAppendTests.genesislessFirstRowIsRefused` / `.laterBatchNeedsNoGenesis` | ✅ 2026-08-15 |
| A3: a genesis-less log **already on disk** still reads as `unknownConversation` | `StoreLifecycleTests.genesislessLogIsUnknown` (via `PrewrittenStore`) | ✅ 2026-08-15 |
| A3: TLC reproduces the shipped bug (`Fix = "none"` fails) — the model's calibration, re-run when the await structure changes | `Formal/LedgerStore.tla` | ✅ 2026-08-15 |
| A4: wrapped cancellation not recorded as failure (reachable half) | `GenerationDriverTests.spuriousCancellationIsNotAStop` | ✅ 2026-08-15 |
| Playground: the example compiles **and runs** against public-only API | scratch SwiftPM target over `LedgerKit` (not in-repo) | ✅ 2026-08-15 |
| P2 over the real overlay, no assertion changed | `OverlayTests.p2OverTheCorpus`; criterion verified by `git diff` of `ProjectionChecks.swift` / `ProjectionCheckTests.swift` | ✅ 2026-08-15 |
| The empty live set is the identity — §7.4's theorem, as value equality | `OverlayTests.emptyLiveSetIsTheIdentity` | ✅ 2026-08-15 |
| Clause 3, both branches, by input: a terminated generation and one naming no message | `OverlayTests.liveSetOutrunsTheLog` / `.liveSetNamesNoMessage` | ✅ 2026-08-15 |
| The corpus reaches `MessageState.failed` at all (partial + zero-token shapes) | `Corpus.failedGenerations`, inherited by every sweep | ✅ 2026-08-15 |
| Display cadence independent of flush cadence | `ConversationProjectionTests.streamingShowsTheExactText` (a policy that cannot flush, so any text on screen bypassed disk) | ✅ 2026-08-16 |
| The feed's causal order: a generation's deltas all precede its terminal | `StoreFeedTests.feedOrderingIsCausal` — catches the detached-hop mutation D38 forbids | ✅ 2026-08-16 |
| A projection attaching mid-generation shows the live partial, not `.interrupted` | `ConversationProjectionTests.attachingMidGenerationSeesTheLiveText` | ✅ 2026-08-16 |
| D48's knob measured, not assumed: a non-zero cadence does strictly less overlay work | `ConversationProjectionTests.displayCadenceCoalesces` | ✅ 2026-08-16 |
| Overlay flips state only — structurally, via `MessageTree.updateStates` (D49) | `OverlayTests.overlayTouchesOnlyState`, plus the mutation that needed API widening to express | ✅ 2026-08-15 |
| Clause 1 exactness — a **store** obligation since D47, not the overlay's | `ConversationProjectionTests.streamingShowsTheExactText` and `.p2AgainstALiveStore`, both against the **script's** text — P2's own clause 1 is tautological here | ✅ 2026-08-16 |
| Live ⊆ open, terminal drops the live entry (clause 3, by construction) | `ConversationProjectionTests.terminalDropsTheLiveEntry` — pruned from the base on re-pull, so no "generation ended" notification is needed | ✅ 2026-08-16 |
| Mapping override rides the projection, store keeps `.default` | `ConversationProjectionTests.mappingOverrideRidesTheProjection` | ✅ 2026-08-16 |
| List tracks the index, no delta-cadence churn (bounded both sides) | `ConversationListProjectionTests.listTracksTheIndex` / `.deltaFlushesDoNotChurnTheList` | ✅ 2026-08-16 |
| Deletion surfaced coherently; the last view frozen | `ConversationProjectionTests.deletionIsSurfaced` | ✅ 2026-08-16 |
| P2 against a live store mid-generation (clauses 2–3 on real inputs) | `ConversationProjectionTests.p2AgainstALiveStore` | ✅ 2026-08-16 |
| Kill-shaped recovery: overlay vanishes, `.interrupted` shows through | `RecoveryTests.killMidStreamRecoversAsInterrupted` — with the unflushed-tail delta asserted as arithmetic | ✅ 2026-08-16 |
| P2's degenerate case after a crash, as **value equality** | `RecoveryTests.recoveredProjectionEqualsTheFold` | ✅ 2026-08-16 |
| DoD-1's second half: the interrupted partial survives as a sibling, Regenerate works | `RecoveryTests.interruptedPartialSurvivesRegeneration` | ✅ 2026-08-16 |
| A started-but-silent generation renders `.streaming`, never `.interrupted` | `ConversationProjectionTests.startedButSilentGenerationIsStreaming` — the Phase 3 A-note's regression test | ✅ 2026-08-16 |
| Pipeline through real session under the projection (tier 2) | `DriverPipelineTests.projectionFollowsARealStream` | ✅ 2026-08-16 |
| §11 sketch incl. projection lines runs against the real driver | `APISketchTests` (tier 1) + `DriverPipelineTests.sketchRunsAgainstTheRealDriver` (tier 2) | ✅ 2026-08-16 |
| The exit-criterion preview exists, builds and runs | `Projection/Projection/StreamingPreview.swift`; app target links both packages | ✅ 2026-08-16 (mid-stream smoothness pending a human) |
| Healthy-log property over every M7-written log, **including crashed ones** | `RecoveryTests`, `DriverPipelineTests`, `APISketchTests` | ✅ 2026-08-16 |
| Rev 10 amendments carried into code (per-batch retired-phrase sweep) | 5 batches, 5 sweeps; 4 code/test sites updated (`Policies.swift`, `Persistence.swift`, `ProjectionChecks.swift`, `ProjectionCheckTests.swift`) + 1 forward-pointer in `NormalizeAppleErrors.swift`; final sweep clean on all 9 retired phrases | ✅ 2026-08-16 |

---

## 9. Decision log

| # | Decision | Status |
|---|---|---|
| D38 | The store notifies via an internal `AsyncStream`; the projection subscribes; unbounded buffering (the `GenerationChannel` argument) | **Accepted** 2026-08-15 (proposed 08-13) |
| D39 | Deltas cross by value (pre-buffer, at signal receipt); everything else by `.changed` invalidation + re-pull; no tool-record shape | **Accepted as amended** 2026-08-15 — **superseded in part by D47**: the delta payload is the *cumulative* shown partial, not a suffix |
| D40 | The overlay flips `.interrupted → .streaming` and shows the live set's value as the full partial; the projection assembles folded + accumulated; P2 clause 1 polices the assembly | **Accepted** 2026-08-15 — D47 removes the assembly step, so clause 1 now polices a value the store computed |
| D41 | `conversationList` by store notification + `conversationSummaries()` re-pull; **GRDB `ValueObservation` deliberately not wired**; seam stays six verbs; ADR-003 amended to record the declined exception | **Accepted** 2026-08-15 — deviation signed off; **completed by D46**, which supplies the store verb this decision assumed existed |
| D42 | Two public types (`ConversationProjection`, `ConversationListProjection`); mapping + display cadence as init parameters; no facade | **Accepted** 2026-08-15 — cadence default revised by D48 |
| D43 | The exit-criterion preview lives in the `Projection` app target as the demo's skeleton; the Playground stays a reducer example | **Accepted** 2026-08-15 |
| D44 | **A3's remedy: `guard`, adopted alone.** Refuse a non-genesis first row inside the append transaction; the tombstone is dropped entirely, not even kept as an affordance. The deciding argument: `guard` is a claim about the **log**, both tombstones are claims about one **process's memory**, and §6.5's healthy-log property is a property of logs — so enforcement belongs where logs are written, and a retained tombstone would only invite the next reader to mistake it for the protection | **Accepted** 2026-08-15 |
| D45 | `Formal/` is a repo artifact, not a scratch spike: TLA+/PlusCal models of the store's interleavings, calibrated by requiring TLC to reproduce a known-real bug before any of its other results are believed. Not wired into CI (no Java in the toolchain contract); re-run by hand when `ConversationStore`'s await structure changes | **Accepted** 2026-08-15 |
| D46 | **The store gains a second read verb**, `conversationSummaries()`, **internal** like `liveGenerations`. D41 assumed it existed; it did not — the index read lived only on the `PersistenceStore` seam, and D28 says the store exposes exactly one read verb. §11 is satisfied because it forbids *synchronous* reads, and an `async` summaries verb has `conversation(_:)`'s shape exactly. Internal keeps D42's public surface at two types; ADR-003 rule 4 is untouched, since that caps the **seam**, not the store | **Accepted** 2026-08-15 |
| D47 | **The feed carries the cumulative shown partial, not a suffix.** D39's accumulate-and-reconcile shape has two holes: a flush landing between a `.delta` and a `.changed` re-pull puts the same text in both the base partial and the accumulator (**double-counted** — D40's own named wrong shape, arriving through the feed rather than the overlay), and a projection created *mid-generation* (list → detail navigation, an ordinary case) starts with an empty accumulator and needs the base partial, so the two cases want opposite rules. The store already holds both halves (folded partial + `DeltaBuffer.text`), so it computes the whole partial trivially; the projection's rule becomes one idempotent assignment. Cost is one string copy per delta arrival — boring and measurable, against a correctness hazard that would otherwise need a rule in three places | **Accepted** 2026-08-15 |
| D48 | **Display cadence defaults to `.zero`.** SwiftUI already coalesces `@Observable` invalidations per frame, so a ~16 ms timer buys no smoothness — it buys less *projection work* (one `overlay_live` + tree rebuild per delta rather than per frame), which is a different and unmeasured benefit. A non-zero default also means every app pays a latency floor and every test injects `.zero`, and "the default is the thing tests don't use" is a smell. The knob stays; **Phase 2 counts `overlay_live` invocations at both settings** so its value is measured rather than assumed. Rev 10 item 11 if §7.4's "~a frame" wording needs the note | **Accepted** 2026-08-15 |
| D49 | **The overlay is made structurally unable to touch anything but state.** `MessageTree` gains a narrow internal state-setting mutation rather than the overlay rebuilding a tree through `init(nodes:rootChildren:)`. P2's "more than its state overlaid" clause then becomes belt-and-braces instead of the only defence — tenet 1 applied to the read side, the same move `FoldedMessageState` already makes one layer down | **Accepted** 2026-08-15 |

## 10. Status log

| Date | Phase | Tests | Note |
|---|---|---|---|
| 2026-08-13 | **Plan drafted** at the M6 boundary | 415 (392 + 23) | Drafted from the M6 boundary audit. Phase 0 carries the audit's A1–A4 (A1/A3 owner-approved 2026-08-13); rev 10 inventory seeded with one item already decided (DoD-2 → PCC). Batch B's mechanical staleness fixes (ROADMAP header/banner/beta-track/cut-line, ADR index, two stale code comments) landed the same day, ahead of Phase 0 |
| 2026-08-16 | **Phase 3 done** — tier-2 pipeline, the kill-shaped test, the preview | **452 (429 + 23)** | Both substrates green; the `Projection` app target builds, links both packages, and runs in the simulator. **The tier-2 test found a real bug on its first run:** the projection read the store's live set only at *init*, so between `generationStarted` and the first delta it rendered `.interrupted` for a generation that was actively running — a visible flash of the crash state at the start of every generation, and **P2 could not have caught it** because an empty live set is self-consistent. The fix (a re-pull takes the store's live set) then introduced a *second* bug the parallel suite caught: the store's view is read now while a queued `.delta` was enqueued earlier, so applying stale notifications walked the text **backwards**; closed by one rule — a shown partial never shortens, which is sound because §7.3 makes partials append-only. Two harness findings: `reopened()` restarted the identifier stream (right for a read-only reopen, wrong once it writes — and the collision surfaced as the active path getting *shorter*, not as a collision), and the flush bound is per-accumulation, not cumulative. The kill-shaped test landed **tier 1** rather than tier 2, since a crash needs no real session. §11's sketch gained its projection lines at both tiers, with the `projection.conversationList` spelling recorded as a divergence for rev 10 item 6 |
| 2026-08-16 | **Phase 2 done** — the store feed, `ConversationProjection`, `ConversationListProjection` | **447 (424 + 23)** | Both substrates green; the parallel suite run three times to confirm no flakes. `.changed` publishes from **one** place (`foldForward`, where all five write paths converge); `shownPartials` becomes actor state so the store can state the whole partial (D47); D46's summaries verb lands under the list. **Three `ConversationProjection` API deviations from D42, all owed sign-off:** `async throws` init (so `conversation` can be non-optional without `nil` conflating loading/deleted/failed), a second published `isDeleted`, and a new `store.liveSet(of:)` read at attach — without which a projection created mid-generation renders `.interrupted` over a running stream, **which P2 would not have flagged** because an empty live set is self-consistent. **Two of three planned mutations were unfalsifiable, and chasing why produced the phase's best test.** "Notify before the cache advances" cannot be caught: `yield` runs no subscriber inline and a reader must hop to the actor to read, so the two statements' order is unobservable — D38's constraint holds by *absence of a suspension point*, not by ordering. Re-derived the reorder that would genuinely break (a `.delta` after its terminal's `.changed`, which sticks `.streaming` forever) and pinned the feed's whole sequence in `feedOrderingIsCausal`, which **does** catch the detached hop. Also found: **P2's clause 1 is tautological against a live store** — the overlay builds `shown` from `live[generation]`, so they agree even when the live set is wrong; the fix is an independent oracle (the script's text), and the suffix-accumulation mutation went from 1 catcher to 3. And **three tests were flaky as written**, spinning on `live.count == 1` before asserting the complete text; the parallel suite caught what every filtered run had passed |
| 2026-08-15 | **Phase 1 done** — `overlay_live`, P2 completed, D49 landed | **435 (412 + 23)** | Both substrates green plus `LEDGERKIT_DEEP=1`. **The no-assertion-changed criterion held, verified by diff**: `ProjectionCheckTests.swift` untouched; the only edit to `ProjectionChecks.swift` deletes a typealias that `Projection/` now ships. P2 sweeps 132 projections over every fixture × truncation × subset of open generations, 38 of them live, reaching 2 concurrent live generations. **Three mutations run; the one that was *not* caught was the finding of the phase:** flipping every `.failed` message to `.streaming` passed the entire suite, because `Corpus.all` contained **no failed generation at all** — 8 `.completed`, 2 `.cancelled`, 0 `.failed` — so nothing anywhere in the package had ever swept the most complex `MessageState` case, the only one carrying `Recoverability` and the whole subject of §8. Fixed with a `failedGenerations` golden fixture (a failure with a partial, and §7.2's zero-token 401), which inherits every sweep for free. **This is M3 Phase 1's healthy-log finding repeating one milestone later by the same route**, which promotes that note from history to standing instruction: ask what the corpus *cannot* express. Also: the `terminalTimestamp` mutation could not be typed without first widening `MessageTree` past D49's narrow API — the strongest evidence available that D49 was worth taking |
| 2026-08-15 | **Phase 0 done** — the audit's A1–A4, D44 resolved, Playground rewritten | **429 (406 + 23)** | Both substrates green (macOS 27 host + iOS 27 simulator). Five mutations run, five caught. D38–D43 promoted to Accepted; D44 resolved as **`guard` alone**; **D46–D49 taken**, three of which fix gaps rather than confirm the plan: D41 named a store verb that did not exist (D46), D39's suffix-accumulation double-counts and cannot handle a projection created mid-generation (D47), and D42's ~16 ms cadence default duplicates work SwiftUI already does (D48). **Two audit characterisations were corrected by measurement.** A2 is not "the field held unparseable text" — Apple's `debugDescription` *is* JSON, so the test this plan specified passes against the bug; the real defect is **dictionary-order instability** (three processes, three orderings), the per-process hasher seed reaching a durable audit field. And A1's duration is attributable only when a snapshot preceded the throw, which for a tool called as the model's first action never happens. The recurring lesson, now from the other direction: **an audit finding is an empirical claim too** |
| 2026-08-15 | Pre-Phase-0 spike: generated-log sweeps + `Formal/` | 420 (397 + 23) | **Two additions, neither on the critical path, one of which changed a decision.** (1) `LogGenerator.swift` / `GeneratedLogSweepTests.swift` — bounded-exhaustive generated logs over a 26-shape alphabet, closing the corpus's shape-diversity gap (every prior input was a subsequence of ten hand-written fixtures). Four oracles, one new: **containment**, which makes I2's "reduction continues as if the event were absent" executable for the first time. Tiered — length 3 (17,576 logs, ~1s) always, length 4 (456,976, ~25s) behind `LEDGERKIT_DEEP=1`, because the rest of the suite runs in ~1.2s. Found no bugs; mutation-tested to prove the containment oracle is not vacuous. (2) `Formal/LedgerStore.tla` — **TLC reproduced A3 in ten states and then falsified the proposed tombstone fix** (D44, rev 10 items 8–9) |

# LedgerKit v0.1 — Design Specification

**Status:** Draft for ratification — **rev 4**
**Date:** 2026-07-13 (rev 3: 2026-07-12, rev 2: 2026-07-12, rev 1: 2026-07-09)
**Targets:** iOS 27 / macOS 27 (Foundation Models `LanguageModel` protocol as inference substrate)
**Changes from rev 3:** Appendix B.

---

## 1. Positioning

LedgerKit is a durable conversation-state engine for LLM-powered apps on Apple platforms. It is an event-sourced ledger of conversation history, a typed message-lifecycle state machine, and a reconciliation layer between durable app state and ephemeral `LanguageModelSession` working context.

**Elevator pitch:** *The state layer Foundation Models doesn't ship.*

**What changed at WWDC 2026 and why this spec exists in this shape:** Apple's `LanguageModel` protocol standardized the inference boundary. Apple, Anthropic, and Google ship conforming providers; `FoundationModelsUtilities` ships a Chat Completions adapter for OpenAI-compatible servers, in-session summarization modifiers, and a Skills API. The inference layer is now commodity. LedgerKit does not compete with, wrap, or re-abstract any of it. LedgerKit owns everything the platform leaves to the app: durable state.

---

## 2. Boundary map (sherlock analysis)

The single most important design input. Anything in the left column is a non-goal forever, not just for v0.1.

| Apple owns (do not rebuild) | LedgerKit owns |
|---|---|
| Inference protocol (`LanguageModel` + `LanguageModelExecutor`) | Durable persistence across launches |
| Provider packages (on-device, PCC, Claude, Gemini, Chat Completions) | Message lifecycle state machine (streaming → terminal) |
| In-session transcript & context window | Interruption recovery (app killed mid-stream) |
| In-session summarization/compaction (utilities profile modifiers) | Branching: edit, regenerate, sibling responses |
| Prompt patterns / Skills API / Dynamic Profiles | Multi-conversation management: index, lifecycle, metadata |
| Guided generation, tool execution within session | Tool-invocation *record* (audit trail in the ledger) |
| Auth/billing for server models (provider packages) | Typed error → recoverability → UI-affordance mapping |
| Evaluations framework | Export, search (later), sync (much later) |

**Sherlock-risk assessment:** Apple's direction of travel is upward (2025: inference → 2026: providers, compaction, skills, richer context-management and KV-cache APIs). The defensible ground is durable app-level state: platform vendors historically stop at the session boundary and leave persistence, identity, and cross-launch state to apps. A session is not a store. The new context-management APIs sit *adjacent* to this boundary — verifying that they stop at the session edge is on the beta spike list (§14). If Apple ships a "conversation store" in 2027, LedgerKit's residual value is the branching model, recovery semantics, and test infrastructure — but price that risk in: this is a 2–4 year asset, which is the correct horizon for a positioning play anyway.

**The nearer incumbent (rev 4).** The thing LedgerKit actually displaces on day one is not a hypothetical 2027 Apple conversation store — it is the pattern every tutorial already recommends: `Transcript` is `Codable`, so encode `session.transcript` into SwiftData (`@Attribute(.externalStorage)`), reload it through the transcript-seeding initializer, done in twenty lines. The README and the launch post must answer "why not that?" before the reader asks (DoD-4, Appendix A). The answer, mechanically: a blob has no message lifecycle (failed / cancelled / interrupted are indistinguishable from absent); it loses mid-stream partials entirely on crash (the transcript holds completed turns — the kill-mid-stream demo is unimplementable on top of it); it is linear (no edit-as-branch, no regenerate-as-sibling, no branch switcher); it rewrites invisibly (every save is a full-state overwrite — no audit trail, no history); and it has no recovery semantics beyond "whatever was last encoded." Every one of those is a v0.1 goal. The blob is the null hypothesis; this spec exists because the null hypothesis fails five ways.

---

## 3. Design tenets

1. **Illegal states are unrepresentable.** Message lifecycle is a closed enum. No `isLoading: Bool` alongside `error: Error?`. A message cannot be simultaneously streaming and failed.
2. **Event-sourced: the log is the truth.** State is a deterministic fold over an append-only event log. Consequences: crash recovery is structural, not a feature; branching is natural; sync becomes log-shipping later; tests are golden event sequences. Everything else — snapshots, the conversation index, the observable projection — is derived, rebuildable, and deletable.
3. **The inference boundary is Apple's.** LedgerKit consumes `LanguageModelSession` / `any LanguageModel` and never re-exports or wraps those types in its own abstraction. Provider choice is the app's business.
4. **Signals cannot be skipped.** Every generation terminates in exactly one terminal outcome (completed, failed, cancelled) or is derivably interrupted. Recoverability is typed, and the type dictates the UI affordance.
5. **Test doubles are first-class.** A deterministic scripted `LanguageModel` conformer ships in the package; the entire library is testable and previewable with zero network and zero Apple Intelligence eligibility.
6. **Strict concurrency clean.** Swift 6.2, no `@unchecked Sendable` in public API, reduction is pure and isolated from UI.

---

## 4. Goals (v0.1)

- **G1.** Append-only event log with atomic persistence; conversation state derived by deterministic reduction.
- **G2.** Message tree supporting edit-as-branch and regenerate-as-sibling; a conversation view is a path through the tree.
- **G3.** Generation driver that runs a `LanguageModelSession` stream, translating outputs into ledger events, with cooperative cancellation.
- **G4.** Interruption recovery: process death mid-stream is detected at reduction time and surfaces as a typed `.interrupted` message state with partial content. The affordance is **Regenerate**; the partial is retained as its own branch, reachable via the branch switcher. Continuation-style resume is explicitly out of scope (v0.2 research, §12).
- **G5.** Error taxonomy anchored on Apple's built-in `LanguageModelError`, with a `Recoverability` axis mapping errors to UI-actionable categories.
- **G6.** `ScriptedLanguageModel` test double + golden-log fixtures + property-tested reduction invariants.
- **G7.** SwiftUI-observable projection (`@Observable` store) — state only, no view components.
- **G8.** Demo app: chat UI over on-device model, one-line swap to the Claude provider package, kill-and-relaunch recovery demonstrable.
- **G9.** Conversation index: cheap list reads (id, title, timestamps) without reducing every log; create / delete / retitle lifecycle.

## 5. Non-goals (v0.1)

- **N1.** No networking, no providers, no API-key handling. (Apple + vendor packages.)
- **N2.** No prompt templating, personas, or skills. (Utilities package.)
- **N3.** No compaction awareness. In-session compaction is invisible to LedgerKit in v0.1; rehydration materializes the full active path. Accepted consequence, stated honestly (rev 4): a rebuilt session sees more context than the compacted live session it replaces — and may therefore *exceed the window that compaction was hiding*. On-device budgets are small (reported ~4k shared tokens — ⚠️ verify against the beta), so a long on-device conversation can be unregenerable after process death: rehydration fails with `contextWindowExceeded`, which classifies to `recoverableUpstream(.reduceContext)` (§8), and the app-side escape is a utilities compaction pass before retry. The failure is graceful and typed, not silent — but it is a failure, and pretending the consequence is merely "sees more context" undersold it. Compaction bookkeeping arrives in v0.3, and the event carries the summary text (§12) so rehydration and audit can reproduce what the model saw.
- **N4.** No RAG, embeddings, or search.
- **N5.** No sync. The event log is designed to permit log-shipping later; nothing is built.
- **N6.** No UI components. State machine + observation only.
- **N7.** No tool *orchestration*. FM executes tools inside the session; LedgerKit records invocations as events for replay/audit. Driving multi-step agent loops is v0.2+ at most.
- **N8.** No guided-generation structured partials in v0.1 (plain-text assistant content only). The event model reserves room via `Content` (§6.2).
- **N9.** No message-level erasure or redaction — conversation-level delete only (§9). Append-only logs and erasure are in structural tension; resolving it is a deliberate design exercise (v0.2 design doc, §12), not a checkbox.
- **N10.** No assistant-initiated conversations through the v0.1 store API. The *wire format* has headroom — `generationStarted(parent: nil)` is a virtual-root child the reducer accepts (I6) — so enabling model-generated openers later is a store-policy relaxation, not a migration (the §6.5 pattern: log tolerant, store enforces). The v0.1 store simply never emits one.
- **N11.** No transcript-entry-complete rehydration (rev 4, the honest scope of tenet "rebuild from the ledger"). Apple's `Transcript` carries six entry kinds — instructions, prompt, response, tool calls, tool outputs, reasoning. The v0.1 ledger represents the first three (as text) plus tool invocations as `ToolRecord`s; rehydration reconstructs **text + instructions only** (§7.1 fidelity classes). Tool-call/tool-output entries are not re-materialized into rebuilt transcripts under *any* recording policy in v0.1, and reasoning entries are not even recordable (OQ9). v0.2 revisits reconstruction from `.full` tool records (§12).

---
## 6. Core model

### 6.1 The ledger (events)

All Swift below is illustrative of shape, not final API. Names bikesheddable; semantics not.

```swift
public struct LedgerEvent: Sendable, Codable, Identifiable {
    public let id: EventID                     // UUIDv7 — identity only, never ordering
    public let conversationID: ConversationID  // stream identity, on the envelope (rev 3)
    public let sequence: Int64                 // per-conversation monotonic — THE order.
                                               // Int64, not UInt64 (rev 4): SQLite INTEGER is i64
                                               // and JSON tooling degrades past 2^53; the extra
                                               // bit bought nothing but friction.
    public let timestamp: Date                 // stamped by the store at append; display/audit only
    public let payload: Payload

    public enum Payload: Sendable, Codable {
        case conversationCreated(title: String?)
        case userMessageAppended(MessageID, content: String, parent: MessageID?)
        case instructionsChanged(String?)   // nil clears; see §7.1
        case generationStarted(GenerationID, MessageID, parent: MessageID?, model: ModelDescriptor)
                                            // parent nil ⇒ child of the virtual root (I6). The v0.1
                                            // store never emits nil — wire headroom for N10.
                                            // model = the *requested* descriptor (§7.8).
        case deltaAppended(GenerationID, text: String)
        case toolInvocationRecorded(GenerationID, ToolRecord)
        case generationEnded(GenerationID, Outcome)
        case messageEdited(original: MessageID, replacement: MessageID, content: String)
        case activePathChanged(endpoint: MessageID)
        case titleChanged(String?)          // nil clears — symmetric with instructions (rev 4)
    }
}

public enum Outcome: Sendable, Codable {
    case completed(StopInfo)                    // usage, stop reason, resolved model identity (§7.8)
    case failed(GenerationError)
    case cancelled                              // user-initiated; partial content retained
}
```

Ten payload kinds. Resist adding more in v0.1; every event kind is API surface forever (logs persist across versions — see §9 on versioning). (Rev 3 grew the *envelope*, not the kind count; rev 4 again changed only shapes — `titleChanged` went optional, `sequence` went `Int64` — free pre-ratification.)

**Envelope vs payload.** `id` / `conversationID` / `sequence` / `timestamp` are the envelope — bookkeeping about the fact; `payload` is the fact. `conversationID` rides the envelope (standard event-sourcing practice: the stream ID makes an event self-describing) so export, fixtures, debugging, and eventual log-shipping don't depend on SQLite table context to know where an event belongs. An event whose envelope `conversationID` disagrees with the stream it was loaded from quarantines (§6.6) — cross-stream contamination is malformed by definition. Physical note (rev 4): `sequence` lives **only** in the events-table key — the encoded blob omits it, and the in-memory envelope is populated from the column at load, so a blob/column disagreement is unrepresentable (§9). `conversationID` is deliberately duplicated (column *and* blob); that duplication is exactly what §6.6 row 4 checks. A per-*operation* correlation ID (edit = two events, one operation) is deliberately **not** on the envelope yet: operation boundaries live only in DB transactions for now (§9), and promoting them to the wire is an explicit inbox item for the v0.3 sync design doc (§12).

**Ordering.** `sequence` is assigned by the store at append time, inside the append transaction, contiguous from 1 per conversation. It is the sole authoritative order. `EventID` is UUIDv7 for time-*sortable identity* (nice for debugging and future log-shipping), but the reducer never orders by id or timestamp — that would smuggle wall-clock into I1. (Foundation mints v4 only; `EventID` implies a small custom v7 generator — trivial, but it's ours.)

**Gaps (rev 4).** Deletion is conversation-level, so a healthy log has none — a gap means partial restore or external tampering. The reducer tolerates them anyway (I2's spirit: every log reduces): reduction continues across the hole, and each *contiguous* gap appends one `QuarantinedEvent` to diagnostics (first missing sequence; range in the reason) — per-gap, not per-row, so a 10k-row hole costs one diagnostic, not 10k. If the hole swallowed a terminal, I5 does what it always does: the generation reduces `.interrupted`, which is correct — you truly don't know how it ended. Crash-point fuzzing covers suffix truncation; the gap fixtures cover interior holes (§10).

**Timestamps** are stamped by the store at append time; deltas coalesced into one flush share that flush transaction's timestamp. They exist for display and audit only — the reducer never reads them.

**Genesis.** `conversationCreated` is the genesis event: sequence 1, exactly once. Anything preceding it, or a second occurrence, quarantines (§6.6).

**Interruption is not an outcome — and terminals are decode-tolerant.** There is deliberately no `Outcome.interrupted` in the wire format. Interruption is a *derived* message state, synthesized by the reducer from the absence of a terminal event (I5). It cannot be written to a log directly. Rev 2 claimed this made interruption unforgeable and left a hole: quarantining an *undecodable* terminal (a hostile garbage outcome, or an `Outcome`/`GenerationError` case added by a future LedgerKit) removed the terminal from reduction — which is exactly what synthesizes `.interrupted`. The quarantine mechanism manufactured the forgery, and a v0.2 log's new error case would have re-rendered historical *failures* as *crashes* on v0.1 readers. Rev 3 closes it with a tolerant-reader exception: **a `generationEnded` whose nested outcome doesn't decode still lands as a terminal** — `.failed(.unrecognized("undecodable outcome: <discriminator>"))`. Consequences: hostile logs can forge *failures* only (harmless — that is what failures are for); forward compatibility degrades an unfamiliar outcome into a generic failure instead of a fake crash; and I5's meaning stays crisp — `.interrupted` arises only when the terminal is genuinely *absent or unreadable at the row level* (process death, bit rot), never merely unfamiliar. This is the single deliberate asymmetry in decode strictness — everywhere else, a quarantined event is contained loss; terminals are the only events whose *absence* carries meaning (I5), so they alone get the tolerance. ADR-001 owns the rule. Residual honesty: a fully undecodable row that happened to *be* the terminal still yields `.interrupted` — correct, because you truly don't know how it ended.

**Roles.** User messages arrive via `userMessageAppended`; assistant messages exist only as the product of a generation. `messageEdited` applies to user messages only — "editing" an assistant message would create user-authored assistant content, which corrupts the audit trail. An edit naming an assistant message quarantines (§6.6). Rewriting what the assistant said is what Regenerate is for. Role *adjacency*, by contrast, is deliberately **not** a reducer concern (rev 4): a `generationStarted` whose parent is an assistant message (the continuation shape, I7/§12) or consecutive user-authored siblings decode and reduce fine — wire headroom, the N10 pattern again. Enforcement is store policy (§6.5 target eligibility); v0.1's verbs cannot produce these shapes. §6.6 records the non-rule explicitly so the fixture inventory stays honest.

```swift
public struct ToolRecord: Sendable, Codable {
    public var name: String
    public var status: Status                // succeeded / failed
    public var duration: Duration?
    public var argumentsJSON: String?        // populated per recording policy, §7.6
    public var resultJSON: String?           // populated per recording policy, §7.6
}
```

`StopInfo` and `ModelDescriptor` remain illustrative. `StopInfo` carries stop reason and usage from `Response.usage` — usage now spans input/output with cached and reasoning token counts across providers (⚠️ verify exact field names against the beta) — plus `resolvedModelID: String?`, the model identity the provider *reports* on the response (§7.8). `ModelDescriptor` identifies the *requested* provider + model + version well enough for branch-compare across models; the request/resolved split is rev 4's answer to most of OQ8. Pin all fields during the beta spike (§14). Evolution note: structs with optional fields tolerate additive change; *enums* are the evolution cliffs. A new enum case inside a non-terminal payload (e.g. `ToolRecord.Status`) quarantines that event only — contained loss, accepted. Terminals get the tolerance exception above.

### 6.2 Derived state

```swift
public struct Conversation: Sendable {
    public var id: ConversationID
    public var title: String?
    public var instructions: String?            // latest instructionsChanged; nil if never set
    public var messages: MessageTree            // nodes keyed by MessageID; rootChildren = the
                                                // virtual root's children (I6), sibling-ordered
    public var activePath: [MessageID]          // root-level node → endpoint, the "visible" thread
                                                // (virtual root excluded — it is not a message)
    public var diagnostics: [QuarantinedEvent]  // §6.6 residue; empty on healthy logs
}

public struct Message: Sendable, Identifiable {
    public var id: MessageID
    public var role: Role                        // user / assistant
    public var parent: MessageID?                // nil ⇒ root-level (child of the virtual root)
    public var children: [MessageID]             // sibling order = sequence order (§6.4)
    public var state: MessageState               // user messages: always .complete
    public var model: ModelDescriptor?           // assistant only — requested descriptor,
                                                 // from generationStarted (§7.8)
    public var stopInfo: StopInfo?               // assistant only — from Outcome.completed (§7.7);
                                                 // nil otherwise. Recorded-but-unprojectable data
                                                 // is a bug, not privacy (rev 4).
    public var toolRecords: [ToolRecord]         // assistant only; sequence order
    public var timestamp: Date                   // originating event's envelope timestamp
    public var terminalTimestamp: Date?          // terminal event's envelope timestamp (rev 4);
                                                 // nil while open and for .interrupted (no terminal
                                                 // exists — I5). Display/audit; gives
                                                 // rateLimited(retryAfter:) its instant (§8).
}

public struct QuarantinedEvent: Sendable {
    public var sequence: Int64
    public var eventID: EventID?                // nil if the row was undecodable
    public var reason: String
}

public enum MessageState: Sendable {
    case complete(Content)
    case streaming(partial: String)
    case failed(partial: String, GenerationError, Recoverability)
    case cancelled(partial: String)
    case interrupted(partial: String)
}

public struct Content: Sendable {
    public var text: String
}
```

User messages are always `.complete`. Assistant messages traverse the machine. There is deliberately no `.pending` distinct from `.streaming(partial: "")` — collapsing them removed a state with no distinct UI meaning; reintroduce only if a provider exposes a meaningful queued phase.

`Content` is a struct, not a bare `String`, on purpose: N8's structured partials extend it additively in v0.2 without a source-breaking change, and without turning `MessageState` — the exhaustive-switch showpiece — into a moving target. (`stopInfo` and `terminalTimestamp` live on `Message`, not inside the enum cases, for the same reason: the showpiece switch stays stable.)

`Recoverability` in `.failed` is **derived at classification time, never persisted** — see §6.3 (the fold → classify → overlay pipeline) and §8. Two of these states are derived-only in a stronger sense, and they are duals: `.interrupted` is fold-derivable only (dead logs); `.streaming` is projection-only (live stores, via the §7.4 overlay — no fold of any log ever yields it). Neither is wire format.

### 6.3 Reduction invariants

Reduction is a **pipeline, named precisely in rev 4** because snapshots and tests depend on the seams:

```
fold(log) -> FoldedState                      // pure; failures carry GenerationError only
classify(folded, mapping) -> Conversation     // applies mapping: (GenerationError) -> Recoverability
overlay_live(...)                             // projection-side only — §7.4; never part of reduce
```

`reduce(log, mapping) ≡ classify(fold(log), mapping)` is the convenience composition the API exposes. `FoldedState` is `Conversation` minus `Recoverability` — and is exactly the snapshot schema (§9): the middle layer was always implicitly there (snapshots store errors and recompute classifications); rev 4 just gives it a name so the seam is testable (P3, §10). The test suite must enforce:

- **I1 (Determinism, two halves):** Same log ⇒ same `FoldedState`, on every platform, every time — no wall-clock or environment reads inside the fold. Same `FoldedState` + same mapping ⇒ same `Conversation`. The mapping is part of classification's identity; keeping it an explicit input keeps I1 honest while allowing apps to customize (§8).
- **I2 (Totality & quarantine):** Every log reduces without trapping. Semantically malformed events and *undecodable* events (bit rot, unknown payload kinds written by a future LedgerKit) are **skipped**: reduction continues as if the event were absent, and each skip appends a `QuarantinedEvent` (sequence + reason) to `Conversation.diagnostics`. The targeted message is unaffected — a delta-after-end is dropped; the message stays in its terminal state. Sequence *gaps* are absences, not events: reduction continues across them, one diagnostic per contiguous gap (§6.1). The full condition inventory is the normative table in §6.6, which is also the hostile-fixture checklist (§10). One deliberate exception: undecodable *outcomes* inside a decodable `generationEnded` do not quarantine — they land as `.failed(.unrecognized)` (§6.1), because a lost terminal is not contained loss. Diagnostics are for logging and debug surfaces, not user-facing by default. Consequence worth advertising: a log written by LedgerKit v0.4 still *loads* on v0.1, degraded but alive.
- **I3 (Single termination):** Per `GenerationID`, at most one `generationEnded`. The driver enforces at-most-once emission; the reducer treats a second terminal as malformed (§6.6).
- **I4 (Generation-scoped bounds):** `deltaAppended` **and** `toolInvocationRecorded` are valid only between `generationStarted` and `generationEnded` for that `GenerationID`. Out-of-bounds events quarantine (§6.6) — a terminal message's content *and audit trail* are immutable post-terminal.
- **I5 (Recovery):** Any generation with a `generationStarted` and **no terminal event anywhere in the log** reduces to `.interrupted(partial:)` — the concatenation of persisted deltas. Order-agnostic by construction: the rule is "no terminal exists," not "the log ends with," so it holds even with interleaved events from other activity. This is the entire crash-recovery mechanism: no dirty flags, no recovery pass, no repair job. The absence of a terminal event *is* the signal, and it cannot be skipped. Because terminals decode tolerantly (§6.1), "no terminal" means genuinely missing or row-level unreadable — process death or bit rot — never a merely unfamiliar outcome kind. `.interrupted` is a *finalization-time* classification (like `Recoverability`): an open generation in an intermediate fold — a snapshot, say (§9) — is stored open, and only a completed reduction with no live overlay (§7.4) classifies it interrupted.
- **I6 (Tree integrity, virtual root):** The tree hangs off an implicit **virtual root** — not a message, created by no event, never on `activePath`, never rendered. Every node with `parent: nil` is a child of the virtual root; root-level sibling order is sequence order, like everywhere else. The first `userMessageAppended(parent: nil)` opens the tree; a *subsequent* bare nil-parent append still quarantines — "new topic" remains "new conversation," and an accidental nil parent should not silently become a hidden branch. Root-level *siblings* arise in exactly two ways: `messageEdited` of a root-level message (the edit names its original, so variant intent is explicit — this is what makes editing the first message legal, something rev 2 accidentally forbade), and — as wire headroom only — nil-parent `generationStarted` (N10; the reducer accepts them, the v0.1 store never emits one). Every non-nil parent must exist and precede its child in sequence order. `activePath` is always a valid chain from one root-level node to the **endpoint**, where the endpoint is any node — it need not be a tree-leaf. The reducer clamps to the nearest valid ancestor if a quarantined event invalidates the path.
- **I7 (Identity):** `GenerationID` ↔ `MessageID` is 1:1 in v0.1. A `generationStarted` naming an already-bound MessageID quarantines (§6.6). Continuation-style resume would relax this to N:1; that is exactly why it is v0.2 research, not a v0.1 promise (§12).

I1–I7 are a page of TLA+/PlusCal if you want the formal version — the state space is small (message lifecycle × log suffix shapes) and model-checking I5 against random truncation is exactly what TLC is for. Optional, but it's a differentiating appendix and a post.

### 6.4 Branching & the active path

- Tree, not DAG. No merges in v0.1 (merging conversation branches has no obvious UX; revisit only with a concrete demand).
- **Auto-extend rule:** when an appended node's parent equals the current path endpoint, the reducer extends `activePath` to the new node. This keeps the normal flow — user message, then its generation — on the visible thread with zero explicit path events, including the in-flight streaming bubble.
- **Everything else is explicit.** `activePathChanged(endpoint:)` names the new endpoint; the path is derived by walking parents up to a root-level node. Three cases:
  - **Edit** of user message *m* creates a sibling of *m* under the same parent (`messageEdited`) plus an `activePathChanged` onto the new branch — two events, one transaction (§9). Editing a root-level message creates a root-level sibling under the virtual root — same rule, no special case (I6). The original branch is retained, unreachable-by-default, surfaced via a branch switcher.
  - **Generation off the endpoint** (rev 4, generalized from "Regenerate"): any generation start whose parent is *not* the current endpoint — `respond(to:)` at a non-endpoint user message, and `regenerate` (which is exactly that, §11) — emits `activePathChanged(endpoint: <the new message>)` alongside its `generationStarted`, same transaction. The parent isn't the endpoint, so auto-extend can't fire, and **a generation the user asked for must never stream invisibly** — rev 3 stated this only for regenerate and left `respond` at an off-path target silently invisible. Sibling assistant nodes fall out whenever the target already has a response — the old response, including an `.interrupted` partial, survives as a sibling branch. This is how DoD-1's "partial retained as its own branch" falls out of the model rather than being a feature.
  - **Branch switch** is a bare `activePathChanged`.
- Sibling order = event sequence order. No reordering events in v0.1.

**Why `activePathChanged` is an event at all — acknowledged tension.** The purist objection is fair: which branch the user is *looking at* is view state, not domain truth, and the mainstream non-event-sourced implementations store the current endpoint as mutable conversation metadata. The auto-extend rule already concedes that most path movement shouldn't be events. We keep the explicit event anyway, deliberately: a switch is user intent, not incidental navigation; it pairs atomically and self-describingly with edit and regenerate in one transaction; and crash-consistent "reopen where I was" falls out free. The accepted cost: branch-navigation history persists in the domain log forever. If that ever becomes objectionable, the escape hatch is demoting the endpoint to index-table metadata (§9) — a projection change, not a migration.

### 6.5 Concurrent generations

Two layers, two different answers — deliberately:

- **The log and reducer are order-agnostic and tolerate concurrency.** I3/I4/I5/I7 are keyed per `GenerationID`; interleaved events from two simultaneous generations reduce correctly today. No schema change is ever needed to allow parallelism.
- **The store enforces single-flight per conversation in v0.1.** The generation starters — `send`, `respond`, `regenerate` (§11) — throw `LedgerError.generationInFlight` if a generation is live in that conversation. Cross-conversation concurrency is unrestricted.

**Start atomicity (rev 4).** The single-flight check, the verb's ledger appends, and the in-flight registration happen in **one actor-isolated critical section**, and a verb's events commit in one transaction (§9): `send` is `userMessageAppended` + `generationStarted` (nothing more — auto-extend is a fold rule, not an event); `respond`/`regenerate` are `generationStarted` (+ `activePathChanged` when the parent isn't the endpoint, §6.4). A losing `send` racer therefore records **nothing** — no orphaned user message with the path already yanked onto it — and any verb that fails to start leaves the log untouched. This is what makes §11's two-channel contract ("`try` guards *did it start*") literally true rather than approximately true.

**Target eligibility (rev 4; store-enforced, wire-tolerant).** `respond(to:)` requires an existing **user** message; `regenerate` requires an existing **assistant** message; `edit` requires a **user** message (§6.1). Anything else throws as an ineligible target — an assistant-parented generation is the continuation shape, and continuation is v0.2 research (I7, §12), not a thing v0.1 backs into by accident. The reducer deliberately accepts other role adjacencies (§6.1) — enforcement is policy, headroom is wire, the N10 pattern.

Why this split matches the ecosystem: Apple's `LanguageModelSession` is single-flight — `isResponding` exists and concurrent requests to one session are an error (⚠️ verify the exact error surface in the iOS 27 beta — iOS 26 evidence says the busy-session condition surfaced *as* `GenerationError.rateLimited`, which is precisely the hazard §7.2's gate exists for: session-busy must never normalize as provider rate limiting). OpenAI's Assistants API — the one mainstream design that held server-side conversation state — enforced one active run per thread. Chat products (Claude.ai, ChatGPT) enforce one stream per visible thread client-side. Provider HTTP APIs are stateless and don't care. Precedent is consistent: *inference* concurrency is a rate-limit question; *conversation-state* concurrency is single-flight.

Throw, don't queue: queuing hides a product decision (should the second send target the new leaf that the in-flight generation is about to create?) inside a library. Surfacing `generationInFlight` lets the app disable the send button, which is what every chat UI does anyway.

**Mid-stream edits and switches are legal.** Single-flight gates *generation starts* (`send` / `respond` / `regenerate`, §11), not ledger writes: `switchBranch` and `edit` remain available while a generation streams. A mid-stream switch moves the visible path; the stream continues off-path (auto-extend already fired at `generationStarted`) and terminates normally — completion changes state in place and emits no path event, so the bubble stays wherever the user left it. An edit-then-respond during flight hits `generationInFlight` on the respond. Whether switching away should *cancel* is a product decision — the store exposes `cancelGeneration(in:)` (§11) and takes no position. One verb overrides rather than respects the flight: `deleteConversation` cancels first, then deletes (§9).

Priced-in future: parallel sibling generation — regenerate on two models simultaneously and branch-compare — is representable in today's log and becomes a v0.2+ *store-policy relaxation*, not a migration (§12).

### 6.6 Quarantine rules (normative)

The single inventory of conditions the reducer skips. Disposition for every row is the same — skip the event, continue reduction, append a `QuarantinedEvent(sequence:eventID:reason:)` to `Conversation.diagnostics`, leave targeted entities untouched (I2) — except row 3, the one deliberate exception. This table **is** the hostile-fixture checklist (§10) and is owned by ADR-001.

| # | Condition | Disposition |
|---|---|---|
| 1 | Row undecodable at the envelope level (no event identity recoverable) | Quarantine — sequence-only diagnostics |
| 2 | Unknown payload discriminator (written by a future LedgerKit) | Quarantine — conversation loads degraded |
| 3 | `generationEnded` decodes, but the nested `Outcome` / `GenerationError` discriminator is unknown | **No quarantine** — lands as `.failed(.unrecognized("undecodable outcome: <tag>"))` (tolerant-terminal rule, §6.1) |
| 4 | Envelope `conversationID` ≠ the stream the event was loaded from | Quarantine — cross-stream contamination |
| 5 | Any event before genesis; a second `conversationCreated` | Quarantine |
| 6 | `userMessageAppended` naming an unknown parent | Quarantine |
| 7 | A bare `userMessageAppended(parent: nil)` after the first | Quarantine — the "new topic ≠ new branch" guard (I6) |
| 8 | `generationStarted` reusing a `GenerationID`, binding an already-bound `MessageID` (I7), or naming an unknown parent | Quarantine |
| 9 | `deltaAppended` / `toolInvocationRecorded` with an unknown `GenerationID`, or outside the started→ended bounds (I4) | Quarantine |
| 10 | A second `generationEnded` for the same `GenerationID` (I3) | Quarantine |
| 11 | `messageEdited` whose original is assistant-authored, or unknown, or whose replacement ID already exists | Quarantine |
| 12 | `activePathChanged` naming an endpoint that never existed | Quarantine — distinct from *clamping*, which handles paths invalidated by later quarantines; a never-valid endpoint is malformed, not stale |

`instructionsChanged` and `titleChanged` carry no references and are always valid after genesis.

**Deliberate non-rules, recorded so the inventory stays complete (rev 4):** Role adjacency — a `generationStarted` with an assistant parent, or consecutive user-authored siblings — does **not** quarantine; it is wire headroom under store enforcement (§6.1, §6.5). Sequence **gaps** are absences, not skipped events: one diagnostic per contiguous gap, reduction continues (§6.1). And **cascades are expected, not pathological**: a quarantined `generationStarted` (row 8) orphans that generation's deltas, tool records, and terminal, which then quarantine individually under rows 9–10 — a fixture asserts the cascade's exact residue rather than pretending it can't happen (§10).

---
## 7. The session seam (Foundation Models integration)

The one OS-coupled module. Everything in §6 is pure Swift and platform-agnostic — which matters when the framework's open-sourcing lands and Swift-on-server becomes a target (out of scope now; costs nothing to preserve).

**Ownership rule:** LedgerKit is durable truth; `LanguageModelSession` is an ephemeral working copy. Sessions are cattle. Any session can be discarded and rebuilt from the ledger at any time — which is precisely why instructions live *in* the ledger (§7.1): a ledger that can't rebuild the session isn't the truth. Rev 4 scopes the claim honestly: rebuild is **text-fidelity, not transcript-entry-fidelity** — §7.1's fidelity classes and N11 state exactly what a rebuilt session contains and what it doesn't. The tenet's force is unchanged where it matters (the visible conversation and its instructions); its limits are now stated instead of implied.

Mechanics follow, as real subsections since rev 4 (rev 3's unnumbered list made `§7.x` references fragile). Verify exact APIs against the iOS 27 beta — flagged inline.

### 7.1 Rehydration

To generate from leaf *m*: materialize the active path — from its root-level node; the virtual root contributes nothing — **plus the current instructions** (latest `instructionsChanged` in the log; nil ⇒ none) into a session transcript (⚠️ verify: transcript-seeding initializer shape in iOS 27; iOS 26 had `LanguageModelSession(transcript:)`). Session reuse across turns in the same live conversation is a KV-cache-relevant optimization — do it when the session is still valid, but correctness never depends on it (cardinality rules in §7.8).

**Fidelity classes (rev 4).** Apple's `Transcript` carries six entry kinds; a rebuilt session contains:

- **Instructions — exact.** The latest `instructionsChanged`, always.
- **Prompt/response text — exact, partials included.** Every message on the active path contributes its current text — including the partial of a `.failed`/`.cancelled`/`.interrupted` message if the user kept it on the path. What the user saw is what the model sees.
- **Tool calls / tool outputs — not reconstructed.** Under *any* recording policy in v0.1: with `.metadataOnly` (the default) the outputs were never retained, so reconstruction is impossible by design; with `.full` it is representable but deliberately deferred (v0.2, §12) pending the transcript-entry construction surface (OQ2-adjacent). Consequence, owned: **a rebuilt session's model no longer sees prior tool results** — post-crash regeneration can differ from what the live session would have produced. The audit trail outlives the session's memory of it.
- **Reasoning — absent.** Not recordable in v0.1 at all (OQ9); rebuilt sessions never contain reasoning entries.

*Scope caveat:* apps mutating instructions/tools mid-session via Dynamic Profiles are outside v0.1 audit fidelity — LedgerKit records conversation-level instructions only. If your app swaps profiles per-turn, the ledger records which model ran (`ModelDescriptor`), not which profile.

### 7.2 Generation start & the outcome boundary (rev 4)

The rule the entire error-UX story hangs on, stated normatively: **the driver appends `generationStarted` — with its paired `activePathChanged` where §6.4 requires one, and `send`'s user message, all in the verb's single transaction (§6.5) — *before* issuing the provider request. Every failure after that append is an `Outcome`, never a thrown error.** That includes request-time failures that produce zero tokens: an auth failure (401 ⇒ `.failed(.providerFailure)` ⇒ `recoverableUpstream(.reauthenticate)`), an instant guardrail rejection, an unavailable model. This is what makes §8's classification table reachable through observation for the most common server-model failures — without it, the reauth bubble in §11's switch could never render, because the error would have been thrown into a `Task` nobody is switching over. Zero-token failures render as `.failed(partial: "", …)`: an empty failed bubble is a feature (the user sees *that* it failed and *how to recover*), not an artifact.

The throw channel (§11) is exactly the complement — failures *before* the append: unknown conversation, ineligible target (§6.5), `generationInFlight`, persistence failure. Those leave no trace in the log, which is correct: nothing started.

**Task-cancellation across the boundary follows the same line:** cancelled before the append ⇒ the verb throws `CancellationError` — nothing started, Swift convention holds, nothing to record. Cancelled after ⇒ the §7.5 path: the call *returns* `.cancelled` (§11's documented deviation, now with a crisp boundary instead of a vibe).

**Defensive session gate:** the driver checks `isResponding` before issuing, and treats a busy session as a driver defect — `generationEnded(.failed(.unrecognized("driver: session busy")))` — never as a provider signal. The hazard is concrete: iOS 26 evidence says the busy-session condition surfaced *as* `GenerationError.rateLimited` (⚠️ single-source; verify — OQ6), and normalizing that per §8 would classify a programming error as `retryable` — a retry loop against a busy session. Store single-flight makes the gate unreachable in v0.1; it is cheap insurance for the §6.5 parallel-generation relaxation.

### 7.3 Streaming reduction

FM streams *cumulative snapshots*, not deltas. The driver diffs successive snapshots and emits `deltaAppended` with the suffix. For plain text, snapshots are append-only, so prefix-diffing is sound; assert the prefix property in debug. **Release behavior on violation:** the driver fails the generation — `generationEnded(.failed(.unrecognized("driver: non-prefix snapshot")))`, terminal — and never emits a reconstructed or corrupt delta. A wrong transcript is worse than a dead one. (Guided-generation partials are *not* prefix-stable — one reason N8 exists.)

**Non-text stream content (rev 4):** provider streams can vend more than text — response metadata, usage updates, and *custom segments* (reasoning, provider-specific segments like search results). **v0.1 records text deltas only.** Non-text segments are ignored — neither persisted nor rehydrated (N11, OQ9) — deliberately and loudly in the docs, not as an accident of the diff loop. Usage and resolved model identity are the two exceptions, captured at completion into `StopInfo` (§7.7, §7.8).

### 7.4 Delta persistence batching — two cadences, one truth hierarchy, one overlay

Writing every token to disk is wasteful; losing 30 s of stream on crash is bad UX. Driver coalesces *disk* flushes on a policy (default: every ~250 ms or N chars, and always before `generationEnded`). The *observable projection* applies deltas as they arrive, in memory, ahead of disk — so streaming renders smoothly at display cadence while the log fills at durability cadence. Rev 2 wrote the projection as `fold(persisted log) ⊕ unflushed tail` and left `⊕` undefined; it does more work than "append." Precisely:

`projection = overlay_live( reduce(persistedLog ++ unflushedTail, mapping) )`

where `overlay_live` maps `.interrupted → .streaming(partial:)` for exactly the `GenerationID`s the store currently has in flight, and is the identity otherwise. The decomposition matters: **no fold ever yields `.streaming`** — a log cannot know the process is alive — and `.interrupted` is precisely what a live generation *looks like* to a pure fold. Liveness is store state, deliberately outside the reducer: I1 stays pure. On crash, the live set is vacuously empty at next launch, the overlay is the identity, and the fold's `.interrupted` shows through — recovery is the overlay *disappearing*, not a recovery pass running. On flush, the unflushed tail is exactly what would be lost, which is the already-documented recovery granularity. Make both cadences configurable; the two halves are tested separately in §10.

**Only `deltaAppended` coalesces (rev 4).** Every other event — `generationStarted` (and its transaction-mates, §6.5), terminals, edits, path changes, metadata — appends synchronously before the verb proceeds. The rule earns its keep at the start boundary: if `generationStarted` could sit in the unflushed tail, a crash before the first delta flush would erase the generation entirely — user message persisted, no `.interrupted` bubble, the turn silently vanished. That is a strictly worse artifact than the one G4 exists to fix, and it is now unrepresentable by rule rather than avoided by luck.

### 7.5 Cancellation

Two entry points, one semantics: `store.cancelGeneration(in:)` — the canonical path; the store is the authority on in-flight state and survives view teardown — or cancelling the `Task` awaiting `send` / `respond` / `regenerate` (sugar; structured-concurrency-friendly, but the handle dies with its owner). Either way: FM stream terminates ⇒ driver flushes ⇒ appends `generationEnded(.cancelled)` ⇒ the suspended call returns `.cancelled`. (Pre-start Task-cancel is the one exception — it *throws*, §7.2: there is nothing to terminate.) A cancel racing a natural terminal is benign: first append wins, I3 quarantines the loser. Cancelled ≠ failed ≠ interrupted: three distinct UI treatments.

### 7.6 Tool calls

FM executes registered tools inside the session. The driver observes invocations (⚠️ verify: what iOS 27 exposes for observing tool activity on the response/stream) and records `toolInvocationRecorded` events. Record, don't orchestrate. **Recording policy** on the driver: `.metadataOnly` (default — name, status, duration), `.full` (adds `argumentsJSON`/`resultJSON`), `.off`. Full is opt-in because tool results routinely contain fetched sensitive data, and the ledger outlives the session (§9 privacy). **Shape consequence, stated:** the record is a single event emitted *after* the invocation completes (it carries duration and result) — live "using tool…" UI is therefore not representable from v0.1 ledger data; live tool activity, if surfaced at all, is a session-observation concern (OQ2), not a ledger one. If v0.2 splits this into started/ended kinds for live rendering, those are new payload kinds that v0.1 readers quarantine — the record vanishes rather than degrades on old readers. Priced in and accepted. Rehydration consequence: records are *audit*, not rebuild material, in v0.1 — §7.1's fidelity classes; reconstruction from `.full` records is the v0.2 item (§12).

### 7.7 Usage

`Response.usage` (new in iOS 27) → captured in `StopInfo` on completion. Token counts now span input/output including cached and reasoning tokens across providers (⚠️ verify exact field names against the beta). Projected on `Message.stopInfo` (§6.2, rev 4): per-message token/cost display is table stakes for BYO-key apps, and recorded-but-unprojectable data is a bug, not privacy.

### 7.8 Provider swap & model identity

The driver takes `any LanguageModel` at init. On-device ↔ Claude package ↔ Chat Completions server is the app's one-line choice; zero conditional code inside LedgerKit.

**Model identity is two facts captured at two times (rev 4, resolving most of OQ8):** the **requested** descriptor — provider/model/version as configured — rides `generationStarted` (app-supplied at driver init, or derived from the model's configuration surface if the beta exposes one: the OQ8 residual); the **resolved** identity the provider actually reports (executors report e.g. a `modelID` via response metadata) lands in `StopInfo` at completion. Branch-compare uses the request; audit gets both; a provider silently upgrading its backend is *visible* as request ≠ resolved instead of invisible.

**Cardinality (rev 4, previously unstated):** one driver may serve many conversations concurrently — §6.5's cross-conversation freedom is a driver property too, not just a store one. The driver is stateless per generation: it materializes or reuses a session **per conversation** (an internal cache keyed by `ConversationID` — the §7.1 KV-cache optimization), never one shared session across conversations, because Apple sessions are single-flight (§6.5, §7.2). Correctness never depends on the cache; discard-and-rebuild is always legal (ownership rule).

---

## 8. Error taxonomy & recoverability

The contract that makes error handling a design feature instead of an afterthought. UI affordance is a function of `Recoverability`, never of raw error inspection.

**Anchor on Apple's enum, not per-provider empirics.** Apple steers providers toward the built-in `LanguageModelError` cases, reserving custom errors for service-specific failures. `GenerationError` is therefore defined as a *total normalization of Apple's built-in taxonomy* first, with `providerFailure`/`transport` as the custom-error tail and `unrecognized` as the floor. (⚠️ verify the built-in case inventory against the beta — §14.)

```swift
public enum GenerationError: Error, Sendable, Codable {
    case modelUnavailable(ModelUnavailability)   // deviceNotEligible, appleIntelligenceNotEnabled,
                                                 // modelNotReady — mirror Apple's case names
                                                 // exactly (rev 4; ⚠️ §14 OQ5)
    case contextWindowExceeded
    case guardrailViolation
    case rateLimited(retryAfter: Duration?)
    case providerFailure(status: Int?, code: String?, message: String?)
        // status:  HTTP status, when the failure crossed an HTTP boundary; else nil
        // code:    provider's stable machine-readable error identifier; else nil
        // message: human-readable detail — never used for classification
    case transport(TransportFailure)             // timeout, connectivity, TLS — the "network, not model" bucket
    case unrecognized(description: String)       // loud, never silently swallowed
}

public enum Recoverability: Sendable {            // derived, never persisted — no Codable
    case retryable(after: Duration?)     // transient — offer Retry / auto-backoff
    case recoverableUpstream(RequiredAction)  // caller must change something first
    case terminal                        // Regenerate-with-changes is the only path
}

public enum RequiredAction: Sendable {
    case enableAppleIntelligence         // deep-link Settings
    case awaitModelDownload
    case reduceContext                   // trigger compaction (app-side, utilities modifier), then retry
    case reauthenticate                  // provider-package credential problem
}
```

**Normalization contract (the layer rev 2 hand-waved).** Two layers, named, because the churn lives in the first:

1. **Normalization** — thrown error → `GenerationError`. Lives in the driver's per-provider mapping files. Empirical, fixture-tested (§10), expected to churn.
2. **Classification** — `GenerationError` → `Recoverability`. The pure mapping, an explicit input to the classify layer (§6.3, I1). The table below.

`providerFailure`'s field contract borrows the *shape* of RFC 9457 (Problem Details) as prior art, not authority (rev 4): `status` is the numeric HTTP status when one exists; `message` is human detail and **never participates in classification**; `code` is the provider's stable machine-readable identifier (Anthropic-style error-type strings and the like) — the RFC's own field for this role is a `type` URI, which no LLM provider ships, so `code` is an extension member in 9457 terms. Normalization rules, in order:

1. Apple's built-in `LanguageModelError` cases map 1:1 first — this is Apple's own guidance to provider authors (built-ins when they fit, custom errors for service-specific tails).
2. **Lift rules** — cases that must never fall through to the generic status classes: HTTP 429 → `.rateLimited(retryAfter:)`, parsing `Retry-After` in both RFC 9110 forms (delta-seconds and HTTP-date; normalize the date form to a duration *at normalization time*, so the persisted value is clock-independent — display math is `Message.terminalTimestamp + retryAfter`, §6.2, so the instant the duration is relative to is projected, rev 4). HTTP 408 and all timeout / connectivity / TLS failures → `.transport(…)`.
3. Remaining failures that crossed an HTTP boundary → `providerFailure(status:code:message:)`.
4. Non-HTTP provider-custom errors → `providerFailure(status: nil, code: <identifier>, message:)`.
5. Anything else → `.unrecognized` (loud).

**One exclusion, stated because iOS 26 made it a live hazard (rev 4):** a busy-*session* error surfacing as `rateLimited` is a driver defect, not a provider signal — §7.2's `isResponding` gate keeps it out of normalization entirely (it lands as `unrecognized("driver: session busy")` if it ever fires, never as `retryable`).

Convention: `unrecognized` descriptions originating from LedgerKit's own driver invariants carry a stable `"driver:"` prefix (e.g. the §7.3 prefix-violation path, the §7.2 session gate), so mapping overrides and log triage can distinguish driver defects from provider mysteries.

**Provenance rule:** `GenerationError` is persisted (inside `Outcome.failed`); `Recoverability` is **derived at classification time** by the mapping and stored nowhere — not in events, not in snapshots (snapshots store `FoldedState` — the error, never the classification — and recompute on load, §6.3/§9). This is what keeps I1 honest ("same log ⇒ same folded state; folded state + mapping ⇒ same classified state"), and it means fixing a mapping gap *retroactively upgrades* the affordances on historical failed messages the next time they're reduced. Classification bugs heal; frozen classifications don't.

Default classification mapping (ships in LedgerKit; apps override per-case; overrides apply on next reduction):

| Error | Recoverability |
|---|---|
| `modelUnavailable(.deviceNotEligible)` | `terminal` |
| `modelUnavailable(.appleIntelligenceNotEnabled)` | `recoverableUpstream(.enableAppleIntelligence)` |
| `modelUnavailable(.modelNotReady)` | `recoverableUpstream(.awaitModelDownload)` |
| `contextWindowExceeded` | `recoverableUpstream(.reduceContext)` |
| `guardrailViolation` | `terminal` |
| `rateLimited(after)` | `retryable(after)` |
| `transport(*)` | `retryable(nil)` |
| `providerFailure`, status 5xx | `retryable(nil)` |
| `providerFailure`, status 401 / 403 / 407 | `recoverableUpstream(.reauthenticate)` |
| `providerFailure`, status 429 | `retryable(nil)` — defensive; normalization should have lifted it (log loudly) |
| `providerFailure`, other 4xx status | `terminal` |
| `providerFailure`, status nil, code non-nil | per-provider override table; unmatched → `terminal` (loud) |
| `providerFailure`, status nil, code nil | `terminal` (and logged loudly) |
| `unrecognized` | `terminal` (and logged loudly) |

Nil rationale: an unclassifiable provider failure retried blind risks retry loops on permanent faults; `terminal` still leaves Regenerate as the manual retry, which is the safer default. If a provider family turns out to emit nil-status transients, that's a mapping override keyed on `code` — and a fixture (§10).

Normalization risk, revised: anchoring on the built-in enum shrinks the empirical surface to each provider's custom tail. Still isolate the mapping in one file per provider family, fixture-test it (§10), and expect it to churn. This is where real-world adoption feedback accrues; treat mapping-gap issues as gold.

---

## 9. Persistence

- **Store:** single SQLite database. **Three tables:**
  - `events` — append-only, keyed `(conversation_id, sequence)` UNIQUE. The truth. The `sequence` column is the **only** physical home of sequence (rev 4): the encoded blob omits it and the in-memory envelope is populated from the column at load — a blob/column disagreement is unrepresentable, by construction rather than by check. `conversationID` is deliberately in both places; the duplication is what §6.6 row 4 verifies.
  - `snapshots` — periodic **`FoldedState`** checkpoints (§6.3) so cold-open of a 10k-event conversation doesn't replay from genesis. Each row carries **reducer version + payload schema version**; discarded on mismatch, no migration ever. Snapshots store raw `GenerationError`s, never `Recoverability` (recomputed on load, §8) — mapping-agnostic by construction — **and the diagnostics accumulated so far (rev 4)**: quarantine residue is observable state, so a snapshot that dropped it would make reduced state depend on snapshot timing. P3 (§10) exists to catch exactly that class of bug. **Refresh policy (default):** best-effort async refresh after each `generationEnded` append — the natural quiescent point, and generations dominate event volume, so cold-open replays at most one generation's suffix — with a floor of every 500 events for pathological logs; both configurable. Snapshots are disposable (truth is the log), so best-effort is safe: a missed refresh costs replay time, never correctness. A snapshot landing mid-generation stores the open generation *open* — `.interrupted` is finalization-time (I5), so intermediate folds carry no false classification.
  - `conversations` — the cross-conversation **index projection**: id, created_at, title, last_event_at. Maintained transactionally on **non-delta appends** (rev 4) — delta flushes deliberately don't touch it: a streaming generation would otherwise churn the table and every value-observer at flush cadence (~4 Hz) for zero information, and the live-activity signal belongs to the projection's overlay (§7.4), not the index. `last_event_at` therefore reads "last meaningful event," which is what a list sorts by anyway. Rebuildable by scanning the log. In event-sourcing terms this is a read model: same class as snapshots — derived, deletable at any time, truth is the log. It exists so the conversation list is a table read, not N reductions (G9).
- **Recommendation:** GRDB over raw sqlite3 (migrations, value observation) — but the persistence interface is a small protocol so this is swappable; decide at implementation, don't bikeshed now. SwiftData is the wrong shape for an append-only log with custom reduction; don't fight it.
- **Atomicity:** an event append is the transactional unit; multi-event operations (send = `userMessageAppended` + `generationStarted`, rev 4; edit = `messageEdited` + `activePathChanged`; respond/regenerate = `generationStarted` + `activePathChanged` when off-endpoint, §6.4) commit in **one** transaction, so no crash can strand half an operation. A crash between transactions is by construction a valid log (I2/I5 handle the rest). Note the limit of this guarantee: operation boundaries exist only as DB transactions — the log itself doesn't record them. Promoting an operation/correlation ID onto the envelope is deferred to the v0.3 sync design doc (§6.1, §12); noted here so it reads as a decision, not an omission.
- **Log versioning:** every event row carries a schema version. v0.1 policy: reducer reads all past versions, writes current. **Forward compatibility:** payload kinds written by a *newer* LedgerKit decode to quarantine (§6.6) — the conversation loads, degraded, never fails — with the single tolerant-terminal exception (§6.1). Codable evolution of `Payload` is the sharpest long-term maintenance edge in the whole design — encoding is tagged JSON (ratified, was OQ1); ADR-001 formalizes it: the discriminator registry (tags are never reused; removed tags stay reserved), the unknown-discriminator → quarantine rule, the tolerant-terminal exception, the gap-diagnostic rule (§6.1), and the version-frozen fixture corpus (§10).
- **Log growth:** delta rows dominate — at the default flush cadence a 60 s generation is ~240 rows. Storage cost is trivial (text), but state the stance: **no delta consolidation in v0.1.** Collapsing a completed generation's deltas into one row is a history rewrite, in direct tension with tenet 2; if it ever happens it is a deliberate archival design (v0.3+ at the earliest), not a cleanup task. Snapshots address read cost, not size.
- **Deletion & erasure:** conversation-level delete = transactional `DELETE` of that conversation's events, snapshots, and index row, via `store.deleteConversation(_:)`. **It cancels any in-flight generation first (rev 4):** the cancel runs to its terminal through the normal path (§7.5 — the suspended verb returns `.cancelled`, not a persistence error), then the `DELETE` commits; both steps sequence through the store actor, so the terminal-append-vs-DELETE race cannot occur. It is out-of-band — not an event — because there is no log left to append to; document that it is irreversible. **Sync consequence, priced in now:** these DELETE semantics are local-only. Log-shipping sync (v0.3 design doc, §12) must introduce deletion tombstones or an equivalent, or a deleted conversation resurrects from any peer still holding its log — the classic resurrection problem. Inbox item for the sync doc, not a v0.1 concern. Message-level redaction is out of scope (N9). The honest note for the README: append-only and erasure are structurally opposed; the known idioms are **crypto-shredding** (encrypt payloads under per-conversation or per-message keys; deleting the key is the erasure) versus an explicit, versioned log rewrite. Choosing one is the v0.2 erasure design doc (§12).
- **Privacy:** conversations are user content. File protection `.completeUntilFirstUserAuthentication` minimum; document that apps handling sensitive domains should layer their own encryption. Tool recording defaults to `.metadataOnly` (§7.6) because recorded tool results outlive the session. No LedgerKit telemetry, ever.

---
## 10. Testing strategy

The test story *is* the differentiation — "how do you even test an FM app?" currently has no good public answer.

1. **`ScriptedLanguageModel`** — conforms to Apple's `LanguageModel` protocol (model + executor pair — ⚠️ verify conformance surface against beta). Plays a script: emit snapshot, wait, throw, complete. Powers unit tests, SwiftUI previews, demo screenshots, and CI on Intel Macs with zero Apple Intelligence eligibility. Because the protocol is Apple's, this double is useful to *any* FM app, not just LedgerKit consumers — ship it as a separate product (`LedgerKitTestSupport`) and let it be the gateway drug.
2. **Golden logs:** fixture event logs → expected reduced state, snapshot-tested. Doubles as living documentation of semantics. Hostile fixtures mirror the §6.6 table row-for-row: second genesis, second bare nil-parent append, delta-after-end, tool-record-after-end, assistant-message edit, replacement-ID collision, `activePathChanged` to a never-existent endpoint, envelope `conversationID` mismatch, unknown payload kind — each asserting the exact `diagnostics` residue. Plus the tolerant-terminal fixture asserting the *opposite*: an unknown nested outcome lands as `failed(.unrecognized)` and does **not** quarantine (§6.1). Rev 4 additions, mirroring the §6.6 non-rules: a **mid-log gap** fixture (one diagnostic per contiguous gap; a gap swallowing a terminal yields `.interrupted`), the **cascade** fixture (a quarantined `generationStarted` orphans its deltas, tool records, and terminal into rows 9–10 residue — exact diagnostics asserted), and **role-adjacency non-rule** fixtures (assistant-parent `generationStarted` and consecutive user siblings reduce *without* quarantine — wire headroom proven, not assumed). Root-message edit graduates from impossible (rev 2) to a golden fixture. **Version-frozen corpus:** fixture logs written by each released version are frozen in CI forever — the standard evolution safety net; if per-version decode ever gets hairy, the idiom to reach for is *upcasters* (decode-time old-shape → current-shape transforms) so the reducer stays single-shape (ADR-001).
3. **Crash-point fuzzing:** for every fixture log, truncate at *every* prefix and assert the reducer yields a valid state with correct `.interrupted` synthesis (I5) and no traps (I2). Rev 4 adds the **interior-gap variant**: knock out interior slices, not just suffixes, and assert I2's gap diagnostics alongside I5's synthesis. Cheap, brutal, and the single highest-value suite in the package.
4. **Cancellation chaos:** drive `ScriptedLanguageModel` streams, cancel at randomized points — including via `store.cancelGeneration(in:)` racing natural completion, and Task-cancellation straddling the §7.2 boundary (pre-append ⇒ throws, post-append ⇒ returns `.cancelled`) — assert exactly one terminal outcome (I3) and partial-content retention.
5. **Error-mapping fixtures:** canned provider failures → asserted `GenerationError` + `Recoverability`, per provider family, covering both layers: normalization (the §8 lift rules — 429 → `rateLimited` with both `Retry-After` forms, 408/timeout → `transport`, and the busy-session exclusion: a session-busy error lands as `unrecognized("driver: session busy")`, never `rateLimited`) and classification (the status-class rows, the reauthenticate rows, the nil-status floors).
6. **Projection & snapshot equivalence, in three parts (the §7.4 and §9 contracts made executable):** **P1 (fold/tail equivalence, pure):** `reduce(persisted ++ unflushedTail, mapping) == reduce(logAfterFlush, mapping)`, property-tested over randomized flush points. **P2 (overlay correctness):** for every live `GenerationID`, the projection shows `.streaming` with partial equal to the concatenated deltas; for everything else the projection equals the fold; and the live set is always a subset of open (started, un-terminated) generations. Crash recovery is P2's degenerate case: empty live set ⇒ overlay is identity ⇒ `.interrupted` shows through. **P3 (snapshot equivalence, rev 4):** `resume(snapshot(prefix), suffix) == fold(fullLog)` — **including `diagnostics`** — property-tested over randomized snapshot points. The snapshot fast-path is a second reduction path; rev 3 shipped it untested, which was exactly the kind of hole this spec exists to not have. P3 is also what *forces* snapshots to persist diagnostics (§9): drop them and P3 fails on any log with quarantine residue before the snapshot point.
7. **Device integration (manual/CI-optional):** real on-device model behind an env flag; availability matrix spot checks.

---

## 11. Public API sketch (consumer's view)

```swift
let store = try ConversationStore(persistence: .sqlite(url: dbURL))   // actor

// Lifecycle & metadata
let convo = try await store.createConversation()                      // optional title:
try await store.setInstructions("You are an origami tutor.", in: convo.id)
try await store.setTitle("Valley folds 101", in: convo.id)            // titleChanged; nil clears (§6.1)
try await store.deleteConversation(convo.id)                          // cancels any in-flight generation
                                                                      // first (§9), then irreversible,
                                                                      // out-of-band delete

// Turn verbs — the three generation starters; all throw generationInFlight
// under single-flight (§6.5), all suspend to a terminal Outcome:
let driver = GenerationDriver(model: SystemLanguageModel.default,     // or ClaudeLanguageModel(...), etc.
                              toolRecording: .metadataOnly)

let outcome = try await store.send("Explain valley folds", in: convo.id, using: driver)
    // send ≡ append user message + respond(to: it) — the 95% path, one call.
    // Atomic within the actor (§6.5): the single-flight check, the user-message
    // append, and generationStarted commit together — a losing racer records
    // NOTHING. No orphaned user message, no yanked path.

let replacement = try await store.edit(message.id,
                                       content: "Explain mountain folds",
                                       in: convo.id)
    // Pure ledger: messageEdited + activePathChanged, one transaction (§6.4).
    // Does NOT generate — composition is the app's business.

let outcome2 = try await store.respond(to: replacement, in: convo.id, using: driver)
    // A generation whose parent is an existing USER message (§6.5 eligibility) —
    // the post-edit verb. Parent == endpoint here, so auto-extend fires (§6.4).
    // Targeting any OTHER user message is equally legal and emits
    // activePathChanged in the same transaction — a requested generation
    // never streams invisibly (§6.4, rev 4).

let outcome3 = try await store.regenerate(assistant.id, in: convo.id, using: driver)
    // EXACTLY respond(to: its parent) — pure sugar since rev 4 (§6.4): the
    // off-endpoint path event is respond's job now, so regenerate adds nothing
    // but the assistant-to-parent lookup. Sibling response falls out.

// Branching
try await store.switchBranch(to: endpoint, in: convo.id)              // bare activePathChanged

// Cancellation — canonical path; the store outlives any Task handle:
await store.cancelGeneration(in: convo.id)                            // no-op if none live; racing a
                                                                      // natural terminal is benign —
                                                                      // first append wins, I3 (§7.5)

// send/respond/regenerate THROW only when the generation never started —
// i.e. before generationStarted is appended (§7.2): unknown conversation,
// unknown/ineligible target (respond: user messages; regenerate: assistant
// messages — §6.5), generationInFlight, persistence failure. After the
// append, failures are outcomes, not exceptions — including zero-token
// request-time failures (auth, instant guardrail) — they land in the ledger
// and render via observation. One channel for "couldn't record", one channel
// for "recorded a failure".
generationTask = Task {
    _ = try await store.send("Explain valley folds", in: convo.id, using: driver)
}

// Stop button — either path, same semantics (§7.5):
generationTask?.cancel()            // sugar: dies with its owner
// or:
await store.cancelGeneration(in: convo.id)   // canonical

// SwiftUI — message states drive UI directly:
switch message.state {
case .streaming(let partial): StreamingBubble(partial)
case .interrupted(let partial): InterruptedBubble(partial, onRegenerate: ...)
case .failed(_, _, .recoverableUpstream(.reauthenticate)): ReauthPromptBubble(...)
...
}

// Conversation list — the index projection, not N reductions. Lives on the
// @MainActor observable projection (below), not the store actor, which
// exposes no synchronous reads:
ForEach(projection.conversationList) { summary in ... }
```

**A deliberate deviation, documented:** Swift convention is that cancelled async work throws `CancellationError`. `send` (and `respond`/`regenerate`) instead *return* `.cancelled`, because cancellation here is a first-class ledger terminal — the recording operation itself *succeeded*. Throwing would split one semantic ("generation reached a terminal") across two channels. The boundary is §7.2's (rev 4): Task-cancel *before* `generationStarted` lands throws `CancellationError` — nothing started, convention holds; *after*, the call returns `.cancelled`. The rule of thumb for consumers: `try` guards "did it start"; the return value and the observed state answer "how did it end".

**Isolation sketch (tenet 6):** `ConversationStore` is an actor and owns all writes. The observable projection is a `@MainActor @Observable` class fed by the store; deltas hop to the main actor coalesced at *display* cadence (~a frame), independent of the *disk* flush cadence (§7.4). The reducer is pure, `nonisolated` functions over `Sendable` values — no isolation, no clocks, no I/O. The liveness overlay (§7.4) is applied on the projection side — the reducer never learns what "live" means.

The pitch in one exhaustive `switch`: the compiler forces the app to handle interruption and recoverability. That switch statement is your code-aesthetics blog post made executable.

---

## 12. Phasing & effort (evenings/weekends, honest)

- **v0.1 — target: tagged before iOS 27 GA (~Sept).** §6–§11 complete; demo app; README with the kill-mid-stream GIF. Estimate: **4–6 weeks part-time**, which assumes the ⚠️ verifications hold across betas — expect to repeat the API-verification evening per beta through August; price that in. Cut line if slipping, in order: (1) branch-switcher UX in demo (keep the events, hide the UI), (2) GRDB polish → naive SQLite, (3) tool-invocation recording → v0.2, (4) provider-mapping breadth — ship on-device + Claude-package mappings only; Chat-Completions family → v0.2. Never cut: I1–I7 **and P1–P3** tests, interruption recovery, ScriptedLanguageModel.
- **v0.2:** tool records → replay view (and, if OQ2 makes live tool activity observable, the started/ended event-pair design — see §7.6's priced-in quarantine consequence); **transcript-fidelity rehydration** (reconstruct tool-call/tool-output entries from `.full` records into rebuilt transcripts; record reasoning/custom segments if OQ9 exposes them — closes the §7.1 fidelity gap for apps that opt in); guided-generation partials (extends `Content`); export (Markdown/JSON — now self-describing per-event thanks to the envelope `conversationID`); `RecordingLanguageModel` (capture real streams as fixtures); **continuation-resume research** (relaxes I7 to N:1 — the honest version of "Resume"); **parallel sibling generation** (relax single-flight per §6.5, multi-model branch-compare UX; the §7.2 session gate and §7.8 cardinality rules are its groundwork); **erasure design doc** (crypto-shredding vs. log rewrite, §9).
- **v0.3:** compaction bookkeeping integrated with utilities' summarizer — `compactionRecorded` **carries the summary text**, so both rehydration and the audit trail reproduce what the model actually saw, not merely that something happened; search; **sync design doc only** (log-shipping / CRDT exploration — the distributed-systems bridge, deliberately paper-first; inbox from v0.1: deletion tombstones (§9), envelope operation/correlation IDs (§6.1/§9)).

## 13. Definition of done (v0.1)

1. Demo: kill the app mid-stream → relaunch → the message renders `.interrupted` with partial text; **Regenerate works, and the interrupted partial survives as its own branch, reachable via the branch switcher.** Recorded as a GIF; this is the README hero and the launch post.
2. Swap `SystemLanguageModel` → Claude provider package: **the demo compiles and runs with only the driver-init line changed.**
3. Crash-point fuzz suite (suffix **and interior-gap** variants), cancellation chaos suite (including the §7.2 boundary cases), hostile-fixture quarantine assertions (the §6.6 table, row-for-row, including the tolerant-terminal *non*-quarantine, the role-adjacency non-rules, and the cascade fixture), and **P1–P3** green in CI (Scripted model — no device dependency).
4. README: 60-second quickstart, the recoverability table, the exhaustive-switch example, and the **"why not just persist `session.transcript`?" section** — the incumbent is the SwiftData transcript blob (§2), and the README answers it before the reader asks.
5. Tagged `0.1.0`; pre-1.0 SemVer caveats stated; ADR-001 committed (tagged-JSON event encoding; discriminator registry — tags never reused, removed tags reserved forever; unknown-discriminator → quarantine with the single tolerant-terminal exception; the gap-diagnostic rule; version-frozen fixture corpus; upcasters named as the evolution idiom).

## 14. Open questions

Resolved items from rev 1 have been folded into the spec body (rev 2's Appendix B has that map). Still genuinely open — all beta-empirical, one spike evening each, likely recurring per beta:

1. **Transcript seeding:** initializer shape for materializing a transcript into a `LanguageModelSession` in iOS 27 (iOS 26 had `LanguageModelSession(transcript:)`).
2. **Tool-activity observation:** what iOS 27 exposes for observing tool invocations on the response/stream (feeds §7.6) — and whether transcript entries for tool exchanges can be constructed app-side (feeds the v0.2 transcript-fidelity item, §12).
3. **`LanguageModel` conformance surface:** exact model + executor requirements, so `ScriptedLanguageModel` conforms to the real thing, not a guess.
4. **Snapshot stream element types:** what the cumulative-snapshot stream vends (feeds §7.3 prefix-diffing).
5. **Built-in `LanguageModelError` inventory:** the case list `GenerationError` must totally cover (§8) — including exact case *names* (iOS 26 surfaced `appleIntelligenceNotEnabled`; the 1:1 normalization claim earns matching names).
6. **Session single-flight surface:** the exact error/behavior when a second request hits a responding session (feeds §6.5/§7.2). iOS 26 evidence: it surfaced *as* `GenerationError.rateLimited` — single-source, verify; this is why §7.2 gates on `isResponding` and treats a leak as a driver defect rather than letting it normalize as `retryable`.
7. **Context-management & KV-cache APIs:** confirm the new iOS 27 context APIs stop at the session boundary — this is the sherlock check for §2.
8. **`ModelDescriptor` derivation, narrowed (rev 4):** the resolved identity now comes from response metadata (§7.8); the residual question is whether the *requested* descriptor is derivable from `any LanguageModel`'s configuration surface or must be app-supplied at driver init.
9. **Reasoning & custom segments (rev 4):** what the iOS 27 stream and transcript expose for reasoning entries and provider custom segments — observable? recordable? re-constructible into a seeded transcript? Feeds §7.3's ignore rule, N11, and the v0.2 transcript-fidelity item (§12).

---

## Appendix A — Blog exhaust map (posts fall out; they do not gate)

- "Apple shipped the inference layer. Here's the layer they didn't." — the §2 boundary map. **Time-sensitive: WWDC analysis has a shelf life; this one should ship first, now.**
- "Your transcript blob is not a ledger" — the §2 incumbent argument; doubles as the README's why-not section (DoD-4) and pairs with the launch post.
- "Conversations are ledgers: event-sourcing LLM chat state" — §6.
- "Crash-proof streaming by construction" — I5 + crash-point fuzzing.
- "The interruption you could forge: fixing an invariant by loosening a decoder" — the rev 3 tolerant-terminal story; pairs with the crash-proof post.
- "Testing Foundation Models apps without a device" — ScriptedLanguageModel.
- "Deleting from an append-only log" — the §9/N9 erasure tension, once the v0.2 design doc exists.
- Optional: "Model-checking a chat app" — the TLA+ appendix, if written.

## Appendix B — Changes from rev 3

- **The outcome boundary, stated (§7.2, new subsection):** `generationStarted` is appended *before* the provider request is issued; every failure after the append is an `Outcome`, never a throw — including zero-token request-time failures (auth, instant guardrails), which render as `.failed(partial: "")`. This is what makes §8's reauthenticate row reachable through observation; rev 3 assumed it silently. Task-cancel gains its boundary: pre-append throws `CancellationError` (nothing started — convention holds), post-append returns `.cancelled` (§11's deviation, now crisp). Defensive `isResponding` gate added: a busy-session error is a driver defect (`"driver: session busy"`), never normalized — iOS 26 evidence says session-busy surfaced *as* `rateLimited` (OQ6), which would have classified a programming error as retryable.
- **Rehydration fidelity scoped (tenet honesty):** the §7 ownership rule now says rebuild is *text-fidelity*; §7.1 enumerates fidelity classes — instructions exact; path text exact, partials included; tool-call/tool-output entries **never reconstructed in v0.1** (under `.metadataOnly` unrecoverable by design; under `.full` deferred to v0.2); reasoning entries unrecordable (OQ9, new). N11 added; v0.2 gains the transcript-fidelity item. Post-crash regeneration differing from the live session's counterfactual is now owned, not implied.
- **Reduction pipeline named (§6.3):** `fold → classify → overlay`; `FoldedState` (= `Conversation` minus `Recoverability`) is the layer snapshots always implicitly stored and now explicitly is the snapshot schema (§9); I1 split into two determinism halves; snapshots persist accumulated diagnostics; **P3 (snapshot equivalence) added (§10.6)** — `resume(snapshot, suffix) == fold(fullLog)`, diagnostics included, randomized snapshot points. Rev 3 shipped the snapshot fast-path as the only untested reduction path; that hole is closed.
- **Start atomicity (§6.5):** single-flight check + the verb's appends + in-flight registration are one actor critical section; `send` = `userMessageAppended` + `generationStarted` in one transaction (§9) — a losing racer records *nothing*, no orphaned user message with the path yanked onto it. "`try` guards did-it-start" is now literally true.
- **`respond` generalized; `regenerate` becomes exact sugar (§6.4/§11):** any generation start whose parent isn't the endpoint emits `activePathChanged` in the same transaction — a requested generation never streams invisibly. Rev 3 stated this only for regenerate, leaving `respond(to:)` at a non-endpoint target silently off-path. `regenerate ≡ respond(to: parent)` with no residue.
- **Target eligibility + role adjacency (§6.1/§6.5/§6.6):** store enforces targets (respond: user; regenerate: assistant; edit: user — an assistant-parented generation is the continuation shape, v0.2 research, not an accident); the reducer deliberately tolerates role adjacencies (N10 pattern — wire headroom). Recorded as explicit §6.6 non-rules with fixtures, so the "complete inventory" claim stays true.
- **Flush semantics (§7.4):** only `deltaAppended` coalesces; every other event appends synchronously. Closes the vanishing-turn hole: a crash before the first delta flush could previously have erased the generation entirely (user message persisted, no `.interrupted` bubble).
- **Model identity split (§7.8; OQ8 narrowed):** *requested* descriptor rides `generationStarted`; *resolved* identity (response-reported, e.g. `modelID` via executor metadata) lands in `StopInfo`. Silent provider backend upgrades become visible as request ≠ resolved. Driver↔session↔conversation **cardinality stated**: one driver, many conversations; sessions cached per-conversation, never shared across (Apple sessions are single-flight).
- **Projection completeness (§6.2):** `Message` gains `stopInfo` (usage incl. cached/reasoning token counts — recorded-but-unprojectable is a bug) and `terminalTimestamp` (gives `rateLimited(retryAfter:)` its instant; the persisted duration stays clock-independent, §8). Both live on `Message`, not in `MessageState` cases — the showpiece switch stays stable.
- **`deleteConversation` cancels first (§9/§11):** cancel runs to its terminal through the actor (suspended verb returns `.cancelled`, not a persistence error), then the DELETE commits; the race is sequenced away.
- **N3 stated honestly:** full-path rehydration can *exceed* the window compaction was hiding; with small on-device budgets, long conversations may be unregenerable after process death until v0.3 — graceful, typed failure (`reduceContext`), but a failure.
- **The incumbent named (§2, Appendix A, DoD-4):** the day-one competitor is the SwiftData transcript blob, not a hypothetical Apple store; the five-way mechanical argument against it is now in the spec, the README plan, and the blog map.
- **Hostile inventory grew (§6.1/§6.6/§10):** mid-log sequence **gaps** — one diagnostic per contiguous gap, reduction continues, gap-swallowed terminals correctly yield `.interrupted`; interior-gap crash-fuzz variant; **cascade fixture** (quarantined start ⇒ rows 9–10 residue, asserted exactly); busy-session normalization-exclusion fixture (§10.5).
- **Smaller:** `sequence` is `Int64` and physically lives only in the table key — the blob omits it, so blob/column mismatch is unrepresentable; `conversationID` duplication stays (it is what row 4 checks). `titleChanged(String?)` — nil clears, symmetric with instructions. Index updates skip delta flushes (no ~4 Hz churn of the conversations table and its observers mid-stream). I6 drops the vestigial "or edit" (edits create siblings; they cannot invalidate a path — rev 2 leftover). RFC 9457 cited as prior art, not authority (`code` has no 9457 field; the RFC's slot is a `type` URI no provider ships). `ModelUnavailability` mirrors Apple's case names (`appleIntelligenceNotEnabled` — OQ5). §7 mechanics promoted to real numbered subsections (§7.1–§7.8; all cross-references updated — rev 3's list-item references were one reorder away from dangling). `conversationList` moved to the `@MainActor` projection in the §11 sketch — the store actor exposes no synchronous reads.
- rev 2 → rev 3 map: see rev 3's Appendix B.

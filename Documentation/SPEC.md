# LedgerKit v0.1 — Design Specification

**Status:** **rev 8 — ratified 2026-07-28 at the M5 boundary**; subsequent amendments open rev 9. Rev 7 was ratified 2026-07-26 at the M4 boundary; rev 6 on 2026-07-26 at the M3 boundary; rev 5 on 2026-07-25 at the M2 boundary.
**Date:** 2026-07-28 (rev 7: 2026-07-26, rev 6: 2026-07-26, rev 5: 2026-07-25, rev 4: 2026-07-13, rev 3: 2026-07-12, rev 2: 2026-07-12, rev 1: 2026-07-09)
**Targets:** iOS 27 / macOS 27 (Foundation Models `LanguageModel` protocol as inference substrate)
**Changes from rev 7:** Appendix F — two items from the M4 boundary audit, nine from M5. No invariant weakens, no event kind changes, nothing touches the wire.

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

**Sherlock-risk assessment:** Apple's direction of travel is upward (2025: inference → 2026: providers, compaction, skills, richer context-management and KV-cache APIs). The defensible ground is durable app-level state: platform vendors historically stop at the session boundary and leave persistence, identity, and cross-launch state to apps. A session is not a store. The new context-management APIs sit *adjacent* to this boundary, and **rev 7 verified they stop at the session edge (OQ7 closed, read from the SDK)**: `ContextOptions { includeSchemaInPrompt, reasoningLevel }` is per-request; `TranscriptErrorHandlingPolicy { revertTranscript, preserveTranscript }` is per-session; `session.usage` aggregates within a session; `Transcript` is `MutableCollection` + `RangeReplaceableCollection`. Every one of them is session-scoped, and none persists anything. The last is the most interesting result: **Apple made the working copy officially mutable, which is an argument *for* durable truth living outside it, not against.** A transcript you can splice in place is a working buffer, not a record — a record is the thing you can still trust after someone spliced the buffer. If Apple ships a "conversation store" in 2027, LedgerKit's residual value is the branching model, recovery semantics, and test infrastructure — but price that risk in: this is a 2–4 year asset, which is the correct horizon for a positioning play anyway.

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
- **N3.** No compaction awareness. In-session compaction is invisible to LedgerKit in v0.1; rehydration materializes the full active path. Accepted consequence, stated honestly (rev 4): a rebuilt session sees more context than the compacted live session it replaces — and may therefore *exceed the window that compaction was hiding*. On-device budgets are small (reported ~4k shared tokens — ⚠️ verify against the beta), so a long on-device conversation can be unregenerable after process death: rehydration fails with `contextSizeExceeded` (rev 6 name), which classifies to `recoverableUpstream(.reduceContext)` (§8), and the app-side escape is a utilities compaction pass before retry. The failure is graceful and typed, not silent — but it is a failure, and pretending the consequence is merely "sees more context" undersold it. Compaction bookkeeping arrives in v0.3, and the event carries the summary text (§12) so rehydration and audit can reproduce what the model saw.
- **N4.** No RAG, embeddings, or search.
- **N5.** No sync. The event log is designed to permit log-shipping later; nothing is built.
- **N6.** No UI components. State machine + observation only.
- **N7.** No tool *orchestration*. FM executes tools inside the session; LedgerKit records invocations as events for replay/audit. Driving multi-step agent loops is v0.2+ at most.
- **N8.** No guided-generation structured partials in v0.1 (plain-text assistant content only). The event model reserves room via `MessageContent` (§6.2 — renamed from `Content` at M4; wire-neutral, since Swift type names reach no encoding).
- **N8a (rev 7). Text-only *user* content is an owned scoping decision, not an accident of the iOS 26 shapes.** `userMessageAppended(content: String)` carries text and nothing else, while 27 permits attachment segments in a prompt (see N11). The decision stands for v0.1 on the same grounds as N8 — the state machine, the branching model and the recovery semantics are what this release is *for*, and none of them gets more true with images in it — and it is **additive to reverse**: attachments arrive as a new payload kind, or as a widening of the content field, both of which old readers degrade on rather than corrupt (§6.6 row 2, ADR-001). Stated because "we only support text" reads as an oversight when the platform supports more, and this one is a choice with a date on it.
- **N9.** No message-level erasure or redaction — conversation-level delete only (§9). Append-only logs and erasure are in structural tension; resolving it is a deliberate design exercise (v0.2 design doc, §12), not a checkbox.
- **N10.** No assistant-initiated conversations through the v0.1 store API. The *wire format* has headroom — `generationStarted(parent: nil)` is a virtual-root child the reducer accepts (I6) — so enabling model-generated openers later is a store-policy relaxation, not a migration (the §6.5 pattern: log tolerant, store enforces). The v0.1 store simply never emits one.
- **N11.** No transcript-entry-complete rehydration (rev 4, the honest scope of tenet "rebuild from the ledger"). Apple's `Transcript` carries six entry kinds — instructions, prompt, response, tool calls, tool outputs, reasoning. The v0.1 ledger represents the first three (as text) plus tool invocations as `ToolRecord`s; rehydration reconstructs **text + instructions only** (§7.1 fidelity classes). Tool-call/tool-output entries are not re-materialized into rebuilt transcripts under *any* recording policy in v0.1, and reasoning entries are **deliberately not recorded** (rev 7). The rev-4 wording said "not even recordable," which the 27 SDK falsifies: reasoning is observable (the executor channel has a `Reasoning` action family with its own `appendText` / `replaceTextSegment` and a `ReasoningSignature`) and constructible (`Transcript.Reasoning { id, segments, signature: Data? }`). So this is a scoping decision that must be defended rather than an incapacity to note. It is defended: reasoning text is the most sensitive content a model produces and the least stable across providers and versions, the ledger outlives the session (§9 privacy), and v0.1's `.metadataOnly` default for *tool* results applies the same judgement to a strictly less sensitive category. v0.2 revisits reconstruction from `.full` tool records (§12).

**What did change at 27 is one level down (rev 7): `Transcript.Segment` grew from two cases to four** — `text`, `structure`, and now `attachment` and `custom`. The **entry** kinds did not change; the things entries *contain* did. So a prompt or response entry may legally carry image attachments or provider-custom segments, and Apple's `Attachment<Content>` is `PromptRepresentable`, which makes multimodal user input a real 27 feature rather than a rumour — hence N8a, which owns v0.1's text-only scope instead of leaving it to look like an oversight.

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
        case userMessageAppended(message: MessageID, content: String, parent: MessageID?)
        case instructionsChanged(String?)   // nil clears; see §7.1
        case generationStarted(generation: GenerationID, message: MessageID, parent: MessageID?, model: ModelDescriptor)
                                            // parent nil ⇒ child of the virtual root (I6). The v0.1
                                            // store never emits nil — wire headroom for N10.
                                            // model = the *requested* descriptor (§7.8).
                                            // Labels are wire-neutral (rev 8): tags live in the
                                            // discriminator registry, field keys in CodingKeys.
        case deltaAppended(generation: GenerationID, text: String)
        case toolInvocationRecorded(generation: GenerationID, record: ToolRecord)
        case generationEnded(generation: GenerationID, outcome: Outcome)
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

**Interruption is not an outcome — and terminals are decode-tolerant.** There is deliberately no `Outcome.interrupted` in the wire format. Interruption is a *derived* message state, synthesized by the reducer from the absence of a terminal event (I5). It cannot be written to a log directly. Rev 2 claimed this made interruption unforgeable and left a hole: quarantining an *undecodable* terminal (a hostile garbage outcome, or an `Outcome`/`GenerationError` case added by a future LedgerKit) removed the terminal from reduction — which is exactly what synthesizes `.interrupted`. The quarantine mechanism manufactured the forgery, and a v0.2 log's new error case would have re-rendered historical *failures* as *crashes* on v0.1 readers. Rev 3 closes it with a tolerant-reader exception: **a `generationEnded` whose nested outcome doesn't decode still lands as a terminal** — `.failed(.unrecognized("undecodable outcome: <discriminator>"))`. Consequences: hostile logs can forge *failures* only (harmless — that is what failures are for); forward compatibility degrades an unfamiliar outcome into a generic failure instead of a fake crash; and I5's meaning stays crisp — `.interrupted` arises only when the terminal is genuinely *absent or unreadable at the row level* (process death, bit rot), never merely unfamiliar. This is the single deliberate asymmetry in decode strictness — everywhere else, a quarantined event is contained loss; terminals are the only events whose *absence* carries meaning (I5), so they alone get the tolerance. ADR-001 owns the rule. **The rule keys on the outcome failing to decode, not on its tag being unfamiliar — and that breadth has one owned cost (rev 5).** A corrupt `completed` body degrades to `.failed(.unrecognized("undecodable outcome: completed"))`: a generation that *did* complete re-renders as a failure. That is the right trade twice over — terminal-*ness* is the only property I5 depends on, and it is preserved; and the misreported kind costs one already-damaged row, where the narrow rule would have re-opened the forgery hole for every corruption that is not a clean unknown tag. Residual honesty: a fully undecodable row that happened to *be* the terminal still yields `.interrupted` — correct, because you truly don't know how it ended.

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

`StopInfo` and `ModelDescriptor` remain illustrative. `StopInfo` carries usage from `Response.usage` — spanning input/output with cached and reasoning token counts (**field names verified at rev 7; the mapping table is in §7.7**) — plus `stopReason: String?` and `resolvedModelID: String?`. **Both of those are per-provider convention, not framework surface (rev 8, scoping rev 7's "verified" claim honestly):** the verification covered the four usage fields, and the M4 audit read the interface for the rest — no stop-reason key exists anywhere in the 27 SDK (§7.7), and `resolvedModelID` was already known to be convention (§7.8, OQ8). **Nil is the expected value for both on-device**, and a nil must never read as a failure. `ModelDescriptor` identifies the *requested* provider + model + version well enough for branch-compare across models, and rev 7 settles that it is **app-supplied**: nothing in the framework exposes a model-identity key to derive it from. Evolution note: structs with optional fields tolerate additive change; *enums* are the evolution cliffs. A new enum case inside a non-terminal payload (e.g. `ToolRecord.Status`) quarantines that event only — contained loss, accepted. Terminals get the tolerance exception above.

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
    public var generationID: GenerationID?       // assistant only — I7's 1:1 binding, surfaced
                                                 // (rev 5). The folded layer *requires* it to
                                                 // route deltas after a snapshot resume, so
                                                 // projecting it costs nothing and aids audit.
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
    public var reason: QuarantineReason         // closed enum, one case per §6.6 row (rev 5).
                                                // CustomStringConvertible renders the log prose,
                                                // so the inventory is compiler-checked and
                                                // fixtures assert cases, never sentinel strings
                                                // (which ADR-001 declares non-contractual).
}

public enum MessageState: Sendable {
    case complete(MessageContent)
    case streaming(partial: String)
    case failed(partial: String, error: GenerationError, recoverability: Recoverability)
    case cancelled(partial: String)
    case interrupted(partial: String)
}

public struct MessageContent: Sendable {
    public var text: String
}
```

User messages are always `.complete`. Assistant messages traverse the machine. There is deliberately no `.pending` distinct from `.streaming(partial: "")` — collapsing them removed a state with no distinct UI meaning; reintroduce only if a provider exposes a meaningful queued phase.

`MessageContent` is a struct, not a bare `String`, on purpose: N8's structured partials extend it additively in v0.2 without a source-breaking change, and without turning `MessageState` — the exhaustive-switch showpiece — into a moving target. (`stopInfo` and `terminalTimestamp` live on `Message`, not inside the enum cases, for the same reason: the showpiece switch stays stable.)

`Recoverability` in `.failed` is **derived at classification time, never persisted** — see §6.3 (the fold → classify → overlay pipeline) and §8. Two of these states are derived-only in a stronger sense, and they are duals: `.interrupted` is fold-derivable only (dead logs); `.streaming` is projection-only (live stores, via the §7.4 overlay — no fold of any log ever yields it). Neither is wire format.

### 6.3 Reduction invariants

Reduction is a **pipeline, named precisely in rev 4** because snapshots and tests depend on the seams:

```
fold(log) -> FoldedState                      // pure; open generations stay OPEN.
                                              // Failures carry GenerationError only.
classify(folded, mapping) -> Conversation     // finalizes AND classifies: open ⇒ .interrupted (I5),
                                              // and mapping: (GenerationError) -> Recoverability
overlay_live(...)                             // projection-side only — §7.4; never part of reduce
```

`reduce(log, mapping) ≡ classify(fold(log), mapping)` is the convenience composition the API exposes. `FoldedState` is exactly the snapshot schema (§9): the middle layer was always implicitly there (snapshots store errors and recompute classifications); rev 4 just gives it a name so the seam is testable (P3, §10).

**The two layers carry different state enums, and the difference is the point (rev 5).** Rev 4 called `FoldedState` "`Conversation` minus `Recoverability`," which understated the consequence: `Recoverability` lives *inside* a `MessageState` case, not beside it, so the folded layer has its own message-state enum — four cases where the public one has five:

```swift
// Folded — persisted (the snapshot schema, §9). No Recoverability, no .streaming, no .interrupted.
enum FoldedMessageState: Sendable, Codable {
    case complete(MessageContent)
    case open(partial: String)               // started, not terminated. NOT a claim about why.
    case failed(partial: String, GenerationError)
    case cancelled(partial: String)
}
```

One fact appears under three names, at three levels of knowledge, and the progression is the whole recovery story in one table:

| Folded (persisted) | Classified (public) | Overlaid (live, §7.4) |
|---|---|---|
| `.open(partial:)` — the log does not say it ended | `.interrupted(partial:)` — and reduction is finished, so it never will | `.streaming(partial:)` — unless this process is still generating it |

Reading right-to-left is the crash: the overlay disappears, and the fold's honest "no terminal exists" surfaces as `.interrupted`. Reading a *snapshot* is why `.open` must exist — an intermediate fold has not finished reading, so it has not earned `.interrupted`, and storing that state would make reduced state depend on snapshot timing. **A snapshot that could hold `.interrupted` is a snapshot that can forge a crash; giving the folded layer its own enum makes that unrepresentable rather than merely forbidden** (tenet 1). P3 (§10) is the executable version of the same guarantee.

**The folded layer is `Codable` in its entirety — and that conformance commits to nothing.** Snapshots are discard-on-mismatch with no migration ever (§9), so the folded encoding is disposable in a way the event wire format emphatically is not. `MessageContent` and `QuarantinedEvent` therefore gain `Codable` for the snapshot path alone; adding a field to either is free, where the same change to `Payload` would be forever. Keeping `FoldedState` internal — consumers only ever hold `Conversation` — makes that asymmetry structural rather than a comment. **The one conformance that stays load-bearing is `GenerationError`'s**, which is on both paths: inside `Outcome` on the wire *and* inside `FoldedMessageState.failed` in snapshots.

Names above are illustrative per §6.1's standing rule; the semantics are not. The test suite must enforce:

- **I1 (Determinism, two halves):** Same log ⇒ same `FoldedState`, on every platform, every time — no wall-clock or environment reads inside the fold. Same `FoldedState` + same mapping ⇒ same `Conversation` — **including the `.open ⇒ .interrupted` finalization, which takes no input beyond the folded state itself and so cannot perturb this half (rev 5).** The mapping is part of classification's identity; keeping it an explicit input keeps I1 honest while allowing apps to customize (§8).
- **I2 (Totality & quarantine):** Every log reduces without trapping. Semantically malformed events and *undecodable* events (bit rot, unknown payload kinds written by a future LedgerKit) are **skipped**: reduction continues as if the event were absent, and each skip appends a `QuarantinedEvent` (sequence + reason) to `Conversation.diagnostics`. The targeted message is unaffected — a delta-after-end is dropped; the message stays in its terminal state. Sequence *gaps* are absences, not events: reduction continues across them, one diagnostic per contiguous gap (§6.1). The full condition inventory is the normative table in §6.6, which is also the hostile-fixture checklist (§10). One deliberate exception: undecodable *outcomes* inside a decodable `generationEnded` do not quarantine — they land as `.failed(.unrecognized)` (§6.1), because a lost terminal is not contained loss. Diagnostics are for logging and debug surfaces, not user-facing by default. Consequence worth advertising: a log written by LedgerKit v0.4 still *loads* on v0.1, degraded but alive.
- **I3 (Single termination):** Per `GenerationID`, at most one `generationEnded`. The driver enforces at-most-once emission; the reducer treats a second terminal as malformed (§6.6).
- **I4 (Generation-scoped bounds):** `deltaAppended` **and** `toolInvocationRecorded` are valid only between `generationStarted` and `generationEnded` for that `GenerationID`. Out-of-bounds events quarantine (§6.6) — a terminal message's content *and audit trail* are immutable post-terminal.
- **I5 (Recovery):** Any generation with a `generationStarted` and **no terminal event anywhere in the log** reduces to `.interrupted(partial:)` — the concatenation of persisted deltas. Order-agnostic by construction: the rule is "no terminal exists," not "the log ends with," so it holds even with interleaved events from other activity. This is the entire crash-recovery mechanism: no dirty flags, no recovery pass, no repair job. The absence of a terminal event *is* the signal, and it cannot be skipped. Because terminals decode tolerantly (§6.1), "no terminal" means genuinely missing or row-level unreadable — process death or bit rot — never a merely unfamiliar outcome kind. `.interrupted` is a *finalization-time* classification (like `Recoverability`): an open generation in an intermediate fold — a snapshot, say (§9) — is stored open, and only a completed reduction with no live overlay (§7.4) classifies it interrupted.
- **I6 (Tree integrity, virtual root):** The tree hangs off an implicit **virtual root** — not a message, created by no event, never on `activePath`, never rendered. Every node with `parent: nil` is a child of the virtual root; root-level sibling order is sequence order, like everywhere else. The first `userMessageAppended(parent: nil)` opens the tree; a *subsequent* bare nil-parent append still quarantines — "new topic" remains "new conversation," and an accidental nil parent should not silently become a hidden branch. Root-level *siblings* arise in exactly two ways: `messageEdited` of a root-level message (the edit names its original, so variant intent is explicit — this is what makes editing the first message legal, something rev 2 accidentally forbade), and — as wire headroom only — nil-parent `generationStarted` (N10; the reducer accepts them, the v0.1 store never emits one). Every non-nil parent must exist and precede its child in sequence order. `activePath` is always a valid chain from one root-level node to the **endpoint**, where the endpoint is any node — it need not be a tree-leaf. The reducer clamps to the nearest valid ancestor if a quarantined event invalidates the path.
- **I7 (Identity):** `GenerationID` ↔ `MessageID` is 1:1 in v0.1. A `generationStarted` naming an already-bound MessageID quarantines (§6.6). Continuation-style resume would relax this to N:1; that is exactly why it is v0.2 research, not a v0.1 promise (§12). **`MessageID` allocation is additionally *once-only* (rev 5), which is the stronger and more basic half of this invariant: the three events that introduce a node — `userMessageAppended`, `generationStarted`, and `messageEdited`'s `replacement` — each quarantine on an ID the tree already holds (§6.6 rows 6, 8, 11). An ID that has ever named a node can never name another. Without it an append-only log would admit silent in-place rewrites of existing nodes, including of an in-flight assistant message whose ID was bound at its `generationStarted` — user-authored assistant content by the back door (§6.1).**

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

Why this split matches the ecosystem: Apple's `LanguageModelSession` is single-flight — `isResponding` exists and concurrent requests to one session are an error, **typed as `LanguageModelSession.Error.concurrentRequests` at 27 (rev 7, OQ6 closed)**. At 26 that condition lived in the same enum as `rateLimited`, which is the hazard §7.2's gate exists for: session-busy must never normalize as provider rate limiting, and the 26 enum is deprecated rather than gone (§8). OpenAI's Assistants API — the one mainstream design that held server-side conversation state — enforced one active run per thread. Chat products (Claude.ai, ChatGPT) enforce one stream per visible thread client-side. Provider HTTP APIs are stateless and don't care. Precedent is consistent: *inference* concurrency is a rate-limit question; *conversation-state* concurrency is single-flight.

Throw, don't queue: queuing hides a product decision (should the second send target the new leaf that the in-flight generation is about to create?) inside a library. Surfacing `generationInFlight` lets the app disable the send button, which is what every chat UI does anyway.

**Mid-stream edits and switches are legal.** Single-flight gates *generation starts* (`send` / `respond` / `regenerate`, §11), not ledger writes: `switchBranch` and `edit` remain available while a generation streams. A mid-stream switch moves the visible path; the stream continues off-path (auto-extend already fired at `generationStarted`) and terminates normally — completion changes state in place and emits no path event, so the bubble stays wherever the user left it. An edit-then-respond during flight hits `generationInFlight` on the respond. Whether switching away should *cancel* is a product decision — the store exposes `cancelGeneration(in:)` (§11) and takes no position. One verb overrides rather than respects the flight: `deleteConversation` cancels first, then deletes (§9).

**Store-written logs never quarantine (rev 8 — the healthy-log property).** Every log produced by store verbs reduces with **empty `diagnostics`**: the store cannot write an event the reducer would skip. Implied since rev 1 and never stated, which was fine while nothing read `diagnostics`; it becomes load-bearing the moment an app treats a non-empty `diagnostics` as evidence — of damage, of partial restore, or of a *newer* LedgerKit having written this log (§6.6 row 2, the forward-compatibility row). That reading is only sound if the store itself never contributes noise.

Note carefully what the property does **not** claim. A healthy log is not a *correct* one: an `edit` that omitted its paired `activePathChanged` (§6.4) would reduce without a single diagnostic while being semantically wrong, because nothing about it is malformed. The property certifies that the store never writes something the reducer would *reject*; that it wrote the *right* thing is a per-verb obligation with per-verb tests (§10). Conflating the two would make a green quarantine table look like a proof of correctness, which it is not.

Priced-in future: parallel sibling generation — regenerate on two models simultaneously and branch-compare — is representable in today's log and becomes a v0.2+ *store-policy relaxation*, not a migration (§12).

### 6.6 Quarantine rules (normative)

The single inventory of conditions the reducer skips. Disposition for every row is the same — skip the event, continue reduction, append a `QuarantinedEvent(sequence:eventID:reason:)` to `Conversation.diagnostics`, leave targeted entities untouched (I2) — except row 3, the one deliberate exception. This table **is** the hostile-fixture checklist (§10) and is owned by ADR-001.

| # | Condition | Disposition |
|---|---|---|
| 1 | Row undecodable at the envelope level (no event identity recoverable) | Quarantine — sequence-only diagnostics |
| 2 | **The payload cannot be decoded, with the envelope intact** — an unknown discriminator (written by a future LedgerKit), *or* a discriminator this version knows carrying a body it cannot read | Quarantine — conversation loads degraded; the diagnostic names the discriminator where one was legible |
| 3 | `generationEnded` decodes, but its nested `Outcome` does not — unknown discriminator, unknown nested `GenerationError` discriminator, corrupt or malformed body, or the field absent entirely | **No quarantine** — lands as `.failed(.unrecognized("undecodable outcome: <tag>"))`, or `"undecodable error: <tag>"` where the `Outcome` itself read but its nested `GenerationError` did not. `<tag>` is the recovered discriminator, or `<missing>` / `<unreadable>` where none is legible (tolerant-terminal rule, §6.1) |
| 4 | Envelope `conversationID` ≠ the stream the event was loaded from | Quarantine — cross-stream contamination |
| 5 | Any event before genesis; a second `conversationCreated` | Quarantine |
| 6 | `userMessageAppended` naming an unknown parent, **or reusing a `MessageID` the tree already holds** (I7) | Quarantine |
| 7 | A bare `userMessageAppended(parent: nil)` after the first | Quarantine — the "new topic ≠ new branch" guard (I6) |
| 8 | `generationStarted` reusing a `GenerationID`, binding an already-bound `MessageID` (I7), or naming an unknown parent | Quarantine |
| 9 | `deltaAppended` / `toolInvocationRecorded` / `generationEnded` naming an unknown `GenerationID`; or `deltaAppended` / `toolInvocationRecorded` outside the started→ended bounds (I4) | Quarantine |
| 10 | A second `generationEnded` for the same `GenerationID` (I3) | Quarantine |
| 11 | `messageEdited` whose original is assistant-authored, or unknown, or whose replacement ID already exists | Quarantine |
| 12 | `activePathChanged` naming an endpoint that never existed | Quarantine — distinct from *clamping*, which handles paths invalidated by later quarantines; a never-valid endpoint is malformed, not stale |

**Rows 9 and 10 partition terminals (rev 5).** A `generationEnded` for a generation that never started is row 9 (unknown generation); a *second* terminal for one that did is row 10 (I3). Rev 4's cascade prose already relied on this split — an orphaned start's terminal was said to "quarantine under rows 9–10" — but row 9 named only deltas and tool records, so the first-and-only terminal of a quarantined generation fell outside the inventory it was claimed to be inside. Corrected here; the cascade fixture asserts all three orphaned kinds.

`instructionsChanged` and `titleChanged` carry no references and are always valid after genesis.

**Diagnostic identity (rev 5).** `QuarantinedEvent.eventID` is `nil` for exactly two things: row 1, where no identity survived, and gap diagnostics, where no row exists to have one. **Every other row carries the offending event's `EventID`** — including row 2, which is the one that takes deliberate effort. A single all-or-nothing record decode throws away the envelope along with the unrecognized payload, collapsing row 2 into row 1's diagnostic quality; the decoder must therefore recover the envelope independently of the payload, envelope first, payload second. This is not a nicety: row 2 is the forward-compatibility row, so it is precisely the diagnostic a developer reads when a newer LedgerKit wrote the log, and "sequence 4,102 was unreadable" is a materially worse answer than the same sentence with an event ID in it.

**Row 2 covers two conditions, not one (rev 7).** Rev 6's row 2 said "unknown payload discriminator," and rows 1 and 2 were therefore not the complete partition they claimed to be: a row whose envelope reads, whose payload names a kind this version *does* know, but whose body will not decode is neither "no identity recoverable" (row 1) nor "unknown discriminator" (rev 6's row 2). Found at M4 Phase 2 by a fixture that produced it. **The disposition was already right** — skip the row, keep the identity, keep reading, which is contained loss exactly as for an unfamiliar kind — so nothing about behaviour changes here; the inventory's *description* was incomplete, and an inventory that claims completeness has to be complete. The diagnostic reports the discriminator where it is legible, which is the useful thing either way: "this row said `deltaAppended` and I could not read it" and "this row said `messagePinned` and I have never heard of it" are the same instruction to a reader — look at that row — and the tag tells them which they are looking at. (`wire/undecodableRows` pins both.)

**Corollary for the reducer's input.** Rows 1 and 2 are decode failures, so they cannot arise *inside* the fold — it receives decoded events. The fold's input element must therefore be able to represent an unreadable row rather than omit it: a loader that silently drops one turns a row-1/2 condition into a **gap** diagnostic, which is a different and false claim (a gap says the fact is missing; an undecodable row says the fact is present and unintelligible). Reduction consumes a row that is *either* a decoded event *or* a readable key with unreadable contents.

**Deliberate non-rules, recorded so the inventory stays complete (rev 4):** Role adjacency — a `generationStarted` with an assistant parent, or consecutive user-authored siblings — does **not** quarantine; it is wire headroom under store enforcement (§6.1, §6.5). Sequence **gaps** are absences, not skipped events: one diagnostic per contiguous gap, reduction continues (§6.1). And **cascades are expected, not pathological**: a quarantined `generationStarted` (row 8) orphans that generation's deltas, tool records, and terminal, which then quarantine individually under rows 9–10 — a fixture asserts the cascade's exact residue rather than pretending it can't happen (§10). Duplicate **`EventID`** across two rows likewise does **not** quarantine (rev 5): `sequence` is the sole identity reduction depends on (§6.1), and `EventID` earns its keep in debugging, index locality and future log-shipping — none of which the reducer consults. A collision is a generator defect worth finding, not contained loss worth skipping an otherwise-valid fact over.

**Ordering is a precondition, not a rule (rev 5).** Reduction consumes rows in ascending `sequence` order and does not verify it. A row *above* the expected next sequence is a gap (above); a row at or *below* it is applied normally — no diagnostic, and the gap cursor does not move. The store cannot produce either violation: `(conversation_id, sequence)` is UNIQUE and reads are ordered, so enforcement would be unreachable code, and the fold cannot distinguish a duplicated row from a legitimately re-read one without exactly the state §6.3 keeps out of it. The exposure is narrow and worth naming precisely: **only `deltaAppended` and `toolInvocationRecorded` are non-idempotent under replay** — they accumulate. Every other kind either quarantines on its own once-only rule (`conversationCreated` → row 5; `userMessageAppended` / `messageEdited` → rows 6/11; `generationStarted` → row 8; `generationEnded` → row 10) or is last-write-wins and therefore idempotent (`instructionsChanged`, `titleChanged`, `activePathChanged`). Two consumers can violate the precondition and must not: M3's fuzz generators, and any future import or log-shipping tooling (§12), where an overlapping resume suffix would silently double a message's partial text rather than fail. Recorded here because this inventory claims completeness, and this was the last condition with no stated disposition.

---
## 7. The session seam (Foundation Models integration)

The one OS-coupled module. Everything in §6 is pure Swift and platform-agnostic — which matters when the framework's open-sourcing lands and Swift-on-server becomes a target (out of scope now; costs nothing to preserve).

**Ownership rule:** LedgerKit is durable truth; `LanguageModelSession` is an ephemeral working copy. Sessions are cattle. Any session can be discarded and rebuilt from the ledger at any time — which is precisely why instructions live *in* the ledger (§7.1): a ledger that can't rebuild the session isn't the truth. Rev 4 scopes the claim honestly: rebuild is **text-fidelity, not transcript-entry-fidelity** — §7.1's fidelity classes and N11 state exactly what a rebuilt session contains and what it doesn't. The tenet's force is unchanged where it matters (the visible conversation and its instructions); its limits are now stated instead of implied.

Mechanics follow, as real subsections since rev 4 (rev 3's unnumbered list made `§7.x` references fragile). Verify exact APIs against the iOS 27 beta — flagged inline.

### 7.1 Rehydration

To generate from leaf *m*: materialize the active path — from its root-level node; the virtual root contributes nothing — **plus the current instructions** (latest `instructionsChanged` in the log; nil ⇒ none) into a session transcript. **The initializer is confirmed (rev 7, read from the 27 SDK): `LanguageModelSession(model: some LanguageModel, tools: [any Tool] = [], transcript: Transcript)`** — generic over the model, so rehydration is provider-agnostic exactly as §7.8 assumes, with a `SystemLanguageModel`-defaulted convenience overload beside it. `Transcript` is `Codable`, `MutableCollection` and `RangeReplaceableCollection` at 27, so materializing one is ordinary collection-building; the ledger→transcript direction has no API risk left in it. Session reuse across turns in the same live conversation is a KV-cache-relevant optimization — do it when the session is still valid, but correctness never depends on it (cardinality rules in §7.8).

**Fidelity classes (rev 4).** Apple's `Transcript` carries six entry kinds; a rebuilt session contains:

- **Instructions — exact.** The latest `instructionsChanged`, always.
- **Prompt/response text — exact, partials included.** Every message on the active path contributes its current text — including the partial of a `.failed`/`.cancelled`/`.interrupted` message if the user kept it on the path. What the user saw is what the model sees.
- **Tool calls / tool outputs — not reconstructed.** Under *any* recording policy in v0.1: with `.metadataOnly` (the default) the outputs were never retained, so reconstruction is impossible by design; with `.full` it is representable but deliberately deferred (v0.2, §12) pending the transcript-entry construction surface (OQ2-adjacent). Consequence, owned: **a rebuilt session's model no longer sees prior tool results** — post-crash regeneration can differ from what the live session would have produced. The audit trail outlives the session's memory of it.
- **Reasoning — absent, by choice (rev 7).** Recordable in principle at 27 — observable on the channel, constructible as a `Transcript.Reasoning` — and deliberately not recorded in v0.1 (N11). Rebuilt sessions never contain reasoning entries.

*Scope caveat:* apps mutating instructions/tools mid-session via Dynamic Profiles are outside v0.1 audit fidelity — LedgerKit records conversation-level instructions only. If your app swaps profiles per-turn, the ledger records which model ran (`ModelDescriptor`), not which profile.

### 7.2 Generation start & the outcome boundary (rev 4)

The rule the entire error-UX story hangs on, stated normatively: **the driver appends `generationStarted` — with its paired `activePathChanged` where §6.4 requires one, and `send`'s user message, all in the verb's single transaction (§6.5) — *before* issuing the provider request. Every failure after that append is an `Outcome`, never a thrown error.** That includes request-time failures that produce zero tokens: an auth failure (401 ⇒ `.failed(.providerFailure)` ⇒ `recoverableUpstream(.reauthenticate)`), an instant guardrail rejection, an unavailable model. This is what makes §8's classification table reachable through observation for the most common server-model failures — without it, the reauth bubble in §11's switch could never render, because the error would have been thrown into a `Task` nobody is switching over. Zero-token failures render as `.failed(partial: "", …)`: an empty failed bubble is a feature (the user sees *that* it failed and *how to recover*), not an artifact.

The throw channel (§11) is exactly the complement — failures *before* the append: unknown conversation, ineligible target (§6.5), `generationInFlight`, persistence failure. Those leave no trace in the log, which is correct: nothing started.

**Task-cancellation across the boundary follows the same line:** cancelled before the append ⇒ the verb throws `CancellationError` — nothing started, Swift convention holds, nothing to record. Cancelled after ⇒ the §7.5 path: the call *returns* `.cancelled` (§11's documented deviation, now with a crisp boundary instead of a vibe).

**Defensive session gate:** the driver checks `isResponding` before issuing, and treats a busy session as a driver defect — `generationEnded(.failed(.unrecognized("driver: session busy")))` — never as a provider signal. The hazard was concrete, and rev 7 can now explain it rather than merely warn about it. **At iOS 26 a single enum — `LanguageModelSession.GenerationError` — carried both `rateLimited` and `concurrentRequests`**, which is why "busy session surfaces as `rateLimited`" was a plausible reading of the evidence. **At 27 the concerns are split:** `LanguageModelSession.Error { concurrentRequests, transcriptMutationWhileResponding }` is session *misuse*, while `LanguageModelError` carries model and provider failures. The whole 26 enum is deprecated case-by-case, each case naming its replacement.

**The gate stays, for three reasons that survive the closure.** The deprecated enum still *exists* at 27, so a provider built against 26 can still throw the overloaded shape; a typed error is only useful to a driver that checks for it, which is what the gate is; and §6.5's parallel-generation relaxation is exactly when store single-flight stops making this unreachable. What changes is the *disposition* of a leak: it is now a recognizable, named condition rather than a mystery, so §8's normalization exclusion can name it. **M6 residue: confirm the 27 error is thrown rather than trapped** — a precondition failure would be a different design problem, and only running it answers that.

### 7.3 Streaming reduction

FM streams *cumulative snapshots*, not deltas. The driver diffs successive snapshots and emits `deltaAppended` with the suffix. For plain text, snapshots are append-only **in practice**, so prefix-diffing is sound; assert the prefix property in debug. **Rev 7 is careful with the word "sound" here — see the amendment below: append-only is provider behaviour, not something the API guarantees.**

**Which side of the stream you are on decides what you see (rev 6 — verified against the iOS 27 SDK, not inferred).** The two halves genuinely differ, and this paragraph exists because the sentence above reads as flatly contradicting Apple's provider-authoring guidance if you have only seen the other side. A **provider writes deltas**: `LanguageModelExecutor.respond(to:model:streamingInto:)` sends `.response(action: .appendText(_:segmentID:tokenCount:))` *fragments* into its channel. A **consumer reads cumulative state**: `LanguageModelSession.ResponseStream` vends `Snapshot` values whose `content` is the partially-generated whole. The framework accumulates in between. LedgerKit's driver is a consumer, so prefix-diffing is both correct and the only strategy available to it, and the ledger's `deltaAppended` events reconstruct *by subtraction* the fragments the provider originally sent. `ScriptedLanguageModel` (§10.1) sits on the **provider** side — which makes the round trip an end-to-end property the corpus can assert: scripted fragment → framework accumulation → snapshot → driver diff → `deltaAppended` must recover exactly the fragments the script emitted. **Release behavior on violation:** the driver fails the generation — `generationEnded(.failed(.unrecognized("driver: non-prefix snapshot")))`, terminal — and never emits a reconstructed or corrupt delta. A wrong transcript is worse than a dead one. (Guided-generation partials are *not* prefix-stable — one reason N8 exists.)

**The stream element, and the limit of the prefix property (rev 7, OQ4 closed).** The element is `LanguageModelSession.ResponseStream<Content>.Snapshot`, carrying `content` (the partially-generated whole), `rawContent: GeneratedContent`, and — new at 27 — `transcriptEntries: ArraySlice<Transcript.Entry>` and `usage: Usage`. That confirms the cumulative-snapshot model rev 5 assumed. It also **withdraws a guarantee this spec implied**: the provider channel offers `replaceTextSegment(_:segmentID:tokenCount:)` beside `appendText(_:segmentID:tokenCount:)`, and both carry a `segmentID`. A provider may therefore legally *revise* a segment it already sent, in which case the accumulated snapshot is **not** a prefix extension of its predecessor. So append-only plain text is a property of well-behaved providers, not of the API.

Three consequences, and none of them changes v0.1's shape. **(1) The fail-loud path is right and stays.** A non-prefix snapshot terminating the generation as `unrecognized("driver: non-prefix snapshot")` was chosen when it looked like a can't-happen assertion; it is now the honest response to a legal provider behaviour this version does not model. A wrong transcript is still worse than a dead one. **(2) M6 should prefer segment-aware diffing** via `transcriptEntries`, which sees the segment identities the flat-string view erases, and fall back to prefix-diffing only where entries are unavailable. **(3) Recording `replaceTextSegment` faithfully would need a new payload kind** — the ledger has no way to express "revise what I already told you", since `deltaAppended` is append-only by construction. That is a v0.2 conversation (§12), priced exactly like §7.6's started/ended split: new kind, old readers quarantine it, degrade rather than corrupt.

**Non-text stream content (rev 4):** provider streams can vend more than text — response metadata, usage updates, and *custom segments* (reasoning, provider-specific segments like search results). **v0.1 records text deltas only.** Non-text segments are ignored — neither persisted nor rehydrated (N11, OQ9) — deliberately and loudly in the docs, not as an accident of the diff loop. Usage and resolved model identity are the two exceptions, captured at completion into `StopInfo` (§7.7, §7.8).

### 7.4 Delta persistence batching — two cadences, one truth hierarchy, one overlay

Writing every token to disk is wasteful; losing 30 s of stream on crash is bad UX. The **store** coalesces *disk* flushes on a policy (default: every ~250 ms or N chars, and always before `generationEnded`). **Rev 8 corrects the attribution, not the behaviour:** rev 2 said "driver", written before the driver seam existed (§7.9). The store owns every append, so the *cadence* of appends is necessarily its business too; what the driver owns is what this section actually cared about — producing deltas rather than snapshots, which is the diffing on the far side of the seam. The *observable projection* applies deltas as they arrive, in memory, ahead of disk — so streaming renders smoothly at display cadence while the log fills at durability cadence. Rev 2 wrote the projection as `fold(persisted log) ⊕ unflushed tail` and left `⊕` undefined; it does more work than "append." Precisely:

`projection = overlay_live( reduce(persistedLog ++ unflushedTail, mapping) )`

where `overlay_live` maps `.interrupted → .streaming(partial:)` for exactly the `GenerationID`s the store currently has in flight, and is the identity otherwise. The decomposition matters: **no fold ever yields `.streaming`** — a log cannot know the process is alive — and `.interrupted` is precisely what a live generation *looks like* to a pure fold. Liveness is store state, deliberately outside the reducer: I1 stays pure. On crash, the live set is vacuously empty at next launch, the overlay is the identity, and the fold's `.interrupted` shows through — recovery is the overlay *disappearing*, not a recovery pass running. On flush, the unflushed tail is exactly what would be lost, which is the already-documented recovery granularity. Make both cadences configurable; the two halves are tested separately in §10.

**Only `deltaAppended` coalesces (rev 4).** Every other event — `generationStarted` (and its transaction-mates, §6.5), terminals, edits, path changes, metadata — appends synchronously before the verb proceeds. The rule earns its keep at the start boundary: if `generationStarted` could sit in the unflushed tail, a crash before the first delta flush would erase the generation entirely — user message persisted, no `.interrupted` bubble, the turn silently vanished. That is a strictly worse artifact than the one G4 exists to fix, and it is now unrepresentable by rule rather than avoided by luck.

### 7.5 Cancellation

Two entry points, one semantics: `store.cancelGeneration(in:)` — the canonical path; the store is the authority on in-flight state and survives view teardown — or cancelling the `Task` awaiting `send` / `respond` / `regenerate` (sugar; structured-concurrency-friendly, but the handle dies with its owner). Either way: the driver winds down ⇒ the store flushes ⇒ appends `generationEnded(.cancelled)` ⇒ the suspended call returns `.cancelled`. (Pre-start Task-cancel is the one exception — it *throws*, §7.2: there is nothing to terminate.) A cancel racing a natural terminal is benign: first append wins, I3 quarantines the loser. Cancelled ≠ failed ≠ interrupted: three distinct UI treatments.

**A stop that lands in the start window is honoured, not dropped (rev 8).** §6.5's start atomicity opens an interval in which a generation is *claimed but not yet running* — the single-flight slot is taken, the start append has not returned. A cancel arriving there has no running work to stop, and treating it as "nothing live" would let a visibly-started generation run to completion after the user pressed stop, which is precisely the affordance the stop button exists to deny. The intent is therefore recorded and acted on the moment the generation begins. §11's "no-op if none live" remains true for its intended case: a conversation with nothing claimed at all.

**The append that records a cancellation must not run inside the cancelled task (rev 8, from M5).** This is a mechanism the spec assumed and never stated, and it is not obvious. A cancellation-aware persistence backend — GRDB is one — makes any write inside a cancelled task **throw instead of writing**. Perform the wind-down there and a stop erases its own evidence: no terminal, the generation left open, and the conversation reads `.interrupted` on reload — a different state, with a different UI treatment, for something the user explicitly did. Cancellation must therefore stop the **driver**, while the wind-down (final flush, then `generationEnded(.cancelled)`) runs outside the cancelled scope.

The same rule is what makes **partial-content retention** true rather than approximate. The store's consume loop must exit only when the driver's signal stream *ends* — and it ends because the driver was cancelled — so every signal the driver actually produced is drained and recorded before the terminal. A loop that exited on cancellation instead would silently drop whatever the driver had emitted but the store had not yet read, which is content the user was shown.

### 7.6 Tool calls

FM executes registered tools inside the session. The driver observes invocations — **the surface is confirmed (rev 7): `ResponseStream.Snapshot.transcriptEntries` vends transcript entries *mid-stream*, so `toolCalls` and `toolOutput` entries are visible as they land, not only at completion** — and records `toolInvocationRecorded` events. Record, don't orchestrate. **Recording policy** on the driver: `.metadataOnly` (default — name, status, duration), `.full` (adds `argumentsJSON`/`resultJSON`), `.off`. Full is opt-in because tool results routinely contain fetched sensitive data, and the ledger outlives the session (§9 privacy). **Shape consequence, stated:** the record is a single event emitted *after* the invocation completes (it carries duration and result) — live "using tool…" UI is therefore not representable from v0.1 ledger data; live tool activity, if surfaced at all, is a session-observation concern (OQ2), not a ledger one. If v0.2 splits this into started/ended kinds for live rendering, those are new payload kinds that v0.1 readers quarantine — the record vanishes rather than degrades on old readers. Priced in and accepted. Rehydration consequence: records are *audit*, not rebuild material, in v0.1 — §7.1's fidelity classes; reconstruction from `.full` records is the v0.2 item (§12).

**What OQ2's closure does and does not change (rev 7).** It changes the *feasibility* of two things and the *decision* about neither. (1) Live "using tool…" UI is now representable from session observation — `transcriptEntries` mid-stream is exactly the signal — which was the open half of the consequence stated above. The v0.1 stance is unchanged: it stays a **session** concern, not a ledger one, because the ledger event is still emitted after the invocation completes and still carries duration. (2) Rebuilding tool entries into a seeded transcript is now known-possible: `Transcript.ToolCalls` and `Transcript.ToolOutput` both have public initializers (`ToolOutput(id:toolName:segments:)`), so the v0.2 transcript-fidelity item (§12) is a scoping decision rather than an API bet. v0.1 still reconstructs neither (§7.1's fidelity classes, N11).

### 7.7 Usage

`Response.usage` (new in iOS 27) → captured in `StopInfo` on completion. Token counts span input and output including cached and reasoning tokens (**field names verified against the 27 SDK, rev 7 — the ⚠️ is closed**), and `ResponseStream.Snapshot` carries `usage` too, so a long generation's cost is observable mid-stream and not only at the end. Projected on `Message.stopInfo` (§6.2, rev 4): per-message token/cost display is table stakes for BYO-key apps, and recorded-but-unprojectable data is a bug, not privacy.

The mapping onto `TokenUsage` (§6.1) is 1:1 and total:

| Apple | `TokenUsage` |
|---|---|
| `Usage.Input.totalTokenCount` | `inputTokens` |
| `Usage.Input.cachedTokenCount` | `cachedInputTokens` |
| `Usage.Output.totalTokenCount` | `outputTokens` |
| `Usage.Output.reasoningTokenCount` | `reasoningTokens` |

**One asymmetry, deliberate:** Apple's four fields are non-optional `Int`; LedgerKit's are `Int?`. The ledger records what a provider *reported*, and a provider outside Apple's path may report nothing — nil means "not reported," which zero cannot say. **One M6 empirical residue:** whether `Input.totalTokenCount` is inclusive of `cachedTokenCount` is not stated by the interface, and it decides whether an app may sum the two. Record the answer here when M6 measures it; until then apps should display, not arithmetise.

**`stopReason` has no source in the framework (rev 8, from the M4 audit's interface read).** `Response` is `{content, rawContent, transcriptEntries, usage}`, and no stop-reason key exists anywhere in the 27 SDK — the only free-form reporting channels are the `metadata` dictionaries (on `Usage` and the executor channel's `Metadata`). `StopInfo.stopReason` therefore has exactly `resolvedModelID`'s standing (§7.8): a per-provider convention the driver may populate from metadata where a provider follows one, **nil expected on-device**, never an error. Recorded because rev 7's "field names verified" sentence read as covering it, and a claim of verification has to say what it verified.

### 7.8 Provider swap & model identity

The driver takes `any LanguageModel` at init. On-device ↔ Claude package ↔ Chat Completions server is the app's one-line choice; zero conditional code inside LedgerKit.

**Model identity is two facts captured at two times (rev 4, resolving most of OQ8):** the **requested** descriptor — provider/model/version as configured — rides `generationStarted`, and rev 7 closes OQ8's residual: it is **app-supplied at driver init, necessarily**. The `LanguageModel` protocol is two requirements wide — `capabilities` and `executorConfiguration` — and the configuration is an opaque associated type with no model-identity key anywhere in the framework. There is nothing to derive from, so asking the app is not a fallback; it is the only correct design. The **resolved** identity lands in `StopInfo` at completion where a provider reports one — but rev 7 downgrades that expectation honestly: **no standard metadata key exists**, so `resolvedModelID` is a per-provider convention, and **nil is the expected value on-device**. Branch-compare uses the request; audit gets both; a provider silently upgrading its backend is *visible* as request ≠ resolved instead of invisible — where the provider reports anything at all, and a nil must never read as a failure.

**Cardinality (rev 4, previously unstated; §7.9 names the type this constrains):** one driver may serve many conversations concurrently — §6.5's cross-conversation freedom is a driver property too, not just a store one. The driver is stateless per generation: it materializes or reuses a session **per conversation** (an internal cache keyed by `ConversationID` — the §7.1 KV-cache optimization), never one shared session across conversations, because Apple sessions are single-flight (§6.5, §7.2). Correctness never depends on the cache; discard-and-rebuild is always legal (ownership rule).

### 7.9 The driver seam (rev 8)

Everything above describes driver *obligations*; until M5 there was no driver *interface* for them to attach to, because the store that would call one did not exist. It does now, and the shape is contract rather than implementation detail — M6 writes the one production conformance, and anything else that ever runs inference for LedgerKit writes another.

**The store takes a small protocol, and neither of the two obvious alternatives.** Not a concrete driver: that type does not exist until M6 and would drag the one OS-coupled module into every store test, including onto machines with no Apple Intelligence eligibility. Not `any LanguageModel`: tenet 3 says the inference boundary is Apple's, and a durable-state engine has no business seeing a model. The seam is what lets §6's purity claim and §7's beta risk stay on opposite sides of one file.

Its shape:

- **The driver exposes its requested `ModelDescriptor`** (§7.8), which the store copies into `generationStarted` and never invents.
- **One call**, taking a **request** — rehydration material (§7.1): the active path as *reduction output*, plus current instructions — and a **channel** for non-terminal signals (text deltas, tool records), returning the one terminal `Outcome`.

**The call does not throw, and that is the contract rather than an omission.** The store appends `generationStarted` *before* it (§7.2), so by the time a driver runs the generation exists in the log and every failure after that point is an `Outcome` — including zero-token request-time failures. Cancellation likewise *returns* `.cancelled` rather than throwing, which makes §11's documented deviation structural instead of merely documented: a driver cannot split "how it ended" across two channels. Exactly one terminal becomes the type's grammar — two are unrepresentable, zero is a call that never returns.

**Which side owns what**, stated once so the rest of §7 can be read against it:

| Store | Driver |
|---|---|
| every append; flush cadence (§7.4) | rehydration into a session (§7.1) |
| the live set and single-flight (§6.5) | snapshot→delta diffing (§7.3) |
| identity and canonical timestamps (§6.1) | error normalization (§8) |
| the terminal, and that there is exactly one | the `isResponding` gate (§7.2) |
| the request's contents | tool-record observation (§7.6) |

The shape deliberately echoes Apple's own provider seam one layer down — `LanguageModelExecutor.respond(to:model:streamingInto:)` is request-plus-channel — with one divergence that is the whole point: Apple's returns `Void` and throws, because a provider's failures are the caller's problem; LedgerKit's returns the `Outcome`, because a driver's failures are *the ledger's content*.

---

## 8. Error taxonomy & recoverability

The contract that makes error handling a design feature instead of an afterthought. UI affordance is a function of `Recoverability`, never of raw error inspection.

**Anchor on Apple's enum, not per-provider empirics.** Apple steers providers toward the built-in `LanguageModelError` cases, reserving custom errors for service-specific failures. `GenerationError` is therefore defined as a *total normalization of Apple's built-in taxonomy* first, with `providerFailure`/`transport` as the custom-error tail and `unrecognized` as the floor.

**The inventory is no longer ⚠️ (rev 6).** OQ5 asked for the built-in case list "including exact case *names*." It has been read directly from the installed macOS 27 SDK's `FoundationModels.swiftinterface` rather than inferred from documentation, and rev 6 reconciles this section against it. Three things were wrong: one name did not match, one case had no home, and four cases fell through to `unrecognized` — which made the word *total* above false.

```swift
public enum GenerationError: Error, Sendable, Codable {
    case modelUnavailable(ModelUnavailability)   // deviceNotEligible, appleIntelligenceNotEnabled,
                                                 // modelNotReady — mirrors
                                                 // SystemLanguageModel.Availability.UnavailableReason
                                                 // exactly. Note (rev 6) this is an *availability*
                                                 // API, not a LanguageModelError case — see below.
    case contextSizeExceeded(contextSize: Int?, tokenCount: Int?)
                                                 // rev 6: renamed from contextWindowExceeded, which
                                                 // matched no Apple name.
                                                 // rev 7 (M4): gains Apple's two payload fields.
                                                 // Optional where Apple's are not — a non-Apple
                                                 // provider may report neither, and nil says
                                                 // "not reported" where 0 cannot.
    case guardrailViolation
    case refusal                                 // rev 6: the model declined to answer. Apple keeps
                                                 // this distinct from a guardrail intervening, and
                                                 // so does this taxonomy.
    case unsupported(UnsupportedFeature)         // rev 6: the four `unsupported*` built-ins, grouped
    case rateLimited(retryAfter: Duration?)
    case providerFailure(status: Int?, code: String?, message: String?)
        // status:  HTTP status, when the failure crossed an HTTP boundary; else nil
        // code:    provider's stable machine-readable error identifier; else nil
        // message: human-readable detail — never used for classification
    case transport(TransportFailure)             // timeout, connectivity, TLS — the "network, not model" bucket
    case unrecognized(description: String)       // loud, never silently swallowed
}

public enum UnsupportedFeature: Sendable, Codable {
    case capability          // tools / guided generation / reasoning this model lacks
    case transcriptContent   // an entry kind or segment the model cannot consume
    case generationGuide     // a schema the model cannot satisfy
    case languageOrLocale    // the prompt's language is out of scope for this model
}
```

**Coverage of the built-in taxonomy, stated so "total" is checkable (rev 6):**

| `LanguageModelError` case | `GenerationError` | Note |
|---|---|---|
| `contextSizeExceeded(ContextSizeExceeded)` | `contextSizeExceeded(contextSize:tokenCount:)` | 1:1, payload included (rev 7) |
| `rateLimited` | `rateLimited(retryAfter:)` | 1:1 |
| `guardrailViolation` | `guardrailViolation` | 1:1 |
| `refusal` | `refusal` | 1:1 |
| `unsupportedCapability` | `unsupported(.capability)` | grouped |
| `unsupportedTranscriptContent` | `unsupported(.transcriptContent)` | grouped |
| `unsupportedGenerationGuide` | `unsupported(.generationGuide)` | grouped |
| `unsupportedLanguageOrLocale` | `unsupported(.languageOrLocale)` | grouped |
| `timeout` | `transport(.timeout)` | **the one deliberate non-1:1** — lift rule 2 below |

**Why `contextSizeExceeded` carries a payload and the other cases do not (rev 7).** Apple's `ContextSizeExceeded` carries `contextSize` and `tokenCount`, and this is the one built-in where the numbers change what the app can *do*: N3 makes window overflow a headline on-device failure, and `recoverableUpstream(.reduceContext)` is a far better affordance when the app can say how far over it was. The fields are **optional** because the ledger records what was reported, and non-Apple providers report neither. **Classification ignores the payload** — §8 maps the case, and a number cannot change what the user can do about it — exactly as `rateLimited`'s slot reads its own duration for display and nothing else.

**This was additive on the wire, which is the only reason it happened after ratification.** The `contextSizeExceeded` discriminator is unchanged; nil fields encode as absent keys (ADR-001 R-4), so this build writes byte-identical bytes to the pre-widening build for a payload-less value; and keyed containers skip unknown keys, so a rev-6 reader ignores fields a rev-7 writer adds. The two new field keys join ADR-001 R-2's permanent registry. `wire/contextSizeExceededLegacy` pins all three shapes from bytes — pre-widening, post-widening, and a *future* version's extra field — so the claim is a test rather than an argument. **Not free in Swift, though, and worth recording for the next one:** enum cases cannot have default parameter values, so widening a case is source-breaking at every construction site even when it is wire-additive.

**Why the four `unsupported*` cases are grouped rather than lifted to top-level cases.** Every one of them classifies `terminal`, and three of the four are *configuration* errors — the app asked this model for something it does not do — rather than conditions a user can act on. Four top-level cases would buy four identical table rows, four mapping slots nobody overrides differently, and four more cases in the enum every consumer switches over, in exchange for information the nested value already carries losslessly. Grouping keeps §8's table and `MessageState`'s exhaustive switch (§11, the showpiece) proportional to the *affordances* that exist, which is what this taxonomy is for.

**Why `refusal` is not grouped with `guardrailViolation`.** They classify identically today, which is exactly the argument that tempted rev 6 to merge them. They stay apart because Apple keeps them apart and rule 1 below is a 1:1 promise — and because the distinction is real and may yet earn different affordances: a guardrail is a system intervening on content, a refusal is the model itself declining. Collapsing them would discard that, permanently, to save one enum case.

**Neither carries Apple's `debugDescription`.** `LanguageModelError.Refusal` and its siblings carry a `debugDescription` and a `metadata` dictionary. Neither is projected: the field's own name says debug, §8's standing rule is that human-readable detail never participates in classification, and `guardrailViolation` has set this precedent since rev 1. The driver logs it at normalization time (§7.2). If a future revision wants refusal text on screen it is an additive change to *that* case — but it is a wire change, so it happens deliberately or not at all.

**And `Refusal.explanation` is not stored data at all (rev 7)** — it is an *on-demand generation*, an `async throws` `Response<String>` property (with a streaming sibling), meaning reading it asks the model to explain itself and costs tokens. Rev 6 decided not to project refusal text on the grounds that debug detail must not classify; the 27 interface makes that decision look better than it was argued: projecting it would have meant either persisting the output of a second inference call into an append-only ledger, or storing a promise that cannot be honoured after the session is gone. The ledger records that the model refused. An app wanting the explanation asks the model, live, while it still can.

**`modelUnavailable` does not come from `LanguageModelError` at all (rev 6).** It normalizes `SystemLanguageModel.Availability.UnavailableReason` — `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` — which is an availability API the app queries *before* generating. The names match exactly, as rev 4 promised. `PrivateCloudComputeLanguageModel` has its own smaller reason set (`deviceNotEligible`, `systemNotReady`); `systemNotReady` normalizes to `.modelNotReady`. Recorded because §8 claims totality over Apple's taxonomy, and a reader checking that claim against `LanguageModelError` alone would find this case unaccounted for and conclude the claim was sloppy.

```swift
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
2. **Lift rules** — cases that must never fall through to the generic status classes: HTTP 429 → `.rateLimited(retryAfter:)`, parsing `Retry-After` in both RFC 9110 forms (delta-seconds and HTTP-date), **and — rev 7 — in Apple's own third form: `LanguageModelError.RateLimited` carries `resetDate: Date?`, an instant rather than a duration.** All three normalize to a duration *at normalization time*, so the persisted value stays clock-independent and display math remains `Message.terminalTimestamp + retryAfter` (§6.2, rev 4). Converting a date to a duration requires reading a clock, which is legal in the driver and forbidden in the reducer (I1) — the conversion happening at normalization is what keeps that line clean. Note the small honest loss: `resetDate - now` is only as good as the clock skew between device and provider, which is precisely why the *persisted* value is a duration and the instant is recomputed from the terminal's own timestamp. HTTP 408 and all timeout / connectivity / TLS failures → `.transport(…)`.
3. Remaining failures that crossed an HTTP boundary → `providerFailure(status:code:message:)`.
4. Non-HTTP provider-custom errors → `providerFailure(status: nil, code: <identifier>, message:)`.
5. Anything else → `.unrecognized` (loud).

**One exclusion, now with a name (rev 4, sharpened rev 7):** a busy-*session* condition is a driver defect, not a provider signal. At 27 it is the typed `LanguageModelSession.Error.concurrentRequests`; at 26 it was `LanguageModelSession.GenerationError.concurrentRequests`, in the same enum as `rateLimited`, which is how it came to be mistaken for one. **Normalization must map neither to `.rateLimited`.** §7.2's `isResponding` gate keeps both out of normalization entirely; if one ever reaches it, it lands as `unrecognized("driver: session busy")`, never as `retryable`. The same applies to `.transcriptMutationWhileResponding`, its sibling: mutating a transcript mid-response is a LedgerKit bug by construction, since the driver owns the session for the generation's duration.

**Two error families, not one (rev 7).** `LanguageModelSession.GenerationError` is deprecated case-by-case at 27, each case naming its `LanguageModelError` (or `LanguageModelSession.Error`) replacement — but deprecated is not absent, and a provider package built against 26 can still throw it. Per-provider normalization must therefore recognize **both** families and land them on the same `GenerationError`. Fixture-tested per §10.5; the deprecated family is exactly the kind of tail this taxonomy's `unrecognized` floor exists to make loud rather than silent.

Convention: `unrecognized` descriptions originating from LedgerKit's own driver invariants carry a stable `"driver:"` prefix (e.g. the §7.3 prefix-violation path, the §7.2 session gate), so mapping overrides and log triage can distinguish driver defects from provider mysteries.

**Provenance rule:** `GenerationError` is persisted (inside `Outcome.failed`); `Recoverability` is **derived at classification time** by the mapping and stored nowhere — not in events, not in snapshots (snapshots store `FoldedState` — the error, never the classification — and recompute on load, §6.3/§9). This is what keeps I1 honest ("same log ⇒ same folded state; folded state + mapping ⇒ same classified state"), and it means fixing a mapping gap *retroactively upgrades* the affordances on historical failed messages the next time they're reduced. Classification bugs heal; frozen classifications don't.

Default classification mapping (ships in LedgerKit; apps override per-case; overrides apply on next reduction):

| Error | Recoverability |
|---|---|
| `modelUnavailable(.deviceNotEligible)` | `terminal` |
| `modelUnavailable(.appleIntelligenceNotEnabled)` | `recoverableUpstream(.enableAppleIntelligence)` |
| `modelUnavailable(.modelNotReady)` | `recoverableUpstream(.awaitModelDownload)` |
| `contextSizeExceeded` | `recoverableUpstream(.reduceContext)` |
| `guardrailViolation` | `terminal` |
| `refusal` | `terminal` |
| `unsupported(*)` | `terminal` (and logged loudly) — three of the four are configuration errors, so the developer is the audience |
| `rateLimited(after)` | `retryable(after)` |
| `transport(*)` | `retryable(nil)` |
| `providerFailure`, status 5xx | `retryable(nil)` |
| `providerFailure`, status 401 / 403 / 407 | `recoverableUpstream(.reauthenticate)` |
| `providerFailure`, status 429 | `retryable(nil)` — defensive; normalization should have lifted it (log loudly) |
| `providerFailure`, other 4xx status | `terminal` |
| `providerFailure`, status outside 4xx/5xx | `terminal` (and logged loudly) — a status a provider failure cannot meaningfully carry is malformed, not informative |
| `providerFailure`, status nil, code non-nil | per-provider override table; unmatched → `terminal` (loud) |
| `providerFailure`, status nil, code nil | `terminal` (and logged loudly) |
| `unrecognized` | `terminal` (and logged loudly) |

Nil rationale: an unclassifiable provider failure retried blind risks retry loops on permanent faults; `terminal` still leaves Regenerate as the manual retry, which is the safer default. If a provider family turns out to emit nil-status transients, that's a mapping override keyed on `code` — and a fixture (§10).

**"Logged loudly" has no home in `classify` (rev 5).** Several rows above carry that annotation — `unsupported(*)` joined them in rev 6, and it belongs firmly in the normalization-time group below, since a model being asked for a capability it lacks is a fact about the *app's configuration* that the driver is the first and best place to shout about. The classification layer is a pure function that cannot log (§6.3). The annotation is therefore a claim about *where the loudness belongs*, not a requirement on the mapping. Three of the four — `unrecognized`, nil-status/nil-code `providerFailure`, and a 429 that reached classification unlifted — are detectable at **normalization** time in the driver (§7.2, M6), which is both where those values are minted and where a logger exists. The fourth, an unmatched provider `code`, is visible only to classification, and only in an app that supplied a `providerCodes` table in the first place — so it is that app's to notice, against a table it wrote. Deliberately **not** solved by adding provenance to classification's return type: that would complicate the one signature every consumer calls, permanently and source-breakingly, to report a condition the caller can already detect from its own input.

Normalization risk, revised: anchoring on the built-in enum shrinks the empirical surface to each provider's custom tail. Still isolate the mapping in one file per provider family, fixture-test it (§10), and expect it to churn. This is where real-world adoption feedback accrues; treat mapping-gap issues as gold.

---

## 9. Persistence

- **Store:** single SQLite database. **Three tables:**
  - `events` — append-only, keyed `(conversation_id, sequence)` UNIQUE. The truth. **`payload` is TEXT holding UTF-8 JSON (rev 7, from M4's implementation).** Earlier revisions called it a blob, which described its *opacity* to the database and was read as a storage class; the distinction is worth fixing, because a log that `sqlite3 ledger.db "SELECT payload FROM events"` prints readably is worth real money in a project whose fixtures are documentation, and it puts SQLite's `json1` functions within reach for triage. The database still never *interprets* it — that is the property that matters, and TEXT honours it identically. Snapshot payloads stay binary: a disposable cache of a fold that nobody reads by eye. **The schema version lives in a column, never in the blob** — it is loader routing metadata, exactly like `sequence`, and log transport moves rows rather than bare blobs (ADR-001 D-2). The `sequence` column is the **only** physical home of sequence (rev 4): the encoded blob omits it and the in-memory envelope is populated from the column at load — a blob/column disagreement is unrepresentable, by construction rather than by check. `conversationID` is deliberately in both places; the duplication is what §6.6 row 4 verifies.
  - `snapshots` — periodic **`FoldedState`** checkpoints (§6.3) so cold-open of a 10k-event conversation doesn't replay from genesis. Each row carries **reducer version + payload schema version**, both outside the payload so the decision costs no decode; discarded on mismatch, no migration ever. **The discard condition is four-way (rev 7):** either version disagrees, the payload does not decode, the payload names a *different conversation* than its key — the snapshot analogue of §6.6 row 4, and corrupt by the same argument — or the checkpoint claims a sequence before genesis, which would seed a non-empty state and then replay the whole log over it, doubling every delta. All four take the same branch and none is ever fatal: the worst a bad checkpoint may cost is the replay it was avoiding. Snapshots store raw `GenerationError`s, never `Recoverability` (recomputed on load, §8) — mapping-agnostic by construction — **and the diagnostics accumulated so far (rev 4)**: quarantine residue is observable state, so a snapshot that dropped it would make reduced state depend on snapshot timing. P3 (§10) exists to catch exactly that class of bug. **Refresh policy (default):** best-effort async refresh after each `generationEnded` append — the natural quiescent point, and generations dominate event volume, so cold-open replays at most one generation's suffix — with a floor of every 500 events for pathological logs; both configurable. Snapshots are disposable (truth is the log), so best-effort is safe: a missed refresh costs replay time, never correctness. **"Best-effort" governs *failure*, not *detachment* (rev 8):** a refresh that cannot be written is shrugged off, but one allowed to run detached could land *after* a `deleteConversation` had erased the conversation, resurrecting a snapshot row for a log that no longer exists — the same race this section already closes for terminals, arriving through the other door. The refresh therefore sequences within the verb that triggered it, which costs one small write at a point that verb is already finishing. A snapshot landing mid-generation stores the open generation *open* — `.interrupted` is finalization-time (I5), so intermediate folds carry no false classification.
  - `conversations` — the cross-conversation **index projection**: id, created_at, title, last_event_at. Maintained transactionally on **non-delta appends** (rev 4) — delta flushes deliberately don't touch it: a streaming generation would otherwise churn the table and every value-observer at flush cadence (~4 Hz) for zero information, and the live-activity signal belongs to the projection's overlay (§7.4), not the index. `last_event_at` therefore reads "last meaningful event," which is what a list sorts by anyway. Rebuildable by scanning the log. In event-sourcing terms this is a read model: same class as snapshots — derived, deletable at any time, truth is the log. It exists so the conversation list is a table read, not N reductions (G9).
- **Backend: GRDB** (ADR-003, Accepted at M4) — migrations and value observation, the latter of which the M7 projection wants. **The decision is deliberately reversible and the reversal is priced:** persistence sits behind a six-verb internal protocol, GRDB appears in exactly one file and never in a signature, a thrown type, or a re-export, so raw sqlite3 remains the §12 cut line at a cost measured in days. SwiftData is the wrong shape for an append-only log with custom reduction; don't fight it.
- **Atomicity:** an event append is the transactional unit; multi-event operations (send = `userMessageAppended` + `generationStarted`, rev 4; edit = `messageEdited` + `activePathChanged`; respond/regenerate = `generationStarted` + `activePathChanged` when off-endpoint, §6.4) commit in **one** transaction, so no crash can strand half an operation. A crash between transactions is by construction a valid log (I2/I5 handle the rest). Note the limit of this guarantee: operation boundaries exist only as DB transactions — the log itself doesn't record them. Promoting an operation/correlation ID onto the envelope is deferred to the v0.3 sync design doc (§6.1, §12); noted here so it reads as a decision, not an omission.
- **Log versioning:** every event row carries a schema version. v0.1 policy: reducer reads all past versions, writes current. **Forward compatibility:** payload kinds written by a *newer* LedgerKit decode to quarantine (§6.6) — the conversation loads, degraded, never fails — with the single tolerant-terminal exception (§6.1). Codable evolution of `Payload` is the sharpest long-term maintenance edge in the whole design — encoding is tagged JSON (ratified, was OQ1); ADR-001 formalizes it: the discriminator registry (tags are never reused; removed tags stay reserved), the unknown-discriminator → quarantine rule, the tolerant-terminal exception, the gap-diagnostic rule (§6.1), and the version-frozen fixture corpus (§10).
- **Log growth:** delta rows dominate — at the default flush cadence a 60 s generation is ~240 rows. Storage cost is trivial (text), but state the stance: **no delta consolidation in v0.1.** Collapsing a completed generation's deltas into one row is a history rewrite, in direct tension with tenet 2; if it ever happens it is a deliberate archival design (v0.3+ at the earliest), not a cleanup task. Snapshots address read cost, not size.
- **Deletion & erasure:** conversation-level delete = transactional `DELETE` of that conversation's events, snapshots, and index row, via `store.deleteConversation(_:)`. **It cancels any in-flight generation first (rev 4):** the cancel runs to its terminal through the normal path (§7.5 — the suspended verb returns `.cancelled`, not a persistence error), then the `DELETE` commits; both steps sequence through the store actor, so the terminal-append-vs-DELETE race cannot occur. It is out-of-band — not an event — because there is no log left to append to; document that it is irreversible. **Sync consequence, priced in now:** these DELETE semantics are local-only. Log-shipping sync (v0.3 design doc, §12) must introduce deletion tombstones or an equivalent, or a deleted conversation resurrects from any peer still holding its log — the classic resurrection problem. Inbox item for the sync doc, not a v0.1 concern. Message-level redaction is out of scope (N9). The honest note for the README: append-only and erasure are structurally opposed; the known idioms are **crypto-shredding** (encrypt payloads under per-conversation or per-message keys; deleting the key is the erasure) versus an explicit, versioned log rewrite. Choosing one is the v0.2 erasure design doc (§12).
- **Privacy:** conversations are user content. File protection `.completeUntilFirstUserAuthentication` minimum; document that apps handling sensitive domains should layer their own encryption. Tool recording defaults to `.metadataOnly` (§7.6) because recorded tool results outlive the session. No LedgerKit telemetry, ever.

---
## 10. Testing strategy

The test story *is* the differentiation — "how do you even test an FM app?" currently has no good public answer.

1. **`ScriptedLanguageModel`** — conforms to Apple's `LanguageModel` protocol (model + executor pair — **surface verified at M3, OQ3 closed; see §14**). Plays a script: emit snapshot, wait, throw, complete. Powers unit tests, SwiftUI previews, demo screenshots, and CI on Intel Macs with zero Apple Intelligence eligibility. Because the protocol is Apple's, this double is useful to *any* FM app, not just LedgerKit consumers — ship it as a separate product and let it be the gateway drug. **The product is named `Understudy` (rev 7; decided at the M4 boundary, 2026-07-26).** The provisional name undercut the positioning it existed to serve — nobody installs a package called *LedgerKitTestSupport* to get a deterministic Foundation Models double — and it advertised a dependency the product deliberately does not have (it must not depend on LedgerKit, or LedgerKit's own test target could never import it). `Understudy` keeps the theatrical vocabulary the API already speaks (`Script`, `Step`, `Cue`), reads as unmistakably third-party in a namespace Apple grew four `LanguageModel*` types into this cycle, and leaves discoverability to the package description, which is its job. Directory, package, product and module are all one name; historical documents keep the old one as a matter of record.
2. **Golden logs:** fixture event logs → expected reduced state, snapshot-tested. Doubles as living documentation of semantics. Hostile fixtures mirror the §6.6 table row-for-row: second genesis, second bare nil-parent append, delta-after-end, tool-record-after-end, assistant-message edit, replacement-ID collision, `activePathChanged` to a never-existent endpoint, envelope `conversationID` mismatch, unknown payload kind — each asserting the exact `diagnostics` residue. Plus the tolerant-terminal fixture asserting the *opposite*: an unknown nested outcome lands as `failed(.unrecognized)` and does **not** quarantine (§6.1). Rev 4 additions, mirroring the §6.6 non-rules: a **mid-log gap** fixture (one diagnostic per contiguous gap; a gap swallowing a terminal yields `.interrupted`), the **cascade** fixture (a quarantined `generationStarted` orphans its deltas, tool records, and terminal into rows 9–10 residue — exact diagnostics asserted), and **role-adjacency non-rule** fixtures (assistant-parent `generationStarted` and consecutive user siblings reduce *without* quarantine — wire headroom proven, not assumed). Root-message edit graduates from impossible (rev 2) to a golden fixture. **Version-frozen corpus:** fixture logs written by each released version are frozen in CI forever — the standard evolution safety net; if per-version decode ever gets hairy, the idiom to reach for is *upcasters* (decode-time old-shape → current-shape transforms) so the reducer stays single-shape (ADR-001). **The discriminator registry is enforced by a checked-in manifest (rev 7; ADR-001 D-3, closed at M4).** `Registry/tags.json` lists every tag at every level, every field key, and the reserved table; a test compares it against what the codecs actually encode, in both directions, so a rename or an unregistered addition fails CI. Reuse of a retired tag is caught twice — once against the reserved table, once by requiring that decoding it still throws. Deletion is caught by neither, and is caught anyway: the test reads the same exhaustive case inventories the round-trip tests use, so removing a case fails to *compile*. Three mechanisms, because no one of them sees all three failures.
3. **Crash-point fuzzing:** for every fixture log, truncate at *every* prefix and assert the reducer yields a valid state with correct `.interrupted` synthesis (I5) and no traps (I2). Rev 4 adds the **interior-gap variant**: knock out interior slices, not just suffixes, and assert I2's gap diagnostics alongside I5's synthesis. Cheap, brutal, and the single highest-value suite in the package.
4. **Cancellation chaos:** drive scripted streams and cancel at **enumerated, parked points — not randomized ones (rev 8)**. This is the concurrency sibling of the exhaustive-not-randomized rule below, and the mechanism differs in a way worth naming: the pure sweeps enumerate *splits of a log*, while this enumerates *moments in a running generation*, which only exist if something holds the generation still. A test that merely *released* a running stream would still have to guess when it got there — which is a sleep, which is a flake. **Parking removes the guess:** the driver stops at a point the script named, the test observes that it has arrived, and whatever the test does next provably happens there. The enumerable points are the script's step boundaries plus §7.2's straddle in all three of its positions — pre-append (throws `CancellationError`), post-append (returns `.cancelled`), and the start window of §7.5 — crossed with both stop mechanisms (`store.cancelGeneration(in:)` and Task-cancellation). Scripts are small, so this is exhaustive rather than sampled. **One case is genuinely racy and stays so:** cancel versus a natural terminal, which is asserted by *outcome invariant* — exactly one terminal (I3), and the returned outcome is the recorded one — rather than by controlling timing that cannot be controlled. Assert partial-content retention at every point (§7.5).
5. **Error-mapping fixtures:** canned provider failures → asserted `GenerationError` + `Recoverability`, per provider family, covering both layers: normalization (the §8 lift rules — 429 → `rateLimited` with both `Retry-After` forms, 408/timeout → `transport`, and the busy-session exclusion: a session-busy error lands as `unrecognized("driver: session busy")`, never `rateLimited`) and classification (the status-class rows, the reauthenticate rows, the nil-status floors).
6. **Projection & snapshot equivalence, in three parts (the §7.4 and §9 contracts made executable):** **P1 (fold/tail equivalence — a *store* property, rev 7):** `reduce(persisted ++ unflushedTail, mapping) == reduce(logAfterFlush, mapping)`, over **every** flush boundary of every fixture. Rev 4 called this pure; implementing it at M4 showed it is not, and the correction matters. Its actual question is whether the values `append` *returned* are interchangeable with the bytes a re-read decodes — and in memory those are the same array, so a pure test cannot ask it. What it catches are the store's failure modes: a sequence assigned wrongly in a second transaction, a timestamp that does not survive its own encoding (ADR-001 R-5), an encoder asymmetric in one direction. Each leaves the store actor's in-memory state quietly disagreeing with its own database, which is the worst available shape because both halves look right alone. Asserted at the fold *and* classified levels, since a flush landing mid-generation must not finalize differently from a full replay (I5). **P2 (overlay correctness):** for every live `GenerationID`, the projection shows `.streaming` with partial equal to the concatenated deltas; for everything else the projection equals the fold; and the live set is always a subset of open (started, un-terminated) generations. Crash recovery is P2's degenerate case: empty live set ⇒ overlay is identity ⇒ `.interrupted` shows through. **P3 (snapshot equivalence, rev 4):** `resume(snapshot(prefix), suffix) == fold(fullLog)` — **including `diagnostics`** — property-tested over **every** snapshot point of every fixture, twice: through the codec (all fixtures, which is the sweep that reaches logs carrying diagnostics) and through real SQLite (those the write path can express). The snapshot fast-path is a second reduction path; rev 3 shipped it untested, which was exactly the kind of hole this spec exists to not have. P3 is also what *forces* snapshots to persist diagnostics (§9): drop them and P3 fails on any log with quarantine residue before the snapshot point.

**Exhaustive, not randomized (rev 7).** Rev 4 specified randomized points for P1 and P3, and the implementation deliberately does better: fixture logs are ≤ 22 rows, so every split of every fixture runs in milliseconds, and exhaustive beats random on all three axes that matter — no seed to manage, no flake, and a failure that reproduces by re-running rather than by recovering a seed from CI logs. The same rule already governs crash-point fuzzing (§10.3). Generators may only *remove or split*; never reorder, never duplicate, because ordering is a reduction precondition (§6.6).

**P2's harness exists before its overlay (rev 7).** The overlay is M7's, but P2's predicates are written and under test now, parameterized over the overlay function — because the empty-live-set case needs no overlay and is not a placeholder: it is the state every cold open lands in. That makes "crash recovery is P2's degenerate case" executable at M4, swept over every truncation of every fixture, with the predicates themselves tested against deliberately wrong projections so the sweep cannot pass vacuously. M7 supplies the real overlay as an argument and changes no assertion.
7. **Device integration (manual/CI-optional):** real on-device model behind an env flag; availability matrix spot checks.

---

## 11. Public API sketch (consumer's view)

```swift
let store = try ConversationStore(persistence: .sqlite(at: dbURL))    // actor

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

// send/respond/regenerate THROW when the generation could not be RECORDED.
// Usually that means it never started (§7.2): unknown conversation,
// unknown/ineligible target (respond: user messages; regenerate: assistant
// messages — §6.5), generationInFlight, persistence failure. Once
// generationStarted is in the log, generation failures are outcomes, not
// exceptions — including zero-token request-time failures (auth, instant
// guardrail) — they land in the ledger and render via observation. One
// channel for "couldn't record", one channel for "recorded a failure".
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

**`LedgerError`, the throw channel's inventory (rev 8; was a forward reference).** A public `enum`, not a struct with factories: consumers *switch over* errors, which is what a typed error is for, and an error you cannot match exhaustively is a `String` with extra steps. Six cases:

| Case | Condition |
|---|---|
| `unknownConversation(ConversationID)` | never created, or deleted |
| `unknownMessage(MessageID)` | the tree lacks it — `respond`, `regenerate`, `edit`, `switchBranch` |
| `ineligibleTarget(message:expected:found:)` | right ID, wrong role (§6.5); carries both roles, because the actionable question is "then what should I have passed?" |
| `unsupportedTarget(message:)` | structurally valid, but v0.1 cannot express the operation — see below |
| `generationInFlight(ConversationID)` | §6.5's single-flight |
| `persistenceFailure(description:)` | the backend failed; nothing was recorded |

`persistenceFailure` carries **prose, deliberately**: the backend's type never escapes (ADR-003), and what a caller can *do* about a storage failure does not vary by which storage failed. Prose on any of these is non-contractual (ADR-001) — assert on cases and their payloads, never on wording. `CancellationError` also crosses this channel and is deliberately *not* a case here: §7.2 gives it its own meaning, and borrowing Swift's own type says "this is the ordinary cancellation you already know", where a bespoke case would imply LedgerKit had an opinion about a condition it merely observes.

**`unsupportedTarget` is N10 seen from the reading side.** Exactly one condition reaches it in v0.1: `regenerate` of a **root-level** assistant message. Regenerating is `respond(to:)` on the target's parent, and a root-level node's parent is the virtual root — so the store would have to emit `generationStarted(parent: nil)`, which N10 reserves as wire headroom the v0.1 store never writes. The reducer accepts such an event (I6); the store declines to author one. Log tolerant, store enforcing: the §6.5 pattern exactly, arriving for once as a *refusal* rather than as a permission. It is reachable only from a log this version did not write — which is the forward-compatibility direction the whole design cares about — and relaxing N10 in v0.2 makes the case unreachable rather than wrong.

**The throw channel covers "couldn't record", not only "never started" (rev 8).** A persistence failure while flushing deltas or recording the terminal happens *after* the start append, so the older phrasing excluded it while this section's own principle includes it. The store throws, and deliberately writes **no** terminal: the generation stays open and reduces to `.interrupted`, which says *something went wrong*, where a `.completed` terminal missing a flush would claim success. "Only when the generation never started" was a description of when this happens in practice, written before anything implemented the terminal append.

**A deliberate deviation, documented:** Swift convention is that cancelled async work throws `CancellationError`. `send` (and `respond`/`regenerate`) instead *return* `.cancelled`, because cancellation here is a first-class ledger terminal — the recording operation itself *succeeded*. Throwing would split one semantic ("generation reached a terminal") across two channels. The boundary is §7.2's (rev 4): Task-cancel *before* `generationStarted` lands throws `CancellationError` — nothing started, convention holds; *after*, the call returns `.cancelled`. The rule of thumb for consumers: `try` guards "did it start"; the return value and the observed state answer "how did it end".

**Isolation sketch (tenet 6):** `ConversationStore` is an actor and owns all writes. The observable projection is a `@MainActor @Observable` class fed by the store; deltas hop to the main actor coalesced at *display* cadence (~a frame), independent of the *disk* flush cadence (§7.4). The reducer is pure, `nonisolated` functions over `Sendable` values — no isolation, no clocks, no I/O. The liveness overlay (§7.4) is applied on the projection side — the reducer never learns what "live" means.

The pitch in one exhaustive `switch`: the compiler forces the app to handle interruption and recoverability. That switch statement is your code-aesthetics blog post made executable.

---

## 12. Phasing & effort (evenings/weekends, honest)

- **v0.1 — target: tagged before iOS 27 GA (~Sept).** §6–§11 complete; demo app; README with the kill-mid-stream GIF. Estimate: **4–6 weeks part-time**, which assumes the ⚠️ verifications hold across betas — expect to repeat the API-verification evening per beta through August; price that in. Cut line if slipping, in order: (1) branch-switcher UX in demo (keep the events, hide the UI), (2) GRDB polish → naive SQLite, (3) tool-invocation recording → v0.2, (4) provider-mapping breadth — ship on-device + Claude-package mappings only; Chat-Completions family → v0.2. Never cut: I1–I7 **and P1–P3** tests, interruption recovery, ScriptedLanguageModel.
- **v0.2:** tool records → replay view (and, if OQ2 makes live tool activity observable, the started/ended event-pair design — see §7.6's priced-in quarantine consequence); **transcript-fidelity rehydration** (reconstruct tool-call/tool-output entries from `.full` records into rebuilt transcripts; record reasoning/custom segments if OQ9 exposes them — closes the §7.1 fidelity gap for apps that opt in); guided-generation partials (extends `MessageContent`); export (Markdown/JSON — now self-describing per-event thanks to the envelope `conversationID`); `RecordingLanguageModel` (capture real streams as fixtures); **continuation-resume research** (relaxes I7 to N:1 — the honest version of "Resume"); **parallel sibling generation** (relax single-flight per §6.5, multi-model branch-compare UX; the §7.2 session gate and §7.8 cardinality rules are its groundwork); **erasure design doc** (crypto-shredding vs. log rewrite, §9).
- **v0.3:** compaction bookkeeping integrated with utilities' summarizer — `compactionRecorded` **carries the summary text**, so both rehydration and the audit trail reproduce what the model actually saw, not merely that something happened; search; **sync design doc only** (log-shipping / CRDT exploration — the distributed-systems bridge, deliberately paper-first; inbox from v0.1: deletion tombstones (§9), envelope operation/correlation IDs (§6.1/§9)).

## 13. Definition of done (v0.1)

1. Demo: kill the app mid-stream → relaunch → the message renders `.interrupted` with partial text; **Regenerate works, and the interrupted partial survives as its own branch, reachable via the branch switcher.** Recorded as a GIF; this is the README hero and the launch post.
2. Swap `SystemLanguageModel` → Claude provider package: **the demo compiles and runs with only the driver-init line changed.**
3. Crash-point fuzz suite (suffix **and interior-gap** variants), cancellation chaos suite (including the §7.2 boundary cases), hostile-fixture quarantine assertions (the §6.6 table, row-for-row, including the tolerant-terminal *non*-quarantine, the role-adjacency non-rules, and the cascade fixture), and **P1–P3** green in CI (Scripted model — no device dependency).
4. README: 60-second quickstart, the recoverability table, the exhaustive-switch example, and the **"why not just persist `session.transcript`?" section** — the incumbent is the SwiftData transcript blob (§2), and the README answers it before the reader asks.
5. Tagged `0.1.0`; pre-1.0 SemVer caveats stated; ADR-001 committed **and its registry mechanically enforced, not merely documented** (tagged-JSON event encoding; discriminator registry — tags never reused, removed tags reserved forever, checked against a manifest in CI; unknown-discriminator → quarantine with the single tolerant-terminal exception; the gap-diagnostic rule; version-frozen fixture corpus; upcasters named as the evolution idiom).

## 14. Open questions

Resolved items from rev 1 have been folded into the spec body (rev 2's Appendix B has that map).

**Seven of the nine closed by reading, not by running (rev 6 and rev 7).** The SDK was on the build machine the whole time; the questions that survived a careful read are exactly the ones about *behaviour* rather than *shape*. What remains is genuinely empirical and belongs to M6, when `Session/` first runs against a device:

- **OQ6 residue:** is `concurrentRequests` thrown or trapped?
- **OQ4 residue:** do real providers revise segments in practice, and does segment-aware diffing beat prefix-diffing on them?
- **§7.7 residue:** is `Usage.Input.totalTokenCount` inclusive of `cachedTokenCount`?
- **N3's ⚠️:** the actual on-device context budget (~4k shared tokens, reported, unverified).

Re-verify the closed ones per beta; a *new* built-in error case, or a change to the `LanguageModel` protocol's two requirements, is the kind of change that reopens one.

1. ~~**Transcript seeding:** initializer shape for materializing a transcript into a `LanguageModelSession` in iOS 27.~~ **Resolved at M4 (rev 7)**, from the SDK: `LanguageModelSession(model: some LanguageModel, tools: [any Tool] = [], transcript: Transcript)`, generic over the model, plus a `SystemLanguageModel`-defaulted convenience. `Transcript` is `Codable` + `RangeReplaceableCollection`. No residue.
2. ~~**Tool-activity observation:** what iOS 27 exposes for observing tool invocations on the response/stream (feeds §7.6) — and whether transcript entries for tool exchanges can be constructed app-side.~~ **Resolved at M4 (rev 7)**: `ResponseStream.Snapshot.transcriptEntries` exposes `toolCalls` / `toolOutput` entries mid-stream, and both types are publicly constructible (`ToolOutput(id:toolName:segments:)`), so the v0.2 transcript-fidelity item (§12) is feasible. v0.1's stance is unchanged (§7.6). No residue for v0.1.
3. ~~**`LanguageModel` conformance surface:** exact model + executor requirements, so `ScriptedLanguageModel` conforms to the real thing, not a guess.~~ **Resolved at M3 (rev 6)** by reading the installed macOS 27 SDK: `LanguageModel` requires `associatedtype Executor`, `capabilities`, `executorConfiguration`; `LanguageModelExecutor` requires `associatedtype Configuration: Hashable & Sendable`, `associatedtype Model`, `prewarm(model:transcript:)`, `init(configuration:) throws`, and `respond(to:model:streamingInto:) async throws`. `ScriptedLanguageModel` conforms for real, gated `@available(macOS 27)`. Re-verify per beta.
4. ~~**Snapshot stream element types:** what the cumulative-snapshot stream vends (feeds §7.3 prefix-diffing).~~ **Resolved at M4 (rev 7)**: `ResponseStream<Content>.Snapshot { content, rawContent, transcriptEntries (27+), usage (27+) }`. **The interesting half is what it withdrew** — the channel's `replaceTextSegment` means prefix-stability is provider behaviour, not an API guarantee (§7.3). M6 residue: prefer segment-aware diffing, and measure how real providers behave.
5. ~~**Built-in `LanguageModelError` inventory:** the case list `GenerationError` must totally cover (§8) — including exact case *names*.~~ **Resolved at M3 (rev 6)**, from the SDK interface: `contextSizeExceeded`, `rateLimited`, `guardrailViolation`, `refusal`, `unsupportedCapability`, `unsupportedTranscriptContent`, `unsupportedGenerationGuide`, `unsupportedLanguageOrLocale`, `timeout` — each carrying a payload struct. §8 is reconciled against this list and now states its coverage as a table. Re-verify per beta; a *new* built-in case is the one change that would reopen this.
6. ~~**Session single-flight surface:** the exact error/behavior when a second request hits a responding session (feeds §6.5/§7.2). iOS 26 evidence: it surfaced *as* `GenerationError.rateLimited` — single-source, verify.~~ **Resolved at M4 (rev 7)**: `LanguageModelSession.Error.concurrentRequests` (typed, 27+), split out of the iOS 26 enum that also held `rateLimited` — which is how the 26 evidence arose. §7.2's gate is retained: the 26 enum is deprecated, not absent, so a provider built against it can still throw the overloaded shape. **M6 residue: confirm it is thrown, not trapped.**
7. ~~**Context-management & KV-cache APIs:** confirm the new iOS 27 context APIs stop at the session boundary — this is the sherlock check for §2.~~ **Resolved at M4 (rev 7): the sherlock check passes.** `ContextOptions` is per-request, `TranscriptErrorHandlingPolicy` per-session, `session.usage` per-session, `Transcript` mutable in place. All session-scoped, none persistent (§2). No residue.
8. ~~**`ModelDescriptor` derivation, narrowed (rev 4):** whether the *requested* descriptor is derivable from `any LanguageModel`'s configuration surface or must be app-supplied at driver init.~~ **Resolved at M4 (rev 7): app-supplied, necessarily.** `LanguageModel` exposes only `capabilities` and an opaque `executorConfiguration`; there is no model-identity key in the framework. `StopInfo.resolvedModelID` is per-provider convention — **expect nil on-device** (§7.8).
9. ~~**Reasoning & custom segments (rev 4):** what the iOS 27 stream and transcript expose — observable? recordable? re-constructible?~~ **Resolved at M4 (rev 7)**: observable (the channel's `Reasoning` action family) and constructible (`Transcript.Reasoning { segments, signature }`); `Transcript.Segment` also gained `attachment` and `custom`, while `Transcript.Entry`'s six kinds are unchanged. v0.1 records none of it **by choice** (N11, N8a). No blocking residue; v0.2 scope.

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

## Appendix C — Changes from rev 4

Rev 5 is a **clarifying** revision, opened by the M1 completion audit and closed by the M2 audit (both 2026-07-25): no semantics reverse, no event kind is added or removed, no invariant weakens, and no code written against rev 4 becomes wrong. Four of the first five items close gaps M2 would otherwise have had to improvise past; the last two record what implementing M2 actually surfaced — which is the point of auditing at milestone boundaries rather than mid-reducer. **Ratified at the M2 boundary**; subsequent amendments open rev 6.

- **`MessageID` is allocate-once (I7, §6.6 row 6).** Rev 4 covered `MessageID` collision at two of the three sites that introduce a node — row 8 (`generationStarted`) and row 11 (`messageEdited`'s replacement) — and was silent at the third. Row 6 now covers `userMessageAppended` reusing an ID the tree holds, and I7 states the general rule: an ID that has ever named a node can never name another. The silence was not harmless: it admitted a user-authored event overwriting an in-flight assistant message whose ID was bound at its `generationStarted` — user-authored assistant content by the back door, which §6.1's role rule exists to forbid. Rows 6, 8 and 11 are now one rule at three sites, not three coincidences.
- **The folded layer gets its own state enum (§6.3, I1).** "`Conversation` minus `Recoverability`" hid the fact that `Recoverability` lives *inside* a `MessageState` case: the folded layer needs a parallel four-case enum, and it needs a case rev 4 never named — **`.open(partial:)`**, a generation started and not terminated *without* the claim that it crashed. §9 already required it ("a snapshot landing mid-generation stores the open generation open") and I5 already called `.interrupted` "a finalization-time classification"; rev 5 supplies the type that makes both true by construction. The three-name table — folded `.open` → classified `.interrupted` → overlaid `.streaming` — is now in §6.3, because reading it right-to-left *is* the recovery story. Consequence made explicit: a snapshot that could hold `.interrupted` is a snapshot that can forge a crash, so the parallel enum is tenet 1 applied to the reducer's own internals rather than a DRY violation. Finalization is stated to live in `classify` (not a fourth pipeline stage), and I1's second half notes that it takes no input beyond the folded state and so cannot perturb determinism. Also stated: the folded layer is `Codable` throughout and that conformance **commits to nothing** — snapshots are discard-on-mismatch, so `Content` and `QuarantinedEvent` gain `Codable` freely, while `GenerationError`'s conformance is the one that stays load-bearing because it sits on both the wire and the snapshot path.
- **Tolerant-terminal widened to match its own rationale (§6.6 row 3, §6.1).** §6.1 always described the rule broadly ("a hostile garbage outcome, *or* an `Outcome`/`GenerationError` case added by a future LedgerKit"); row 3 described it narrowly, as unknown-discriminator only. Row 3 now covers every way a nested outcome can fail to decode — unknown tag, unknown nested error tag, corrupt body, absent field — with `<missing>` / `<unreadable>` as the diagnostic tags where none is legible. The one cost is now owned in §6.1: because the rule keys on *failing to decode* rather than on *being unfamiliar*, a corrupt `completed` body re-renders as a failure. Correct trade — terminal-ness is the only property I5 depends on, and the narrow rule would have re-opened the forgery hole for every corruption that is not a clean unknown tag.
- **Diagnostic identity stated (§6.6).** `QuarantinedEvent.eventID` is `nil` for row 1 and gap diagnostics only; every other row carries the event's identity. Row 2 is the one that takes deliberate effort — an all-or-nothing record decode discards the envelope along with the unrecognized payload, silently degrading the forward-compatibility diagnostic to sequence-only. The envelope must therefore decode independently of the payload. Rev 4 implied the requirement in `QuarantinedEvent`'s doc and stated it nowhere.
- **Duplicate `EventID` recorded as a non-rule (§6.6).** Rev 4 added the non-rules paragraph so the inventory would "stay honest"; this was the remaining unaddressed condition. It does not quarantine: `sequence` is the only identity reduction consults, so a collision is a generator defect to find, not contained loss to skip a valid fact over.
- **Row 9 covers orphaned terminals (§6.6).** A `generationEnded` naming a generation that never started was in neither row 9 (deltas and tool records only) nor row 10 (second terminals only), even though the cascade prose in §6.6, §10 and Appendix B all asserted that rows 9–10 handled it. Surfaced by implementing the cascade fixture at M2.1, where a quarantined start orphans three event kinds and the table accounted for two.
- **A `providerFailure` status outside 4xx/5xx gets a row (§8).** The table enumerated 4xx and 5xx and stopped, leaving a provider failure reporting 2xx, 3xx, or nonsense with no stated verdict. It takes the same safe floor as an unclassifiable one — `terminal`, loudly — on the grounds that such a status is malformed rather than meaningful, and `terminal` still leaves Regenerate as the manual retry. Surfaced at M2.2, where the mapping's exhaustive `switch` had to answer the question the table didn't. Also stated: "logged loudly" is a normalization-time obligation, not a classification-time one, because `classify` is pure — three of the four loud rows are the driver's to notice at M6, and the fourth is the app's.
- **Row ordering recorded as a non-rule (§6.6).** Reduction requires ascending sequence and neither verifies nor repairs violations; only deltas and tool records are non-idempotent under replay, everything else quarantines or is last-write-wins. Named because the non-rules paragraph exists so the inventory's completeness claim stays true, and this was the remaining unaddressed condition — reachable today only by fuzz generators and by v0.3 import/log-shipping tooling.
- **Smaller.** `Message` gains `generationID` (assistant only) — I7 already made the binding 1:1, and the folded layer *needs* it to route deltas after a snapshot resume, so the map is not reconstructible from a snapshot without it; projecting it publicly costs nothing and helps audit. `QuarantinedEvent.reason` becomes the closed `QuarantineReason` enum rather than a bare `String`, so §6.6's "single inventory" claim is compiler-checked and fixtures assert cases instead of prose ADR-001 declares non-contractual; the rendered string survives as `CustomStringConvertible`. §6.6 gains the input corollary: reduction consumes rows that may be undecodable, because rows 1–2 cannot originate inside a fold over already-decoded events.
- rev 3 → rev 4 map: see Appendix B.

## Appendix D — Changes from rev 5

Rev 6 is opened by **M3**, and its character is different from every revision before it: rev 5 and earlier reasoned about Apple's API from documentation and WWDC coverage, because that was all there was. **Rev 6 is the first revision written against the installed SDK.** Xcode 27 with the macOS 27 SDK is on the build machine, `FoundationModels.swiftinterface` is 3,583 readable lines, and two of §14's nine open questions turned out to be answerable by opening a file. Where this revision changes something, it is almost always because the real interface disagreed with a reasonable inference — which is the argument for checking the others the same way (M6's list, §14).

**Ratified at the M3 boundary (2026-07-26); subsequent amendments open rev 7.** No invariant weakens, no event kind is added or removed, and the reducer's semantics are untouched. One change *is* wire-affecting and is called out as such. Every item below is implemented and under test as of ratification — the taxonomy changes ship in `Core/GenerationError.swift` and `Reduce/RecoverabilityMapping.swift`, and §8's coverage table is asserted row for row by `RecoverabilityMappingTests`.

- **§8's taxonomy reconciled against the real `LanguageModelError` (OQ5 closed).** The claim that `GenerationError` is a "total normalization of Apple's built-in taxonomy" was false in three ways, all now fixed. (1) **`contextWindowExceeded` → `contextSizeExceeded`** — the old name matched no Apple case, which quietly broke the rule that built-ins "map 1:1 first" and that names are mirrored exactly. **This is a wire change**: the discriminator is renamed and the old tag is reserved forever in ADR-001's registry. It is free now — pre-1.0, no released logs exist and the frozen corpus (§10.2) is still empty — and would not be free later, which is precisely why it happens in the revision that noticed it. (2) **`refusal` added**: Apple distinguishes the model *declining* from a *guardrail intervening*, and so does this taxonomy; they classify identically today, and are kept apart anyway because the distinction is real and may yet earn different affordances. (3) **`unsupported(UnsupportedFeature)` added**, grouping the four `unsupported*` built-ins that previously fell through to `unrecognized` — the floor, whose whole job is to be loud about things the taxonomy failed to anticipate, and which was quietly absorbing four cases the taxonomy *had* been shown. Grouped rather than lifted because all four classify `terminal` and three of four are configuration errors; §8 records that reasoning so a later reader does not "fix" it. §8 also gains a coverage table, so "total" is now a checkable claim rather than an adjective.
- **`modelUnavailable`'s provenance stated (§8).** It normalizes `SystemLanguageModel.Availability.UnavailableReason`, not a `LanguageModelError` case — an availability API queried *before* generating. The names match exactly, as rev 4 promised; what was missing was any indication of where they come from, so a reader auditing §8's totality against `LanguageModelError` alone would find the case unaccounted for and conclude the section was sloppy. PCC's smaller reason set is noted too (`systemNotReady` → `.modelNotReady`).
- **§7.3: which side of the stream you are on (the sentence that would have cost an evening).** A *provider* writes deltas (`appendText` fragments into the executor's channel); a *consumer* reads cumulative snapshots (`ResponseStream.Snapshot.content`); the framework accumulates in between. Rev 5's "FM streams cumulative snapshots, not deltas" is correct from the driver's seat and reads as flatly wrong from a provider author's, and `ScriptedLanguageModel` is a provider — so the package contains both seats and needed the distinction written down. It also names a free end-to-end property for M6: scripted fragment → accumulation → snapshot → driver diff → `deltaAppended` must recover exactly what the script emitted.
- **OQ3 closed (§14).** The `LanguageModel` / `LanguageModelExecutor` requirements are recorded verbatim. `ScriptedLanguageModel` conforms to the real protocols, gated `@available(macOS 27)`, rather than to an internal imitation — the imitation was only ever justified by the surface being unknown. The engine and script vocabulary stay platform-agnostic, so M3's "verifiable on any Mac" property survives intact.
- **§10.1: `LedgerKitTestSupport` is a provisional name.** It undercuts the positioning it exists to serve — nobody installs *LedgerKitTestSupport* to get a Foundation Models test double — and it advertises a dependency the product deliberately does not have. Renaming is cheap pre-1.0 and expensive after; the decision is deferred no later than the `0.1.0` tag.
- rev 4 → rev 5 map: see Appendix C.

## Appendix E — Changes from rev 6

Rev 7 is opened by **M4** and closes the arc rev 6 began. Rev 6 was the first revision written against the installed SDK and closed two of §14's nine open questions by reading a file; rev 7 closes **seven more the same way**, which is the finding worth stating plainly: *nine open questions were carried for three milestones on the assumption they were empirical, and seven of them were answerable by opening `FoundationModels.swiftinterface`.* What is left is genuinely about behaviour — is an error thrown or trapped, what do real providers do — and belongs to M6. The lesson is cheap to state and was expensive to learn: **read the interface first; a spike evening is for questions the interface cannot answer.**

**Ratified at the M4 boundary (2026-07-26); subsequent amendments open rev 8.** No invariant weakens, no event kind is added or removed, and the reducer's semantics are untouched. One change is wire-affecting (`contextSizeExceeded`'s payload) and was additive by construction; one section (§6.6 row 2) has its *description* corrected with no change to behaviour. Everything below is implemented and under test as of ratification — 266 tests across both packages.

- **`contextSizeExceeded` carries Apple's two numbers (§8; M4-PLAN D17 — the wire change).** `contextSizeExceeded(contextSize: Int?, tokenCount: Int?)`, mirroring `LanguageModelError.ContextSizeExceeded`. This is the one built-in whose payload changes what an app can *do*: N3 makes window overflow a headline on-device failure, and `reduceContext` is a far better affordance when the app can say how far over it was. Optional where Apple's are not, because the ledger records what was *reported* and non-Apple providers report neither — nil says "not reported," which zero cannot. Classification ignores the payload entirely. **Additive by construction, which is the only reason this could happen after ratification:** the tag is unchanged, nil fields encode as absent keys, old readers skip unknown keys, and `wire/contextSizeExceededLegacy` pins all three shapes — pre-widening, post-widening, and a *future* version's extra field — from bytes on disk. The corpus proves it rather than the commit message claiming it: every `dev/` fixture came back byte-identical. **Recorded for the next one:** Swift enum cases take no default arguments, so widening a case is source-breaking at every construction site even when the wire does not notice.
- **§7.3: prefix-stability is provider behaviour, not an API guarantee (OQ4 closed).** The provider channel offers `replaceTextSegment(_:segmentID:tokenCount:)` beside `appendText`, both carrying a `segmentID`, so a provider may legally revise a segment it already sent and the accumulated snapshot is then not a prefix extension of its predecessor. Rev 5 assumed append-only; rev 6 explained which side of the stream sees what; rev 7 records that the property was never Apple's to promise. Three consequences, none of which changes v0.1's shape: the driver's fail-loud path was chosen as a can't-happen assertion and is now the honest answer to a legal behaviour this version does not model; M6 should prefer segment-aware diffing via `transcriptEntries`; and recording a revision faithfully would need a new payload kind, since `deltaAppended` is append-only by construction — a v0.2 conversation priced exactly like §7.6's started/ended split.
- **§6.6 row 2 covers two conditions, and always did (the inventory's completeness claim, repaired).** A row whose envelope reads, whose payload names a kind this version *does* know, but whose body will not decode was in neither row 1 ("no identity recoverable") nor row 2 ("unknown discriminator"). Found at M4 Phase 2 by a fixture that produced it. **The disposition was already correct** — skip the row, keep the identity, keep reading — so no behaviour changes; row 2's *description* now covers both, because a table that calls itself the single inventory has to be one. `wire/undecodableRows` pins it. The diagnostic's rendered prose was reworded to match (non-contractual per ADR-001, so no fixture moved).
- **The busy-session question closes, and explains its own history (OQ6).** At 27, `LanguageModelSession.Error { concurrentRequests, transcriptMutationWhileResponding }` is session *misuse*, split out of the iOS 26 enum that carried it alongside `rateLimited` — which is exactly how "busy session surfaces as `rateLimited`" became a plausible reading of the 26 evidence. §7.2's gate is **retained**, and its rationale improves: the 26 enum is deprecated case-by-case, not removed, so a provider built against 26 can still throw the overloaded shape, and §8's normalization must recognize both families. M6 residue: thrown or trapped.
- **Model identity: app-supplied, necessarily (OQ8 closed, §7.8 softened).** The `LanguageModel` protocol is two requirements wide — `capabilities` and an opaque `executorConfiguration` — with no model-identity key anywhere in the framework. Asking the app at driver init is not a fallback, it is the only correct design. `StopInfo.resolvedModelID` is downgraded honestly: no standard metadata key exists, it is per-provider convention, and **nil is expected on-device**. Request ≠ resolved remains valuable where it is available and is not a guarantee.
- **The sherlock check passes (OQ7 closed, §2).** `ContextOptions` is per-request, `TranscriptErrorHandlingPolicy` per-session, `session.usage` per-session, and `Transcript` is `MutableCollection` + `RangeReplaceableCollection`. Everything session-scoped, nothing persistent. The most interesting result is the last one: **Apple made the working copy officially mutable, which argues *for* durable truth living outside it.** A transcript you can splice in place is a buffer; a record is what you still trust after someone splices the buffer.
- **Reasoning is recordable and deliberately not recorded (OQ9 closed, N11 reworded).** Rev 4 said "not even recordable," which the SDK falsifies — reasoning is observable on the channel and constructible as `Transcript.Reasoning { segments, signature }`. So v0.1's silence becomes a decision that must be defended, and is: reasoning text is the most sensitive content a model produces and the least stable across providers, the ledger outlives the session, and `.metadataOnly` already applies that judgement to the strictly less sensitive category of tool results.
- **Entries did not grow; segments did (N11 amended, N8a added).** `Transcript.Segment` went from two cases to four (`attachment`, `custom`), while `Transcript.Entry` still has six kinds — the M3 audit's note to the contrary was a misreading, caught while drafting this revision. Multimodal user input is therefore a real 27 feature, and v0.1's text-only `userMessageAppended` is recorded as an **owned scoping decision with additive headroom** rather than an artifact of the iOS 26 shapes: reversible as a new payload kind or a widened content field, both of which old readers degrade on rather than corrupt.
- **Usage field names verified; the mapping is recorded (§7.7's ⚠️ closed).** `Usage.Input { totalTokenCount, cachedTokenCount }` and `Usage.Output { totalTokenCount, reasoningTokenCount }` map 1:1 and totally onto `TokenUsage`'s four fields; `ResponseStream.Snapshot` carries `usage` too, so cost is observable mid-stream. One asymmetry, deliberate: Apple's fields are non-optional and LedgerKit's are not, because a provider may report nothing and nil says so where zero cannot. One M6 residue: whether input's total is inclusive of cached — which decides whether an app may sum them.
- **§8 gains Apple's third `Retry-After` form.** `LanguageModelError.RateLimited` carries `resetDate: Date?` — an instant, not a duration. All three forms normalize to a duration *at normalization time*, which is a clock read that is legal in the driver and forbidden in the reducer (I1); the persisted value stays clock-independent and display math remains `terminalTimestamp + retryAfter`.
- **`Refusal.explanation` is an on-demand generation, not stored data.** It is an `async throws` `Response<String>`, so reading it asks the model to explain itself and costs tokens. Rev 6 declined to project refusal text on the grounds that debug detail must not classify; rev 7 records that the alternative would have meant persisting the output of a *second inference call* into an append-only ledger, or storing a promise that cannot be honoured once the session is gone.
- **The test double is named `Understudy` (§10.1).** The provisional name undercut the positioning it existed to serve and advertised a dependency the product deliberately does not have. The theatrical vocabulary was already in the API (`Script`, `Step`, `Cue`); discoverability is the package description's job.
- **What M4 built, recorded where the spec was vague or now-stale (§9, §10).** Events are **TEXT** holding UTF-8 JSON — "blob" described opacity to the database and was read as a storage class, and a log that prints readably under `sqlite3` is worth real money in a project whose fixtures are documentation; the database still never interprets it. The **schema version lives in a column, never the blob** (ADR-001 D-2). The **snapshot discard condition is four-way**, two of them previously unstated — a payload naming another conversation (the snapshot analogue of row 4) and a checkpoint claiming a sequence before genesis. **GRDB is the decided backend** (ADR-003), behind a six-verb internal protocol that keeps the §12 cut line to raw sqlite3 cheap. **P1 is a store property, not a pure one** — its actual question is whether `append`'s return value is interchangeable with a re-read, which in memory is unaskable. **P1 and P3 sweep exhaustively rather than randomly**, because fixtures are ≤ 22 rows and exhaustive buys no seed, no flake, and failures that reproduce by re-running. **P2's harness exists before its overlay**, parameterized over it, because the empty-live-set case is not a placeholder but the state every cold open lands in. And the **discriminator registry is mechanically enforced** (ADR-001 D-3): a checked-in manifest, compared against what the codecs encode in both directions, with deletion caught by the compiler because the test reads the same exhaustive inventories the round-trips do.
- rev 5 → rev 6 map: see Appendix D.

## Appendix F — Changes from rev 7

Rev 8 was opened by the **M4 boundary audit** (2026-07-27) and closed by **M5** (2026-07-28). The audit's two items came first and are small: a provenance correction found by reading the swiftinterface, and a refresh of illustrative names. M5's nine follow, and they have a shape worth naming up front — **only two change what the API promises; five state mechanisms this document assumed and never wrote down.** That ratio is the honest summary of building the store: the design held, and what it lacked was not decisions but *sentences*. The most expensive of them (a cancelled task cannot record its own cancellation) was a wall M5 walked into, not a subtlety anyone reasoned out in advance.

**Ratified at the M5 boundary (2026-07-28); subsequent amendments open rev 9.** No invariant weakens, no event kind is added or removed, the reducer's semantics are untouched, and **nothing here touches the wire**. Everything below is implemented and under test as of ratification — **331 tests** across both packages.

### From the M4 boundary audit (2026-07-27)

- **`StopInfo.stopReason` has no source in the framework (§6.1, §7.7).** Rev 7's "field names verified" sentence covered the four usage fields but read as covering all of `StopInfo`; the audit read the interface for the rest and found **no stop-reason surface anywhere in the 27 SDK** — `Response` is `{content, rawContent, transcriptEntries, usage}`, and the only free-form reporting channels are the `metadata` dictionaries. `stopReason` therefore joins `resolvedModelID` (§7.8) as per-provider convention: the ledger records what is reported, **nil is the expected value on-device**, and a nil must never read as a failure. The field stays — optional struct fields are cheap headroom — but its provenance is now stated instead of implied. The general rule, restated from Appendix E because it caught its own author: *a claim of verification has to say what it verified.*
- **Illustrative names refreshed to the shipped surface (§6.1, §6.2, §6.3, §11, §12).** `Content` → `MessageContent`; `Payload`'s generation/message values labelled (`generationStarted(generation:message:parent:model:)` and kin — wire-neutral, since tags live in the discriminator registry and field keys in `CodingKeys`); `MessageState.failed` labelled; `.sqlite(url:)` → `.sqlite(at:)`, Foundation's convention for file-location labels. Names were always bikesheddable per §6.1's standing rule, so none of this is semantic — but sketches that match the code they illustrate are worth keeping true whenever the drift is noticed, and the M4 audit noticed.
### From M5 — the `ConversationStore` actor (2026-07-28)

**What changes the contract:**

- **`LedgerError` is recorded, and it has a sixth case (§11).** Five of the six were named in prose already; the inventory is now stated against real signatures, with the reasoning for `persistenceFailure` carrying opaque prose and for `CancellationError` deliberately *not* being a case. The new one is **`unsupportedTarget`**, and it is N10 arriving from an unexpected direction: `regenerate` of a **root-level** assistant message would require `generationStarted(parent: nil)`, the shape N10 reserves as wire headroom the v0.1 store never writes — so the store refuses. Every prior application of "log tolerant, store enforcing" granted the log latitude; this one spends it. Reachable only from a log a *newer* LedgerKit wrote, which is the direction that matters, and relaxing N10 later makes the case unreachable rather than wrong.
- **The throw channel covers "couldn't record", not only "never started" (§11).** A persistence failure while flushing deltas or recording the terminal is post-start, so the old phrasing excluded it while §11's own stated principle — *one channel for "couldn't record"* — includes it. The store throws and deliberately writes **no** terminal, leaving the generation open to reduce as `.interrupted`: "something went wrong" is true, where a `.completed` terminal missing a flush would claim success. The old sentence was a description of practice written before anything implemented a terminal append.

**Mechanisms this document assumed and never stated:**

- **⚠️ The append that records a cancellation must not run inside the cancelled task (§7.5).** The milestone's sharpest finding, and one nothing in this spec would have led a reader to. A cancellation-aware backend — GRDB is one — makes writes inside a cancelled task *throw instead of writing*, so performing the wind-down there means **a stop erases its own evidence**: no terminal, generation left open, conversation reads `.interrupted`. That is a different state with a different UI treatment for something the user explicitly did, and §7.5 has insisted on that distinction since rev 1 without ever saying what would destroy it. Cancellation stops the **driver**; the wind-down runs outside the cancelled scope. Discovered by measurement — every cancellation test failed before the shape was right.
- **Partial-content retention needs the consume loop to exit on *stream end*, not on cancellation (§7.5).** The same restructure, and the reason it is stated separately: a loop that exits on cancellation silently drops whatever the driver emitted but the store had not yet read. "Partial content retained" then means "as much as we happened to have", which is not a property.
- **A stop landing in the start window is honoured, not dropped (§7.5).** §6.5's start atomicity opens an interval where a generation is claimed but not running. Reading §11's "no-op if none live" literally there would let a visibly-started generation finish after the user pressed stop.
- **The driver seam exists, and is contract (§7.9, new).** §7 has always described driver *obligations* with no interface to attach them to. Now stated: a `ModelDescriptor` the driver exposes, plus one **non-throwing** call taking rehydration material and a signal channel and returning the one terminal `Outcome`. Non-throwing is the whole design — the store appends `generationStarted` first, so everything after is an `Outcome`, and cancellation *returns* `.cancelled`, making §11's documented deviation structural rather than documented. A table records which side owns what. The shape echoes Apple's provider seam with one deliberate divergence: theirs returns `Void` and throws because a provider's failures are the caller's problem; ours returns the `Outcome` because a driver's failures **are the ledger's content**.
- **"Best-effort async" snapshot refresh governs failure, not detachment (§9).** A detached save can land after `deleteConversation` erased the conversation, resurrecting a snapshot row for a log that no longer exists — §9 already closes that race for terminals, and it was open at the other door.

**Attribution and testing strategy:**

- **§7.4's flush loop is the store's, not the driver's.** Behaviour unchanged; the sentence predates the seam. The store owns every append, so the cadence of appends is necessarily its business.
- **§10.4's cancellation points are enumerated and parked, not randomized.** The concurrency sibling of rev 7's exhaustive-not-randomized amendment, with a mechanism difference worth naming: the pure sweeps enumerate splits of a log, this enumerates moments in a *running* generation, which exist only if something holds it still. One case stays genuinely racy — cancel versus a natural terminal — and is asserted by outcome invariant rather than by timing nobody can control.
- **The healthy-log property is stated, *with its limit* (§6.5).** Store-written logs always reduce with empty `diagnostics`, which is what lets an app read a non-empty `diagnostics` as evidence of damage or of a newer writer. The limit matters as much as the property: a healthy log is not a *correct* one — an edit missing its paired path event reduces perfectly cleanly while being wrong — so this certifies only that the store never writes what the reducer would reject. Mutation testing is what forced the distinction; it would have been comfortable to leave it implied.

- rev 6 → rev 7 map: see Appendix E.

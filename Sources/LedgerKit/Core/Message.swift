import Foundation

/// One node of the message tree — derived state, rebuilt by folding the log
/// (SPEC §6.2). Not `Codable`: the snapshot schema is `FoldedState` (M2/§9),
/// never these types directly.
public struct Message: Sendable, Identifiable, Equatable {
    public var id: MessageID
    public var role: Role
    /// Assistant only — I7 binds this 1:1 with `id`.
    ///
    /// Surfaced publicly because the folded layer requires it regardless (it is
    /// how a snapshot resume rebuilds the generation→message routing map), so
    /// projecting it costs nothing and makes a log dump legible by eye.
    public var generationID: GenerationID?
    /// `nil` ⇒ root-level (child of the virtual root, I6).
    public var parent: MessageID?
    /// Sibling order = sequence order (SPEC §6.4).
    public var children: [MessageID]
    /// User messages: always `.complete`.
    public var state: MessageState
    /// Assistant only — the *requested* descriptor from `generationStarted`
    /// (SPEC §7.8).
    public var model: ModelDescriptor?
    /// Assistant only — from `Outcome.completed` (SPEC §7.7); nil otherwise.
    public var stopInfo: StopInfo?
    /// Assistant only; sequence order.
    public var toolRecords: [ToolRecord]
    /// The originating event's envelope timestamp. Display/audit only.
    public var timestamp: Date
    /// The terminal event's envelope timestamp; nil while open and for
    /// `.interrupted` (no terminal exists — I5). Gives
    /// `rateLimited(retryAfter:)` its display instant (SPEC §8).
    public var terminalTimestamp: Date?

    /// Reducer-side assembly. **Internal on purpose (M4 Phase 0):** this
    /// initializer can express states the domain forbids — a `.user` message
    /// that is `.streaming`, an assistant `generationID` on a user node, a
    /// `stopInfo` on a failure — and tenet 1 says illegal states should be
    /// unrepresentable rather than merely undocumented. The only *public* way to
    /// obtain messages is therefore to reduce a log
    /// (``Conversation/init(reducing:loadedFrom:mapping:)``), which cannot
    /// produce any of them.
    ///
    /// This costs previews and fixtures nothing: building a short log is a
    /// better example anyway, because it exercises the real semantics. It was
    /// briefly `public` (M1–M3) for no reason anyone needed — the elements of a
    /// tree whose own assembly initializer was already internal.
    init(
        id: MessageID,
        role: Role,
        generationID: GenerationID? = nil,
        parent: MessageID? = nil,
        children: [MessageID] = [],
        state: MessageState,
        model: ModelDescriptor? = nil,
        stopInfo: StopInfo? = nil,
        toolRecords: [ToolRecord] = [],
        timestamp: Date,
        terminalTimestamp: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.generationID = generationID
        self.parent = parent
        self.children = children
        self.state = state
        self.model = model
        self.stopInfo = stopInfo
        self.toolRecords = toolRecords
        self.timestamp = timestamp
        self.terminalTimestamp = terminalTimestamp
    }
}

/// Who authored a message. User messages arrive via `userMessageAppended`;
/// assistant messages exist only as the product of a generation (SPEC §6.1).
///
/// `Codable` for the snapshot path only. Role is never on the event wire — it is
/// *derived* from which event introduced the node — so this conformance carries
/// none of `LedgerEvent.Payload`'s permanence: snapshots are discard-on-mismatch.
public enum Role: String, Sendable, Hashable, Codable {
    case user
    case assistant
}

/// The message lifecycle (SPEC §6.2) — the exhaustive-switch showpiece.
///
/// Deliberately not `Codable`: `.interrupted` is fold-derivable only (dead
/// logs), `.streaming` is projection-only (live overlay, §7.4), and `.failed`
/// carries `Recoverability`, which is never persisted. There is deliberately
/// no `.pending` distinct from `.streaming(partial: "")`.
public enum MessageState: Sendable, Equatable {
    case complete(MessageContent)
    case streaming(partial: String)
    /// Labelled because this is the one case carrying three payloads, and it is
    /// the case consumers destructure most (SPEC §11's showpiece switch). A
    /// positional `.failed(_, let error, _)` makes a reader count; the labels
    /// make the same match self-describing. Patterns may still bind
    /// positionally, so this costs match sites nothing.
    case failed(partial: String, error: GenerationError, recoverability: Recoverability)
    case cancelled(partial: String)
    case interrupted(partial: String)
}

/// Completed assistant content. A struct, not a bare `String`, on purpose:
/// v0.2's structured partials (N8) extend it additively without turning
/// `MessageState` into a moving target (SPEC §6.2).
///
/// Named `Content` until M4: the bare noun said nothing ("content of what?") and
/// collided conceptually with SwiftUI's ubiquitous `Content` and Foundation
/// Models' own `Content` generic parameters, in a package whose whole job is to
/// sit beside both. Wire-neutral rename — Swift type names reach no encoding
/// (payload tags are `Kind` raw values; the snapshot's synthesized coding keys
/// off case and label names).
///
/// `Codable` for the snapshot path only (`FoldedMessageState.complete`), which is
/// why N8 can widen it freely — a stale snapshot is discarded, never migrated.
public struct MessageContent: Sendable, Equatable, Codable {
    public var text: String

    /// Stays **public** where the other derived-state initializers went internal
    /// at M4 Phase 0, and the distinction is the reasoning rather than an
    /// oversight: those can express states no log can produce, and this cannot —
    /// there is no invariant over a string to violate. It also earns its keep,
    /// since a consumer previewing their own bubble view needs some way to hand
    /// it content.
    public init(text: String) {
        self.text = text
    }
}

import Foundation

/// One node of the message tree — derived state, rebuilt by folding the log
/// (SPEC §6.2). Not `Codable`: the snapshot schema is `FoldedState` (M2/§9),
/// never these types directly.
public struct Message: Sendable, Identifiable, Equatable {
    public var id: MessageID
    public var role: Role
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

    public init(
        id: MessageID,
        role: Role,
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
public enum Role: Sendable, Hashable {
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
    case complete(Content)
    case streaming(partial: String)
    case failed(partial: String, GenerationError, Recoverability)
    case cancelled(partial: String)
    case interrupted(partial: String)
}

/// Completed assistant content. A struct, not a bare `String`, on purpose:
/// v0.2's structured partials (N8) extend it additively without turning
/// `MessageState` into a moving target (SPEC §6.2).
public struct Content: Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

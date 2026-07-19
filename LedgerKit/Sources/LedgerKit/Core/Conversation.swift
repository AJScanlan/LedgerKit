import Foundation

/// A conversation's fully reduced state (SPEC §6.2) — the output of
/// `classify(fold(log), mapping)`. Derived and rebuildable; the log is the
/// truth.
public struct Conversation: Sendable, Identifiable, Equatable {
    public var id: ConversationID
    public var title: String?
    /// Latest `instructionsChanged`; nil if never set.
    public var instructions: String?
    public var messages: MessageTree
    /// Root-level node → endpoint, the "visible" thread. The virtual root is
    /// excluded — it is not a message (I6).
    public var activePath: [MessageID]
    /// Quarantine residue (SPEC §6.6); empty on healthy logs. For logging and
    /// debug surfaces, not user-facing by default.
    public var diagnostics: [QuarantinedEvent]

    /// The visible thread, resolved to messages in path order (root-level
    /// node → endpoint). Non-optional per node on purpose: I6 plus the
    /// reducer's clamping guarantee that every `activePath` entry resolves,
    /// so per-element optionality at render sites would advertise a state the
    /// domain forbids. The `compactMap` is a defensive backstop, not policy.
    public var activeMessages: [Message] {
        activePath.compactMap { messages[$0] }
    }


    public init(
        id: ConversationID,
        title: String? = nil,
        instructions: String? = nil,
        messages: MessageTree = MessageTree(),
        activePath: [MessageID] = [],
        diagnostics: [QuarantinedEvent] = []
    ) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.messages = messages
        self.activePath = activePath
        self.diagnostics = diagnostics
    }
    
}

/// One skipped event's residue (SPEC §6.6, I2): reduction continued as if the
/// event were absent, and this records why.
public struct QuarantinedEvent: Sendable, Equatable {
    public var sequence: Int64
    /// `nil` if the row was undecodable at the envelope level, or for a
    /// sequence-gap diagnostic (one per contiguous gap, SPEC §6.1).
    public var eventID: EventID?
    public var reason: String

    public init(sequence: Int64, eventID: EventID? = nil, reason: String) {
        self.sequence = sequence
        self.eventID = eventID
        self.reason = reason
    }
}

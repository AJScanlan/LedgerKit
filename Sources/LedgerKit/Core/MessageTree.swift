/// The message tree — nodes keyed by `MessageID`, hanging off an implicit
/// virtual root (SPEC §6.2, I6). Tree, not DAG: no merges in v0.1.
///
/// Value-semantic and derived: only the reducer (M2) constructs and mutates
/// trees; consumers read. The virtual root is not a message — it is
/// represented only by `rootChildren`.
public struct MessageTree: Sendable, Equatable {
    /// The virtual root's children, sibling-ordered (= sequence order, like
    /// everywhere else — SPEC §6.4).
    public private(set) var rootChildren: [MessageID]

    private var nodes: [MessageID: Message]

    /// An empty tree — what a conversation has before its first message.
    public init() {
        self.nodes = [:]
        self.rootChildren = []
    }

    /// Reducer-side assembly (M2). Not public: consumers never build trees.
    init(nodes: [MessageID: Message], rootChildren: [MessageID]) {
        self.nodes = nodes
        self.rootChildren = rootChildren
    }

    /// Keyed lookup, `Dictionary`-shaped: optional because callers can hold
    /// IDs the tree does not — the domain permits dangling references
    /// (quarantine residue, stale UI state), so `Optional` is the truthful
    /// return type. For the visible thread, prefer
    /// `Conversation.activeMessages`, where resolution is guaranteed.
    public subscript(id: MessageID) -> Message? {
        nodes[id]
    }

    /// The message's children, sibling-ordered (= sequence order, SPEC §6.4).
    /// Unknown IDs and dangling child references yield the empty result —
    /// absence, not error, matching I2's containment posture.
    public func children(of messageID: MessageID) -> [Message] {
        guard let message = self[messageID] else { return [] }
        return message.children.compactMap { self[$0] }
    }

    /// Replaces message states in place, and **can do nothing else** (M7-PLAN D49).
    ///
    /// Exists for one caller — `Projection/Overlay.swift`, whose whole contract is
    /// "message state changes; nothing else does". P2's *"had more than its state
    /// overlaid"* clause polices that, but a predicate is a test and this is a
    /// type: going through here, the overlay cannot move a parent, reorder
    /// siblings, invent tool records or touch `terminalTimestamp`, so the
    /// predicate becomes belt-and-braces rather than the only defence. Tenet 1
    /// applied to the read side — the same move `FoldedMessageState` makes one
    /// layer down by simply having no `.streaming` case.
    ///
    /// **`mapValues` deliberately**, where a keyed loop would do: it preserves the
    /// key set *by construction*, so "the overlay cannot drop or invent a message"
    /// is a property of the API rather than of this body being written carefully.
    /// It is also order-independent — each value depends only on its own old value
    /// — which matters because a dictionary walk is normally the I1 hazard.
    ///
    /// Lives here rather than beside its caller, breaking the pattern that puts
    /// `Payload.updatesIndex` beside the index writer, for a reason with no
    /// alternative: `nodes` is `private`, so only this file can offer a mutation
    /// this narrow. Widening `nodes` to internal to move one method would hand
    /// the whole module the tree-rebuilding power this method exists to withhold.
    ///
    /// - Parameter transform: The new state for a message, or `nil` to leave it
    ///   exactly as it is.
    mutating func updateStates(_ transform: (Message) -> MessageState?) {
        nodes = nodes.mapValues { message in
            guard let state = transform(message) else { return message }
            var updated = message
            updated.state = state
            return updated
        }
    }

    /// The *other* branches at this message's position — its parent's
    /// children excluding the message itself, sibling-ordered. For root-level
    /// messages the parent is the virtual root (I6), so the group is
    /// `rootChildren`: an edited first message legally has root-level
    /// siblings (SPEC §6.4).
    ///
    /// Non-empty exactly when a branch switcher is warranted; a lone message
    /// has no siblings, matching the English word.
    public func siblings(of messageID: MessageID) -> [Message] {
        guard let message = self[messageID] else { return [] }
        let group: [MessageID]
        if let parent = message.parent {
            group = self[parent]?.children ?? []
        } else {
            group = rootChildren
        }
        return group.filter { $0 != messageID }.compactMap { self[$0] }
    }
}

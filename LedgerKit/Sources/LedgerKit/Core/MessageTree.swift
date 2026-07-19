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

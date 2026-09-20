import Foundation

/// A conversation's fully reduced state (SPEC §6.2) — the output of
/// `classify(fold(log), mapping)`. Derived and rebuildable; the log is the
/// truth.
///
/// ## Read-only to consumers (M9-PLAN D63)
///
/// Every stored property here — and on ``Message``, ``QuarantinedEvent`` and
/// `ConversationSummary` — is `public internal(set)`. M4 Phase 0 made these types
/// constructible **only** by reducing a log, and then left them mutable
/// afterwards, so a consumer could still write `message.state = .streaming(…)` —
/// a state no fold produces — through the back door the internal initializers had
/// just closed. Tenet 1 says illegal states should be unrepresentable rather than
/// merely undocumented, and half a door is not a door.
///
/// **`internal(set)` rather than `private(set)`, and the tests are why.** The
/// module legitimately mutates: `overlay(_:live:)` rewrites states through
/// `MessageTree/updateStates(_:)` from another file, and the test target builds
/// *deliberately wrong* projections to prove P2's predicates are not vacuous.
/// `private(set)` was tried and broke both. The invariant that matters is
/// "consumers cannot forge derived state", which is exactly what `internal(set)`
/// says — verified from outside the package, where
/// `message.state = .streaming(partial:)` now fails with *setter is
/// inaccessible*.
public struct Conversation: Sendable, Identifiable, Equatable {
    public internal(set) var id: ConversationID
    public internal(set) var title: String?
    /// Latest `instructionsChanged`; nil if never set.
    public internal(set) var instructions: String?
    public internal(set) var messages: MessageTree
    /// Root-level node → endpoint, the "visible" thread. The virtual root is
    /// excluded — it is not a message (I6).
    public internal(set) var activePath: [MessageID]
    /// Quarantine residue (SPEC §6.6); empty on healthy logs. For logging and
    /// debug surfaces, not user-facing by default.
    public internal(set) var diagnostics: [QuarantinedEvent]

    /// The visible thread, resolved to messages in path order (root-level
    /// node → endpoint). Non-optional per node on purpose: I6 plus the
    /// reducer's clamping guarantee that every `activePath` entry resolves,
    /// so per-element optionality at render sites would advertise a state the
    /// domain forbids. The `compactMap` is a defensive backstop, not policy.
    ///
    /// ## Computed, and **hoist it out of a SwiftUI body**
    ///
    /// This walks the path on every access, so evaluating it inside a `body` —
    /// `ForEach(projection.conversation.activeMessages)` — re-resolves the whole
    /// thread on every pass. Bind it once instead:
    ///
    /// ```swift
    /// let messages = projection.conversation.activeMessages
    /// ForEach(messages) { message in … }
    /// ```
    ///
    /// **Stored rather than computed was considered at M9 and rejected** (D64.3).
    /// The audit proposed precomputing it in `classify`, which reads as the
    /// obvious fix and is wrong: `overlay(_:live:)` rewrites message states
    /// through ``MessageTree/updateStates(_:)`` on every delta, so a stored array
    /// would be a second copy that goes stale against its own tree the moment a
    /// generation streams — trading a cheap walk for a cache-invalidation
    /// problem, in a type whose whole claim is that it is derived. The cost is
    /// also theoretical rather than measured: the walk is one dictionary lookup
    /// per message on the visible path.
    ///
    /// Hoisting is what the demo does, and Apple's own guidance says derived
    /// collections belong on the model rather than recomputed per pass — which is
    /// exactly what binding it once achieves without the staleness.
    public var activeMessages: [Message] {
        activePath.compactMap { messages[$0] }
    }


    /// Reducer-side assembly (`classify`). **Internal on purpose (M4 Phase 0):**
    /// a `Conversation` *is* the fold of a log, and the public way to make one is
    /// to say so — ``init(reducing:loadedFrom:mapping:)``. A memberwise
    /// initializer additionally admits states no log can produce: an
    /// `activePath` that is not a chain, an endpoint absent from `messages`,
    /// diagnostics unrelated to the events that made the tree. Tenet 2's "the log
    /// is the truth" is only structurally true if the log is the sole way in.
    init(
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
///
/// `Codable` for the snapshot path only — snapshots must persist accumulated
/// diagnostics or reduced state would depend on snapshot timing (SPEC §9, P3).
public struct QuarantinedEvent: Sendable, Equatable, Codable {
    public internal(set) var sequence: Int64
    /// `nil` if the row was undecodable at the envelope level (§6.6 row 1), or
    /// for a sequence-gap diagnostic (one per contiguous gap, SPEC §6.1). Every
    /// other row carries identity — see §6.6 "Diagnostic identity."
    public internal(set) var eventID: EventID?
    /// Typed rather than a bare `String`, so §6.6's inventory is
    /// compiler-checked and fixtures assert cases instead of prose ADR-001
    /// declares non-contractual. The rendered sentence is `description`.
    public internal(set) var reason: QuarantineReason

    /// Reducer-side assembly. **Internal on purpose (M4 Phase 0):** diagnostics
    /// are the reducer's account of what it skipped, and a consumer-fabricated
    /// one would be a claim about a reduction that never happened. Reading them
    /// off ``Conversation/diagnostics`` is the whole intended traffic.
    init(sequence: Int64, eventID: EventID? = nil, reason: QuarantineReason) {
        self.sequence = sequence
        self.eventID = eventID
        self.reason = reason
    }
}

extension QuarantinedEvent: CustomStringConvertible {
    /// One log line. Leads with sequence because that is the only identity a
    /// row-1 diagnostic has.
    public var description: String {
        let identity = eventID.map { " (\($0))" } ?? ""
        return "seq \(sequence)\(identity): \(reason)"
    }
}

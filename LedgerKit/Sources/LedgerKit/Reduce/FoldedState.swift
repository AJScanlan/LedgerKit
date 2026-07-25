import Foundation

/// A conversation reduced by `fold` alone — the middle layer of the pipeline
/// (SPEC §6.3) and **exactly** the snapshot schema (§9).
///
/// Deliberately **internal**. Consumers only ever hold `Conversation`, which is
/// what keeps this layer's `Codable` conformance a private implementation
/// detail: snapshots are discard-on-mismatch with no migration ever, so the
/// folded encoding is disposable in a way `LedgerEvent.Payload`'s emphatically
/// is not. Publishing it would turn a throwaway format into API.
///
/// Distinct from `Conversation` in exactly one way that matters —
/// ``FoldedMessageState`` in place of `MessageState` — and that difference is
/// the point: a snapshot that could hold `.interrupted` is a snapshot that can
/// forge a crash, so the folded layer simply has no such case (§6.3).
struct FoldedState: Sendable, Equatable, Codable {
    var id: ConversationID
    var title: String?
    /// Latest `instructionsChanged`; nil if never set.
    var instructions: String?
    /// Keyed storage only. The tree's *read* API (`children(of:)`,
    /// `siblings(of:)`) is a consumer convenience and lives on `MessageTree`,
    /// which the classify layer builds — nothing in the fold needs it, so
    /// duplicating it here would be duplication without purpose.
    var messages: [MessageID: FoldedMessage]
    /// The virtual root's children, sibling-ordered (= sequence order, §6.4).
    var rootChildren: [MessageID]
    /// Root-level node → endpoint, materialized. The virtual root is excluded —
    /// it is not a message (I6).
    var activePath: [MessageID]
    /// Quarantine residue (§6.6). Persisted with the snapshot, or reduced state
    /// would depend on snapshot timing and P3 would fail (§9, §10.6).
    var diagnostics: [QuarantinedEvent]

    /// Whether `conversationCreated` has been seen (§6.6 row 5).
    ///
    /// Stored rather than derived because it genuinely is not derivable: a
    /// genesis carrying a nil title with no messages yet is indistinguishable
    /// from no genesis at all. Without it, resuming a snapshot of a
    /// *genesis-less* log — which the hostile corpus contains, and which P3
    /// snapshots at randomized points — would start accepting events that a
    /// replay from sequence 1 quarantines as `beforeGenesis`. P3 demands exact
    /// equivalence including diagnostics, so the flag is the price of that.
    var hasGenesis: Bool

    init(
        id: ConversationID,
        title: String? = nil,
        instructions: String? = nil,
        messages: [MessageID: FoldedMessage] = [:],
        rootChildren: [MessageID] = [],
        activePath: [MessageID] = [],
        diagnostics: [QuarantinedEvent] = [],
        hasGenesis: Bool = false
    ) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.messages = messages
        self.rootChildren = rootChildren
        self.activePath = activePath
        self.diagnostics = diagnostics
        self.hasGenesis = hasGenesis
    }

    /// The starting point for a fold from genesis.
    ///
    /// Folding a whole log is `fold(resuming: .empty(id), with: log)` — the
    /// degenerate case of resuming, deliberately, so there is only ever one
    /// reduction path to get wrong (SPEC §9: the snapshot fast-path shipped
    /// untested in rev 3, and P3 exists because of it).
    static func empty(_ id: ConversationID) -> Self {
        Self(id: id)
    }

    /// The current path endpoint — what auto-extend compares a new node's parent
    /// against (§6.4). `nil` means the virtual root, which is what makes the
    /// first root-level message a plain auto-extend rather than a special case.
    var endpoint: MessageID? {
        activePath.last
    }
}

/// One node of the message tree in folded form (SPEC §6.2 / §6.3).
struct FoldedMessage: Sendable, Equatable, Codable {
    var id: MessageID
    var role: Role
    /// Assistant only — I7 binds this 1:1 with `id`.
    ///
    /// Load-bearing for snapshot resume, not merely informational: the fold
    /// routes `deltaAppended` by `GenerationID`, so without this field the
    /// generation→message map would be unreconstructible from a snapshot and
    /// the first delta after a mid-generation checkpoint would quarantine under
    /// row 9. That divergence between replay and resume is precisely what P3
    /// asserts against.
    var generationID: GenerationID?
    /// `nil` ⇒ root-level (child of the virtual root, I6).
    var parent: MessageID?
    /// Sibling order = sequence order (§6.4).
    var children: [MessageID]
    var state: FoldedMessageState
    /// Assistant only — the *requested* descriptor from `generationStarted` (§7.8).
    var model: ModelDescriptor?
    /// Assistant only — from `Outcome.completed` (§7.7); nil otherwise.
    var stopInfo: StopInfo?
    /// Assistant only; sequence order.
    var toolRecords: [ToolRecord]
    /// The originating event's envelope timestamp. Display/audit only.
    var timestamp: Date
    /// The terminal event's envelope timestamp; nil while open (no terminal
    /// exists yet — I5).
    var terminalTimestamp: Date?

    init(
        id: MessageID,
        role: Role,
        generationID: GenerationID? = nil,
        parent: MessageID? = nil,
        children: [MessageID] = [],
        state: FoldedMessageState,
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

/// The message lifecycle as a **fold** sees it (SPEC §6.3) — four cases where
/// the public `MessageState` has five.
///
/// Two public cases are absent, and their absence is load-bearing:
///
/// - **No `.interrupted`.** Interruption is a finalization-time claim (I5): an
///   intermediate fold has not finished reading the log, so it has not earned
///   the conclusion that the generation crashed. `classify` makes it.
/// - **No `.streaming`.** No fold of any log can yield it — a log cannot know
///   the process is alive. Liveness is store state, applied by `overlay_live`
///   on the projection side (§7.4).
///
/// `.open` is what both of those *look like* to a pure fold: started, not
/// terminated, and making no claim about why. Reading the progression
/// `.open → .interrupted → .streaming` backwards is the whole recovery story —
/// on relaunch the overlay is vacuously empty, so the fold's honest "no terminal
/// exists" shows through.
///
/// No `Recoverability` either: it is derived at classification time and stored
/// nowhere, so mapping fixes retroactively upgrade historical failures (§8).
enum FoldedMessageState: Sendable, Equatable, Codable {
    case complete(Content)
    /// Started, not terminated. **Not** a claim about why.
    case open(partial: String)
    case failed(partial: String, GenerationError)
    case cancelled(partial: String)
}

extension FoldedMessageState {

    /// Text accumulated so far, whatever the state — the partial for open and
    /// non-completed terminals, the completed text otherwise.
    var text: String {
        switch self {
        case .complete(let content): content.text
        case .open(let partial), .failed(let partial, _), .cancelled(let partial): partial
        }
    }

    /// Whether a generation is still accepting deltas and tool records (I4).
    var isOpen: Bool {
        if case .open = self { true } else { false }
    }
}

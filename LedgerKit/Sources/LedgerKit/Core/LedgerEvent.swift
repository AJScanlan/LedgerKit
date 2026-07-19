import Foundation

/// One fact in a conversation's append-only log (SPEC §6.1).
///
/// `id` / `conversationID` / `sequence` / `timestamp` are the **envelope** —
/// bookkeeping about the fact; `payload` is the fact. `sequence` is the sole
/// authoritative order, assigned by the store inside the append transaction,
/// contiguous from 1 per conversation. The reducer never orders by `id` or
/// `timestamp` — that would smuggle wall-clock into I1.
///
/// `LedgerEvent` is deliberately **not** `Codable`. The wire blob is the
/// nested ``Record``, which omits `sequence`: sequence physically lives only
/// in the events-table key (SPEC §9), and the envelope is assembled from the
/// column at load via ``init(record:sequence:)`` — so a blob/column
/// disagreement is unrepresentable by construction, not by check.
public struct LedgerEvent: Sendable, Identifiable, Equatable {

    /// The fact itself. Exactly ten kinds — every kind is wire format forever
    /// (SPEC §6.1); resist adding more in v0.1.
    ///
    /// Wire form (ADR-001): a flat tagged-JSON object with a `"kind"`
    /// discriminator beside the payload fields. Unknown discriminators throw
    /// on decode — the reducer quarantines them (SPEC §6.6 row 2) — with one
    /// deliberate exception: a `generationEnded` whose nested outcome does not
    /// decode still lands as a terminal, `.failed(.unrecognized)` (row 3).
    /// Terminals are the only events whose *absence* carries meaning (I5), so
    /// they alone get the tolerance.
    public enum Payload: Sendable, Equatable {
        case conversationCreated(title: String?)
        case userMessageAppended(MessageID, content: String, parent: MessageID?)
        /// `nil` clears (SPEC §7.1).
        case instructionsChanged(String?)
        /// `parent: nil` ⇒ child of the virtual root (I6). The v0.1 store
        /// never emits nil — wire headroom for N10. `model` is the
        /// *requested* descriptor (SPEC §7.8).
        case generationStarted(GenerationID, MessageID, parent: MessageID?, model: ModelDescriptor)
        case deltaAppended(GenerationID, text: String)
        case toolInvocationRecorded(GenerationID, ToolRecord)
        case generationEnded(GenerationID, Outcome)
        /// User messages only — an edit naming an assistant message
        /// quarantines (SPEC §6.1, §6.6 row 11).
        case messageEdited(original: MessageID, replacement: MessageID, content: String)
        case activePathChanged(endpoint: MessageID)
        /// `nil` clears — symmetric with instructions.
        case titleChanged(String?)
    }

    /// The Codable wire blob: everything except `sequence` (SPEC §9).
    ///
    /// This is what the store encodes into the events table and what fixtures
    /// contain. `conversationID` is deliberately duplicated between this blob
    /// and the store's column — that duplication is exactly what §6.6 row 4
    /// (cross-stream contamination) checks.
    public struct Record: Sendable, Codable, Equatable {
        public let id: EventID
        public let conversationID: ConversationID
        /// Stamped by the store at append; display/audit only — the reducer
        /// never reads it. Wire form: ISO 8601, millisecond precision.
        public let timestamp: Date
        public let payload: Payload

        public init(id: EventID, conversationID: ConversationID, timestamp: Date, payload: Payload) {
            self.id = id
            self.conversationID = conversationID
            self.timestamp = timestamp
            self.payload = payload
        }

        private enum CodingKeys: String, CodingKey {
            case id, conversationID, timestamp, payload
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(EventID.self, forKey: .id)
            self.conversationID = try container.decode(ConversationID.self, forKey: .conversationID)
            self.payload = try container.decode(Payload.self, forKey: .payload)
            let raw = try container.decode(String.self, forKey: .timestamp)
            guard let date = WireDate.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timestamp, in: container,
                    debugDescription: "not an ISO 8601 timestamp: \(raw)"
                )
            }
            self.timestamp = date
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(WireDate.string(from: timestamp), forKey: .timestamp)
            try container.encode(payload, forKey: .payload)
        }
    }

    public let id: EventID
    public let conversationID: ConversationID
    /// Per-conversation monotonic — THE order. `Int64`, not `UInt64`:
    /// SQLite INTEGER is i64 and JSON tooling degrades past 2^53.
    public let sequence: Int64
    public let timestamp: Date
    public let payload: Payload

    /// The event's wire blob — what the store persists alongside the
    /// `(conversation_id, sequence)` key.
    public var record: Record {
        Record(id: id, conversationID: conversationID, timestamp: timestamp, payload: payload)
    }

    /// Assembles a full envelope from a loaded blob plus the sequence read
    /// from the events-table key (SPEC §9).
    public init(record: Record, sequence: Int64) {
        self.id = record.id
        self.conversationID = record.conversationID
        self.sequence = sequence
        self.timestamp = record.timestamp
        self.payload = record.payload
    }
}

// MARK: - Payload wire coding (ADR-001)

extension LedgerEvent.Payload: Codable {

    /// The discriminator registry (ADR-001): tags are never reused; removed
    /// tags stay reserved forever.
    private enum Kind: String {
        case conversationCreated
        case userMessageAppended
        case instructionsChanged
        case generationStarted
        case deltaAppended
        case toolInvocationRecorded
        case generationEnded
        case messageEdited
        case activePathChanged
        case titleChanged
    }

    /// Union of all field keys across kinds. `kind` is reserved and may never
    /// be used as a payload field name.
    private enum CodingKeys: String, CodingKey {
        case kind
        case title, messageID, content, parent, instructions
        case generationID, model, text, record, outcome
        case original, replacement, endpoint
    }

    /// Reads only the discriminator of an otherwise-undecodable outcome, for
    /// the tolerant-terminal diagnostic message (SPEC §6.6 row 3).
    private struct TagProbe: Decodable {
        var kind: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown payload kind: \(rawKind)"
            )
        }
        switch kind {
        case .conversationCreated:
            self = .conversationCreated(title: try container.decodeIfPresent(String.self, forKey: .title))
        case .userMessageAppended:
            self = .userMessageAppended(
                try container.decode(MessageID.self, forKey: .messageID),
                content: try container.decode(String.self, forKey: .content),
                parent: try container.decodeIfPresent(MessageID.self, forKey: .parent)
            )
        case .instructionsChanged:
            self = .instructionsChanged(try container.decodeIfPresent(String.self, forKey: .instructions))
        case .generationStarted:
            self = .generationStarted(
                try container.decode(GenerationID.self, forKey: .generationID),
                try container.decode(MessageID.self, forKey: .messageID),
                parent: try container.decodeIfPresent(MessageID.self, forKey: .parent),
                model: try container.decode(ModelDescriptor.self, forKey: .model)
            )
        case .deltaAppended:
            self = .deltaAppended(
                try container.decode(GenerationID.self, forKey: .generationID),
                text: try container.decode(String.self, forKey: .text)
            )
        case .toolInvocationRecorded:
            self = .toolInvocationRecorded(
                try container.decode(GenerationID.self, forKey: .generationID),
                try container.decode(ToolRecord.self, forKey: .record)
            )
        case .generationEnded:
            // Tolerant-terminal rule (SPEC §6.1, §6.6 row 3): if the
            // generation is identifiable, an undecodable outcome must still
            // land as a terminal — a lost terminal is not contained loss; it
            // would forge `.interrupted` (I5).
            let generationID = try container.decode(GenerationID.self, forKey: .generationID)
            let outcome: Outcome
            do {
                outcome = try container.decode(Outcome.self, forKey: .outcome)
            } catch {
                let tag: String
                if !container.contains(.outcome) {
                    tag = "<missing>"
                } else if let probed = (try? container.decode(TagProbe.self, forKey: .outcome))?.kind {
                    tag = probed
                } else {
                    tag = "<unreadable>"
                }
                outcome = .failed(.unrecognized(description: "undecodable outcome: \(tag)"))
            }
            self = .generationEnded(generationID, outcome)
        case .messageEdited:
            self = .messageEdited(
                original: try container.decode(MessageID.self, forKey: .original),
                replacement: try container.decode(MessageID.self, forKey: .replacement),
                content: try container.decode(String.self, forKey: .content)
            )
        case .activePathChanged:
            self = .activePathChanged(endpoint: try container.decode(MessageID.self, forKey: .endpoint))
        case .titleChanged:
            self = .titleChanged(try container.decodeIfPresent(String.self, forKey: .title))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .conversationCreated(let title):
            try container.encode(Kind.conversationCreated.rawValue, forKey: .kind)
            try container.encodeIfPresent(title, forKey: .title)
        case .userMessageAppended(let messageID, let content, let parent):
            try container.encode(Kind.userMessageAppended.rawValue, forKey: .kind)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(parent, forKey: .parent)
        case .instructionsChanged(let instructions):
            try container.encode(Kind.instructionsChanged.rawValue, forKey: .kind)
            try container.encodeIfPresent(instructions, forKey: .instructions)
        case .generationStarted(let generationID, let messageID, let parent, let model):
            try container.encode(Kind.generationStarted.rawValue, forKey: .kind)
            try container.encode(generationID, forKey: .generationID)
            try container.encode(messageID, forKey: .messageID)
            try container.encodeIfPresent(parent, forKey: .parent)
            try container.encode(model, forKey: .model)
        case .deltaAppended(let generationID, let text):
            try container.encode(Kind.deltaAppended.rawValue, forKey: .kind)
            try container.encode(generationID, forKey: .generationID)
            try container.encode(text, forKey: .text)
        case .toolInvocationRecorded(let generationID, let record):
            try container.encode(Kind.toolInvocationRecorded.rawValue, forKey: .kind)
            try container.encode(generationID, forKey: .generationID)
            try container.encode(record, forKey: .record)
        case .generationEnded(let generationID, let outcome):
            try container.encode(Kind.generationEnded.rawValue, forKey: .kind)
            try container.encode(generationID, forKey: .generationID)
            try container.encode(outcome, forKey: .outcome)
        case .messageEdited(let original, let replacement, let content):
            try container.encode(Kind.messageEdited.rawValue, forKey: .kind)
            try container.encode(original, forKey: .original)
            try container.encode(replacement, forKey: .replacement)
            try container.encode(content, forKey: .content)
        case .activePathChanged(let endpoint):
            try container.encode(Kind.activePathChanged.rawValue, forKey: .kind)
            try container.encode(endpoint, forKey: .endpoint)
        case .titleChanged(let title):
            try container.encode(Kind.titleChanged.rawValue, forKey: .kind)
            try container.encodeIfPresent(title, forKey: .title)
        }
    }
}

import Foundation
@testable import LedgerKit

// Shared reducer test harness. Internal rather than file-private because the
// fold, classify and (at M3) corpus suites all build logs the same way, and a
// second copy of this would be a second thing to drift.

/// Deterministic identifiers — fixtures must mint identical bytes every run
/// (SPEC §10.2), and readable low digits make failure messages legible.
func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "01980E5A-0000-7000-8000-%012X", n))!
}

enum Fix {
    static let conversation = ConversationID(uuid(1))
    static let foreign = ConversationID(uuid(2))

    static let userA = MessageID(uuid(0x10))
    static let userB = MessageID(uuid(0x11))
    static let userC = MessageID(uuid(0x12))
    static let edited = MessageID(uuid(0x18))

    static let assistantA = MessageID(uuid(0x20))
    static let assistantB = MessageID(uuid(0x21))

    static let genA = GenerationID(uuid(0x30))
    static let genB = GenerationID(uuid(0x31))
    static let genGhost = GenerationID(uuid(0x3F))

    static let model = ModelDescriptor(provider: "apple", model: "on-device", version: "27.0")
    static let stopInfo = StopInfo(
        stopReason: "endTurn",
        usage: TokenUsage(inputTokens: 12, outputTokens: 8),
        resolvedModelID: "on-device-27.0.1"
    )
}

/// Builds a log with contiguous sequences, so tests state intent rather than
/// bookkeeping. `skip` and `undecodable` punch the two kinds of hole the spec
/// distinguishes: an absent row (a gap) and a present-but-unreadable one.
struct Log {
    static let base = Date(timeIntervalSince1970: 1_784_979_000)

    let conversation: ConversationID
    private(set) var rows: [LoadedEvent] = []
    private var nextSequence: Int64 = 1
    private var nextEventNumber = 0x100

    init(_ conversation: ConversationID = Fix.conversation) {
        self.conversation = conversation
    }

    /// Genesis already applied — the opening every non-genesis test shares.
    static func opened(title: String? = nil) -> Log {
        var log = Log()
        log.append(.conversationCreated(title: title))
        return log
    }

    /// Genesis, one root user message, path sitting on it.
    static func withUserMessage() -> Log {
        var log = Log.opened()
        log.append(.userMessageAppended(Fix.userA, content: "Explain valley folds", parent: nil))
        return log
    }

    /// Genesis, a user message, and a completed generation beneath it — the
    /// ordinary turn, and the shape most classify tests want.
    static func withCompletedTurn() -> Log {
        var log = Log.withUserMessage()
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(Fix.genA, text: "A valley fold"))
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))
        return log
    }

    var lastSequence: Int64 { nextSequence - 1 }

    @discardableResult
    mutating func append(
        _ payload: LedgerEvent.Payload,
        from stream: ConversationID? = nil,
        reusingEventID: EventID? = nil
    ) -> Int64 {
        let sequence = nextSequence
        nextSequence += 1
        nextEventNumber += 1
        let record = LedgerEvent.Record(
            id: reusingEventID ?? EventID(uuid(nextEventNumber)),
            conversationID: stream ?? conversation,
            timestamp: Log.base.addingTimeInterval(Double(sequence)),
            payload: payload
        )
        rows.append(.decoded(LedgerEvent(record: record, sequence: sequence)))
        return sequence
    }

    /// Appends the payload a *decoder* produces for this raw wire JSON.
    ///
    /// The only way to reach the tolerant-terminal rule (§6.6 row 3) from a
    /// fold: that rule lives in `Payload.init(from:)`, so a hand-constructed
    /// `.generationEnded(…, .failed(.unrecognized(…)))` would assert what the
    /// test itself typed rather than what the decoder decided. Composing the
    /// real decoder with the real fold is the whole point.
    @discardableResult
    mutating func appendDecoded(_ payloadJSON: String) throws -> Int64 {
        let payload = try JSONDecoder().decode(LedgerEvent.Payload.self, from: Data(payloadJSON.utf8))
        return append(payload)
    }

    /// The `EventID` minted for the row at `sequence`, for fixtures that need
    /// two rows to collide (the duplicate-`EventID` non-rule, §6.6).
    func eventID(at sequence: Int64) -> EventID? {
        rows.first { $0.sequence == sequence }?.eventID
    }

    /// Leaves `count` sequence numbers unused — an interior gap (§6.1).
    mutating func skip(_ count: Int64) {
        nextSequence += count
    }

    mutating func undecodable(_ failure: LoadedEvent.DecodeFailure, identified: Bool = true) {
        let sequence = nextSequence
        nextSequence += 1
        nextEventNumber += 1
        rows.append(
            .undecodable(
                sequence: sequence,
                eventID: identified ? EventID(uuid(nextEventNumber)) : nil,
                failure
            )
        )
    }

    func folded() -> FoldedState { fold(rows, for: conversation) }

    func reduced(mapping: RecoverabilityMapping = .default) -> Conversation {
        Conversation(reducing: rows, loadedFrom: conversation, mapping: mapping)
    }

    func timestamp(at sequence: Int64) -> Date { Log.base.addingTimeInterval(Double(sequence)) }
}

extension FoldedState {
    var reasons: [QuarantineReason] { diagnostics.map(\.reason) }
}

extension Conversation {
    var reasons: [QuarantineReason] { diagnostics.map(\.reason) }
}

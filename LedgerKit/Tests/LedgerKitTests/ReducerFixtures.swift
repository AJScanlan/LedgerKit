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
    static let assistantC = MessageID(uuid(0x22))

    static let genA = GenerationID(uuid(0x30))
    static let genB = GenerationID(uuid(0x31))
    static let genC = GenerationID(uuid(0x32))
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
    /// Bytes for rows built from raw JSON, keyed by sequence — what lets those
    /// rows have an on-disk form identical to what produced them.
    private var rawBytes: [Int64: String] = [:]

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

    /// Hands the fold a *loader outcome* directly, synthesizing it.
    ///
    /// Legitimate for fold-level unit tests: the fold's contract is to turn a
    /// `LoadedEvent.undecodable` into a diagnostic, and where the value came from
    /// is none of its business. **Not** for corpus fixtures — a synthesized row
    /// has no honest on-disk form, because writing one would freeze the fixture
    /// against a test-side guess at what the real loader produces. Those use
    /// ``unknownPayloadKind(_:)`` / ``corruptRow(_:)`` below, which go through the
    /// production loader instead (M4 Phase 2; the drift ADR-003 rule 2 forbids).
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

    // MARK: Rows built from bytes (M4 Phase 2)

    /// A row carrying a payload kind this version does not know — §6.6 row 2, the
    /// forward-compatibility row — **as bytes, decoded by the production loader.**
    ///
    /// The envelope is well-formed and minted exactly like every other row, which
    /// is the point: the loader recovers identity from it, so the diagnostic
    /// carries an `EventID`. That is the property two-stage decode exists for, and
    /// deriving it from bytes rather than asserting it about a synthesized value
    /// is what makes the claim mean anything.
    @discardableResult
    mutating func unknownPayloadKind(_ kind: String) -> Int64 {
        nextEventNumber += 1
        let id = EventID(uuid(nextEventNumber))
        return appendRaw("""
            {"id":"\(id)","conversationID":"\(conversation)",\
            "timestamp":"\(WireDate.string(from: timestamp(at: nextSequence)))",\
            "payload":{"kind":"\(kind)"}}
            """)
    }

    /// A row whose bytes are unreadable before any identity can be recovered —
    /// §6.6 row 1, the only row (besides a gap) whose diagnostic has no `EventID`.
    @discardableResult
    mutating func corruptRow(_ json: String = #"{"id":"not-a-uuid"}"#) -> Int64 {
        nextEventNumber += 1
        return appendRaw(json)
    }

    /// Runs `json` through the **production** loader and keeps the bytes, so the
    /// on-disk form of this row is the very bytes that produced the in-memory one.
    /// One source of truth, which is the whole reason this could not exist before
    /// M4.
    @discardableResult
    private mutating func appendRaw(_ json: String) -> Int64 {
        let sequence = nextSequence
        nextSequence += 1
        rawBytes[sequence] = json
        rows.append(
            SQLitePersistenceStore.load(
                sequence: sequence,
                json: Data(json.utf8),
                using: WireJSON.decoder()
            )
        )
        return sequence
    }

    /// The bytes behind a row built by ``unknownPayloadKind(_:)`` or
    /// ``corruptRow(_:)``, if any. Keyed lookup only — iteration is always over
    /// `rows`, which is ordered (the I1 hazard CLAUDE.md warns about).
    func rawJSON(at sequence: Int64) -> String? { rawBytes[sequence] }

    func folded() -> FoldedState { fold(rows, for: conversation) }

    func reduced(mapping: RecoverabilityMapping = .default) -> Conversation {
        Conversation(reducing: rows, loadedFrom: conversation, mapping: mapping)
    }

    func timestamp(at sequence: Int64) -> Date { Log.base.addingTimeInterval(Double(sequence)) }

    /// The decoded rows' wire records — what `PersistenceStore.append` takes, so
    /// the store suites replay the very fixtures the reducer suites fold (M4
    /// handoff 2).
    ///
    /// Undecodable rows have no record *by construction*: they are loader
    /// outcomes, not events anyone could have written. A log containing them
    /// therefore cannot be replayed through the store, which is exactly why the
    /// on-disk corpus reserves a `raw` row form (M3 D5) rather than pretending
    /// such rows can be round-tripped.
    var records: [LedgerEvent.Record] {
        rows.compactMap { row in
            switch row {
            case .decoded(let event): event.record
            case .undecodable: nil
            }
        }
    }

    /// Whether this log can be written through `PersistenceStore.append` and read
    /// back unchanged. Three ways it cannot, each structural rather than a gap in
    /// the store:
    ///
    /// - **A sequence gap.** `append` assigns contiguous sequences inside the
    ///   write transaction, so it cannot reproduce a hole — and must not: a gap
    ///   means partial restore or tampering, never something a writer did.
    /// - **A row built from bytes.** Encoding is total, decoding is not, so the
    ///   typed write path cannot express an unreadable row. That asymmetry is the
    ///   one ADR-003 rule 2 calls principled.
    /// - **A foreign event.** `append` rejects the whole batch, by design — it
    ///   refuses to manufacture the cross-stream contamination §6.6 row 4 exists
    ///   to detect.
    ///
    /// Excluding these is not a weaker test; it is the honest scope of the claim
    /// "a log survives the store", and stating it here keeps the exclusion from
    /// being a hard-coded list of fixture names that silently goes stale.
    var isStoreReplayable: Bool {
        // Enumerated rather than compared against `Array(1...count)`: that range
        // traps for an empty log, and `empty` is a fixture. A trapping helper is
        // worse than a failing one — it takes the whole test process down and
        // reports as a signal rather than as an expectation.
        rows.enumerated().allSatisfy { offset, row in
            guard case .decoded(let event) = row else { return false }
            return event.sequence == Int64(offset + 1) && event.conversationID == conversation
        }
    }

    /// Timestamps are minted on whole seconds, so every fixture record is born
    /// canonical (ADR-001 R-5) and satisfies `append`'s debug assertion. Pinned
    /// as a test rather than left as a happy accident — see
    /// `PersistenceAppendTests`.
    var timestampsAreCanonical: Bool {
        records.allSatisfy { WireDate.canonical($0.timestamp) == $0.timestamp }
    }
}

extension FoldedState {
    var reasons: [QuarantineReason] { diagnostics.map(\.reason) }
}

extension Conversation {
    var reasons: [QuarantineReason] { diagnostics.map(\.reason) }
}

import Foundation
import Testing
@testable import LedgerKit

// MARK: - Fixtures

private enum Fix {
    static let eventID = EventID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000A")!)
    static let conversationID = ConversationID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000B")!)
    static let messageID = MessageID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000C")!)
    static let parentID = MessageID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000D")!)
    static let generationID = GenerationID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000E")!)

    static let model = ModelDescriptor(provider: "apple", model: "on-device", version: "27.0")

    static let stopInfo = StopInfo(
        stopReason: "endTurn",
        usage: TokenUsage(inputTokens: 120, outputTokens: 80, cachedInputTokens: 40, reasoningTokens: 12),
        resolvedModelID: "on-device-27.0.1"
    )

    static let toolRecord = ToolRecord(
        name: "search",
        status: .succeeded,
        duration: .milliseconds(847),
        argumentsJSON: #"{"q":"folds"}"#,
        resultJSON: "{}"
    )

    /// One of every payload kind, with associated values populated.
    static let allKinds: [LedgerEvent.Payload] = [
        .conversationCreated(title: "Valley folds 101"),
        .userMessageAppended(messageID, content: "Explain valley folds", parent: parentID),
        .instructionsChanged("You are an origami tutor."),
        .generationStarted(generationID, messageID, parent: parentID, model: model),
        .deltaAppended(generationID, text: "A valley fold is"),
        .toolInvocationRecorded(generationID, toolRecord),
        .generationEnded(generationID, .completed(stopInfo)),
        .messageEdited(original: messageID, replacement: parentID, content: "Explain mountain folds"),
        .activePathChanged(endpoint: messageID),
        .titleChanged("Valley folds 101"),
    ]

    /// Every optional-carrying kind with the optionals nil — nils must be
    /// omitted on the wire and restored on decode.
    static let nilVariants: [LedgerEvent.Payload] = [
        .conversationCreated(title: nil),
        .userMessageAppended(messageID, content: "First message", parent: nil),
        .instructionsChanged(nil),
        .generationStarted(generationID, messageID, parent: nil, model: model),
        .generationEnded(generationID, .failed(.rateLimited(retryAfter: nil))),
        .titleChanged(nil),
    ]

    static let allErrors: [GenerationError] = [
        .modelUnavailable(.deviceNotEligible),
        .modelUnavailable(.appleIntelligenceNotEnabled),
        .modelUnavailable(.modelNotReady),
        .contextWindowExceeded,
        .guardrailViolation,
        .rateLimited(retryAfter: .seconds(30)),
        .rateLimited(retryAfter: nil),
        .providerFailure(status: 500, code: "overloaded_error", message: "Overloaded"),
        .providerFailure(status: nil, code: nil, message: nil),
        .transport(.timeout),
        .transport(.connectivity),
        .transport(.tls),
        .unrecognized(description: "mystery"),
    ]
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func decodePayload(_ json: String) throws -> LedgerEvent.Payload {
    try JSONDecoder().decode(LedgerEvent.Payload.self, from: Data(json.utf8))
}

// MARK: - Round-trips

@Suite("Wire round-trips")
struct WireRoundTripTests {
    @Test("every payload kind", arguments: Fix.allKinds)
    func payloadRoundTrips(_ payload: LedgerEvent.Payload) throws {
        #expect(try roundTrip(payload) == payload)
    }

    @Test("nil optionals are omitted and restored", arguments: Fix.nilVariants)
    func nilVariantRoundTrips(_ payload: LedgerEvent.Payload) throws {
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("null"), "nil must be absent, not null: \(json)")
        #expect(try roundTrip(payload) == payload)
    }

    @Test("every GenerationError case", arguments: Fix.allErrors)
    func errorRoundTrips(_ error: GenerationError) throws {
        #expect(try roundTrip(error) == error)
    }

    @Test("all Outcome cases")
    func outcomeRoundTrips() throws {
        for outcome: Outcome in [.completed(Fix.stopInfo), .completed(StopInfo()), .failed(.guardrailViolation), .cancelled] {
            #expect(try roundTrip(outcome) == outcome)
        }
    }

    @Test("ToolRecord duration is integer milliseconds on the wire")
    func toolRecordDuration() throws {
        let data = try JSONEncoder().encode(Fix.toolRecord)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["duration"] as? Int == 847)
        #expect(try roundTrip(Fix.toolRecord) == Fix.toolRecord)
    }

    @Test("retryAfter is integer milliseconds on the wire")
    func retryAfterMilliseconds() throws {
        let data = try JSONEncoder().encode(GenerationError.rateLimited(retryAfter: .seconds(30)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["retryAfter"] as? Int == 30_000)
    }

    @Test("unknown sibling fields are ignored (additive headroom)")
    func extraFieldsTolerated() throws {
        let payload = try decodePayload(
            #"{"kind":"deltaAppended","generationID":"01980E5A-0000-7000-8000-00000000000E","text":"hi","mood":"jaunty"}"#
        )
        #expect(payload == .deltaAppended(Fix.generationID, text: "hi"))
    }
}

// MARK: - Envelope

@Suite("Envelope")
struct EnvelopeTests {
    private static let timestamp: Date = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: "2026-07-18T09:30:00.000Z")!
    }()

    private var record: LedgerEvent.Record {
        LedgerEvent.Record(
            id: Fix.eventID,
            conversationID: Fix.conversationID,
            timestamp: Self.timestamp,
            payload: .userMessageAppended(Fix.messageID, content: "Explain valley folds", parent: nil)
        )
    }

    @Test("Record round-trips")
    func recordRoundTrips() throws {
        #expect(try roundTrip(record) == record)
    }

    @Test("exact wire JSON — the blob omits sequence, timestamps are ISO 8601")
    func pinnedJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(record), as: UTF8.self)
        #expect(json == """
            {"conversationID":"01980E5A-0000-7000-8000-00000000000B",\
            "id":"01980E5A-0000-7000-8000-00000000000A",\
            "payload":{"content":"Explain valley folds",\
            "kind":"userMessageAppended",\
            "messageID":"01980E5A-0000-7000-8000-00000000000C"},\
            "timestamp":"2026-07-18T09:30:00.000Z"}
            """)
    }

    @Test("LedgerEvent assembles from Record + store-owned sequence")
    func eventAssembly() {
        let event = LedgerEvent(record: record, sequence: 42)
        #expect(event.sequence == 42)
        #expect(event.id == Fix.eventID)
        #expect(event.conversationID == Fix.conversationID)
        #expect(event.record == record)
    }

    @Test("timestamps without fractional seconds still decode")
    func plainISOTimestampDecodes() throws {
        let json = """
            {"conversationID":"01980E5A-0000-7000-8000-00000000000B",\
            "id":"01980E5A-0000-7000-8000-00000000000A",\
            "payload":{"kind":"titleChanged"},\
            "timestamp":"2026-07-18T09:30:00Z"}
            """
        let decoded = try JSONDecoder().decode(LedgerEvent.Record.self, from: Data(json.utf8))
        #expect(decoded.timestamp == Self.timestamp)
    }
}

// MARK: - Terminal tolerance (§6.6 row 3) vs. strictness everywhere else

@Suite("Terminal decode tolerance")
struct TerminalToleranceTests {
    @Test("unknown Outcome discriminator lands as failed(.unrecognized), not quarantine")
    func unknownOutcomeKind() throws {
        let payload = try decodePayload(
            #"{"kind":"generationEnded","generationID":"01980E5A-0000-7000-8000-00000000000E","outcome":{"kind":"resolvedOffline","note":"from the future"}}"#
        )
        #expect(payload == .generationEnded(
            Fix.generationID,
            .failed(.unrecognized(description: "undecodable outcome: resolvedOffline"))
        ))
    }

    @Test("unknown nested GenerationError discriminator degrades with its own tag")
    func unknownErrorKind() throws {
        let payload = try decodePayload(
            #"{"kind":"generationEnded","generationID":"01980E5A-0000-7000-8000-00000000000E","outcome":{"kind":"failed","error":{"kind":"quotaExhausted"}}}"#
        )
        #expect(payload == .generationEnded(
            Fix.generationID,
            .failed(.unrecognized(description: "undecodable outcome: quotaExhausted"))
        ))
    }

    @Test("garbage outcome value still lands as a terminal")
    func garbageOutcome() throws {
        let payload = try decodePayload(
            #"{"kind":"generationEnded","generationID":"01980E5A-0000-7000-8000-00000000000E","outcome":42}"#
        )
        #expect(payload == .generationEnded(
            Fix.generationID,
            .failed(.unrecognized(description: "undecodable outcome: <unreadable>"))
        ))
    }

    @Test("missing outcome still lands as a terminal")
    func missingOutcome() throws {
        let payload = try decodePayload(
            #"{"kind":"generationEnded","generationID":"01980E5A-0000-7000-8000-00000000000E"}"#
        )
        #expect(payload == .generationEnded(
            Fix.generationID,
            .failed(.unrecognized(description: "undecodable outcome: <missing>"))
        ))
    }

    @Test("unknown payload discriminator throws — quarantine is the reducer's job")
    func unknownPayloadKindThrows() {
        #expect(throws: DecodingError.self) {
            try decodePayload(#"{"kind":"messagePinned","messageID":"01980E5A-0000-7000-8000-00000000000C"}"#)
        }
    }

    @Test("non-terminal payloads stay strict: unknown ToolRecord.Status throws")
    func unknownToolStatusThrows() {
        #expect(throws: DecodingError.self) {
            try decodePayload(
                #"{"kind":"toolInvocationRecorded","generationID":"01980E5A-0000-7000-8000-00000000000E","record":{"name":"search","status":"deferred"}}"#
            )
        }
    }
}

// MARK: - Deliberate non-conformances

@Suite("No persistence path")
struct NoPersistencePathTests {
    @Test("Recoverability is not Codable — derived, never persisted (§8)")
    func recoverabilityNotCodable() {
        let value: Any = Recoverability.terminal
        #expect(!(value is any Encodable))
        #expect(!(value is any Decodable))
    }

    @Test("MessageState is not Codable — .interrupted and .streaming are derived-only (§6.2)")
    func messageStateNotCodable() {
        let value: Any = MessageState.streaming(partial: "")
        #expect(!(value is any Encodable))
        #expect(!(value is any Decodable))
    }

    @Test("LedgerEvent itself is not Codable — only Record is the wire blob (§9)")
    func ledgerEventNotCodable() {
        let record = LedgerEvent.Record(
            id: Fix.eventID, conversationID: Fix.conversationID,
            timestamp: Date(timeIntervalSince1970: 0), payload: .titleChanged(nil)
        )
        let value: Any = LedgerEvent(record: record, sequence: 1)
        #expect(!(value is any Encodable))
        #expect(!(value is any Decodable))
    }
}

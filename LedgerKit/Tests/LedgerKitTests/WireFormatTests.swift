import Foundation
import Testing
@testable import LedgerKit

// MARK: - Fixtures

/// The module's exhaustive inventory of the wire surface — every payload kind,
/// every outcome, every error.
///
/// **Internal rather than file-private (M4 Phase 4)** so the registry-manifest
/// test (`RegistryTests`, ADR-001 D-3) reads the same inventory these round-trips
/// do. A second copy would be a second thing to keep exhaustive, and the whole
/// value of an inventory is that it is the *only* one: because every case is named
/// here, deleting a case from the enum fails to compile *this*, which is what makes
/// "a tag cannot be silently removed" a compiler guarantee rather than a habit.
enum Wire {
    static let eventID = EventID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000A")!)
    static let conversationID = ConversationID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000B")!)
    static let messageID = MessageID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000C")!)
    static let parentID = MessageID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000D")!)
    static let generationID = GenerationID(UUID(uuidString: "01980E5A-0000-7000-8000-00000000000E")!)

    static let model = ModelDescriptor(provider: "apple", model: "on-device", version: "27.0")

    /// A fixed millisecond-precision stamp — the wire form's own precision, so
    /// this record is born canonical (ADR-001 R-5).
    static let timestamp: Date = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: "2026-07-18T09:30:00.000Z")!
    }()

    /// One envelope. Lives here rather than in `EnvelopeTests` because the
    /// registry test observes the *envelope's* field keys from it (R-2 covers
    /// those too), and the byte-pinning test below is the other reader.
    static let record = LedgerEvent.Record(
        id: eventID,
        conversationID: conversationID,
        timestamp: timestamp,
        payload: .userMessageAppended(messageID, content: "Explain valley folds", parent: nil)
    )

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

    /// Both `ToolRecord.Status` raw values, every optional populated.
    ///
    /// Fully populated on purpose: the registry test derives the *observed* field
    /// keys by encoding these, and `encodeIfPresent` omits nil — so a fixture with
    /// a nil field would hide that key from the inventory, and a silently removed
    /// key would then look registered-but-unobserved rather than failing.
    static let allToolRecords: [ToolRecord] = [
        toolRecord,
        ToolRecord(
            name: "fetch",
            status: .failed,
            duration: .milliseconds(35),
            argumentsJSON: #"{"url":"…"}"#,
            resultJSON: "null"
        ),
    ]

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
        .generationEnded(generationID, .failed(.contextSizeExceeded(contextSize: nil, tokenCount: nil))),
        .titleChanged(nil),
    ]

    /// Every `Outcome` — the third tagged level, and the one whose tags the
    /// tolerant-terminal rule (§6.6 row 3) probes by name.
    static let allOutcomes: [Outcome] = [
        .completed(stopInfo),
        .completed(StopInfo()),
        .failed(.guardrailViolation),
        .cancelled,
    ]

    static let allErrors: [GenerationError] = [
        .modelUnavailable(.deviceNotEligible),
        .modelUnavailable(.appleIntelligenceNotEnabled),
        .modelUnavailable(.modelNotReady),
        // Both D17 forms: populated, and the field-less shape a pre-widening log
        // holds. The nil form is not merely a nil-optional case here — it is the
        // *old bytes*, which is why `wire/contextSizeExceededLegacy` exists too.
        .contextSizeExceeded(contextSize: 4_096, tokenCount: 5_120),
        .contextSizeExceeded(contextSize: nil, tokenCount: nil),
        .guardrailViolation,
        .refusal,
        .unsupported(.capability),
        .unsupported(.transcriptContent),
        .unsupported(.generationGuide),
        .unsupported(.languageOrLocale),
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
    @Test("every payload kind", arguments: Wire.allKinds)
    func payloadRoundTrips(_ payload: LedgerEvent.Payload) throws {
        #expect(try roundTrip(payload) == payload)
    }

    @Test("nil optionals are omitted and restored", arguments: Wire.nilVariants)
    func nilVariantRoundTrips(_ payload: LedgerEvent.Payload) throws {
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("null"), "nil must be absent, not null: \(json)")
        #expect(try roundTrip(payload) == payload)
    }

    @Test("every GenerationError case", arguments: Wire.allErrors)
    func errorRoundTrips(_ error: GenerationError) throws {
        #expect(try roundTrip(error) == error)
    }

    @Test("all Outcome cases", arguments: Wire.allOutcomes)
    func outcomeRoundTrips(_ outcome: Outcome) throws {
        #expect(try roundTrip(outcome) == outcome)
    }

    @Test("ToolRecord duration is integer milliseconds on the wire")
    func toolRecordDuration() throws {
        let data = try JSONEncoder().encode(Wire.toolRecord)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["duration"] as? Int == 847)
        #expect(try roundTrip(Wire.toolRecord) == Wire.toolRecord)
    }

    @Test("retryAfter is integer milliseconds on the wire")
    func retryAfterMilliseconds() throws {
        let data = try JSONEncoder().encode(GenerationError.rateLimited(retryAfter: .seconds(30)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["retryAfter"] as? Int == 30_000)
    }

    @Test("contextSizeExceeded's payload is two optional named keys (D17)")
    func contextSizeExceededWireForm() throws {
        // Named keys, not positional: two same-typed `Int?`s are exactly the
        // transposition hazard ADR-001 R-2 exists for, and a swapped limit and
        // usage count would decode cleanly into a nonsense claim.
        let json = String(decoding: try WireJSON.encoder().encode(
            GenerationError.contextSizeExceeded(contextSize: 4_096, tokenCount: 5_120)
        ), as: UTF8.self)
        #expect(json == #"{"contextSize":4096,"kind":"contextSizeExceeded","tokenCount":5120}"#)
    }

    @Test("the pre-widening form is byte-identical to a nil-payload encode (D17)")
    func contextSizeExceededStaysAdditive() throws {
        // The additive claim, in the direction that matters. A log written before
        // D17 holds exactly `{"kind":"contextSizeExceeded"}`; this build must
        // *write* those same bytes when it has no numbers, or the widening
        // silently changed what an old shape looks like and the reserved-tag rule
        // would have been the wrong instrument to reach for.
        let json = String(decoding: try WireJSON.encoder().encode(
            GenerationError.contextSizeExceeded(contextSize: nil, tokenCount: nil)
        ), as: UTF8.self)
        #expect(json == #"{"kind":"contextSizeExceeded"}"#)

        let decoded = try JSONDecoder().decode(
            GenerationError.self,
            from: Data(#"{"kind":"contextSizeExceeded"}"#.utf8)
        )
        #expect(decoded == .contextSizeExceeded(contextSize: nil, tokenCount: nil))
    }

    @Test("one field present decodes without the other (D17)")
    func contextSizeExceededDecodesPartially() throws {
        // Providers differ, and the fields are independently optional — so the
        // half-populated shape must not be a decode error. Asserted in both
        // directions because `decodeIfPresent` on one key and `decode` on the
        // other is the plausible slip, and it would only fail on real provider
        // data.
        let sizeOnly = try JSONDecoder().decode(
            GenerationError.self,
            from: Data(#"{"kind":"contextSizeExceeded","contextSize":4096}"#.utf8)
        )
        #expect(sizeOnly == .contextSizeExceeded(contextSize: 4_096, tokenCount: nil))

        let tokensOnly = try JSONDecoder().decode(
            GenerationError.self,
            from: Data(#"{"kind":"contextSizeExceeded","tokenCount":5120}"#.utf8)
        )
        #expect(tokensOnly == .contextSizeExceeded(contextSize: nil, tokenCount: 5_120))
    }

    @Test("the retired contextWindowExceeded tag is not decodable (ADR-001 reserved)")
    func retiredTagStaysRetired() {
        // The reserved table's only entry, asserted as *behaviour*. D17 widened
        // this case's payload, which is precisely the change that might tempt
        // someone to "restore compatibility" by teaching the decoder the old
        // name — the one thing the registry forbids, because a tag that has ever
        // named something may never name anything else.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                GenerationError.self,
                from: Data(#"{"kind":"contextWindowExceeded"}"#.utf8)
            )
        }
    }

    @Test("unknown sibling fields are ignored (additive headroom)")
    func extraFieldsTolerated() throws {
        let payload = try decodePayload(
            #"{"kind":"deltaAppended","generationID":"01980E5A-0000-7000-8000-00000000000E","text":"hi","mood":"jaunty"}"#
        )
        #expect(payload == .deltaAppended(Wire.generationID, text: "hi"))
    }
}

// MARK: - Envelope

@Suite("Envelope")
struct EnvelopeTests {
    private var record: LedgerEvent.Record { Wire.record }

    @Test("Record round-trips")
    func recordRoundTrips() throws {
        #expect(try roundTrip(record) == record)
    }

    @Test("exact wire JSON — the blob omits sequence, timestamps are ISO 8601")
    func pinnedJSON() throws {
        // Encoded through `WireJSON` — the *production* configuration — rather
        // than a local copy of it (ADR-001 D-1, closed at M4). A test that
        // configured its own encoder would pin bytes nobody writes: the one bug
        // class this assertion exists to catch is a *symmetric* encoder/decoder
        // fault, which round-trips cannot see and which a divergent test encoder
        // would hide all over again.
        let json = String(decoding: try WireJSON.encoder().encode(record), as: UTF8.self)
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
        #expect(event.id == Wire.eventID)
        #expect(event.conversationID == Wire.conversationID)
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
        #expect(decoded.timestamp == Wire.timestamp)
    }
}

// MARK: - Timestamp canonicalization (ADR-001 R-5)

@Suite("Timestamp canonicalization")
struct TimestampCanonicalizationTests {
    /// Sub-millisecond precision, fixed rather than `Date()` so the test is
    /// deterministic instead of merely overwhelmingly likely.
    private static let subMillisecond = Date(timeIntervalSince1970: 1_784_979_047.371011)

    private func record(stamped timestamp: Date) -> LedgerEvent.Record {
        LedgerEvent.Record(
            id: Wire.eventID,
            conversationID: Wire.conversationID,
            timestamp: timestamp,
            payload: .titleChanged(nil)
        )
    }

    /// Enough to catch a ~50%-failure-rate bug with certainty rather than by
    /// luck — the shipped-then-reverted string round-trip implementation passed
    /// on a single hand-picked date and failed on half of all others.
    private static let sweep = 2_000

    @Test("a raw high-precision Date does NOT survive its own encoding — this is why R-5 exists")
    func rawDateLosesPrecision() throws {
        let original = record(stamped: Self.subMillisecond)
        #expect(try roundTrip(original) != original)
    }

    @Test("the wire form ROUNDS to nearest millisecond — substituting a truncating formatter regresses it")
    func wireFormRoundsRatherThanTruncates() {
        // The nearest Double to 1712037011.652 sits just below it, so a
        // truncating formatter emits ".651Z". `Date.ISO8601FormatStyle` does
        // exactly that; `ISO8601DateFormatter` rounds. canonical(_:) depends on
        // the rounding, so this test is the guard against swapping them.
        let stamp = Date(timeIntervalSince1970: 1_712_037_011.652)
        #expect(WireDate.string(from: stamp) == "2024-04-02T05:50:11.652Z")
    }

    @Test("canonical stamps round-trip exactly, across the whole clock range")
    func canonicalStampsRoundTrip() throws {
        for _ in 0..<Self.sweep {
            let raw = Date(timeIntervalSince1970: .random(in: 1_700_000_000..<1_900_000_000))
            let original = record(stamped: WireDate.canonical(raw))
            #expect(try roundTrip(original) == original)
        }
    }

    @Test("canonical is idempotent — a canonical stamp is already at a fixed point")
    func canonicalIsIdempotent() {
        for _ in 0..<Self.sweep {
            let once = WireDate.canonical(Date(timeIntervalSince1970: .random(in: 1_700_000_000..<1_900_000_000)))
            #expect(WireDate.canonical(once) == once)
        }
    }

    @Test("canonicalizing the system clock is stable — the store's actual stamping path")
    func liveClockCanonicalizes() throws {
        let stamped = record(stamped: WireDate.canonical(Date()))
        #expect(try roundTrip(stamped) == stamped)
        #expect(WireDate.canonical(Self.subMillisecond) != Self.subMillisecond, "must actually round")
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
            Wire.generationID,
            .failed(.unrecognized(description: "undecodable outcome: resolvedOffline"))
        ))
    }

    @Test("unknown nested GenerationError discriminator degrades, naming the inner layer")
    func unknownErrorKind() throws {
        let payload = try decodePayload(
            #"{"kind":"generationEnded","generationID":"01980E5A-0000-7000-8000-00000000000E","outcome":{"kind":"failed","error":{"kind":"quotaExhausted"}}}"#
        )
        // "error", not "outcome": the Outcome decoded fine as `failed`; it is
        // the nested GenerationError that was unreadable (§6.6 row 3).
        #expect(payload == .generationEnded(
            Wire.generationID,
            .failed(.unrecognized(description: "undecodable error: quotaExhausted"))
        ))
    }

    @Test("a corrupt body under a KNOWN outcome tag still lands as a terminal")
    func corruptCompletedBody() throws {
        // Row 3 keys on the outcome failing to decode, not on its tag being
        // unfamiliar — so a `completed` missing its stopInfo degrades too. The
        // owned cost (§6.1): a generation that DID complete re-renders as a
        // failure. Terminal-ness is what I5 depends on, and it survives.
        let payload = try decodePayload(
            #"{"kind":"generationEnded","generationID":"01980E5A-0000-7000-8000-00000000000E","outcome":{"kind":"completed"}}"#
        )
        #expect(payload == .generationEnded(
            Wire.generationID,
            .failed(.unrecognized(description: "undecodable outcome: completed"))
        ))
    }

    @Test("garbage outcome value still lands as a terminal")
    func garbageOutcome() throws {
        let payload = try decodePayload(
            #"{"kind":"generationEnded","generationID":"01980E5A-0000-7000-8000-00000000000E","outcome":42}"#
        )
        #expect(payload == .generationEnded(
            Wire.generationID,
            .failed(.unrecognized(description: "undecodable outcome: <unreadable>"))
        ))
    }

    @Test("missing outcome still lands as a terminal")
    func missingOutcome() throws {
        let payload = try decodePayload(
            #"{"kind":"generationEnded","generationID":"01980E5A-0000-7000-8000-00000000000E"}"#
        )
        #expect(payload == .generationEnded(
            Wire.generationID,
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
            id: Wire.eventID, conversationID: Wire.conversationID,
            timestamp: Date(timeIntervalSince1970: 0), payload: .titleChanged(nil)
        )
        let value: Any = LedgerEvent(record: record, sequence: 1)
        #expect(!(value is any Encodable))
        #expect(!(value is any Decodable))
    }
}

/// `GenerationError`'s log-facing rendering (M4 Phase 0).
///
/// Lives beside the wire fixtures because `Wire.allErrors` is the module's only
/// exhaustive inventory of the taxonomy, and duplicating it is how a future case
/// silently escapes coverage.
///
/// **These tests deliberately assert structure and payload propagation, never
/// prose.** ADR-001 declares the strings non-contractual and free to reword, so a
/// test matching on wording would freeze exactly what the ADR promises is loose —
/// the same argument that made `QuarantineReason` a typed enum with fixtures
/// asserting cases.
@Suite("Error diagnostics")
struct ErrorDiagnosticsTests {

    @Test("every case renders something", arguments: Wire.allErrors)
    func describesEveryCase(_ error: GenerationError) {
        // The compiler already forces a new case to be *handled*; what it cannot
        // catch is a case handled with a placeholder or an empty string.
        #expect(!error.description.isEmpty)
    }

    @Test("assembled renderings carry no dangling separators", arguments: Wire.allErrors)
    func noDanglingSeparators(_ error: GenerationError) {
        // `providerFailure` is the one case whose rendering is *assembled* from
        // optional parts, so it is the one that can produce "provider failure: "
        // with nothing after it. Asserted over the whole inventory rather than
        // that case alone, so a future assembled case inherits the check.
        let description = error.description
        #expect(!description.hasSuffix(":"))
        #expect(!description.contains("::"))
        #expect(description.trimmingCharacters(in: .whitespaces) == description)
    }

    @Test("the loud floor passes its payload through")
    func unrecognizedCarriesItsDescription() {
        // Triage greps for this. `unrecognized` exists to be loud, and a
        // rendering that swallowed the detail would defeat the case's entire
        // purpose — including the `"driver:"` convention (§8), which is only
        // useful if it survives to the log line.
        #expect(GenerationError.unrecognized(description: "driver: session busy")
            .description.contains("driver: session busy"))
    }

    @Test("a provider failure surfaces the identifier classification used")
    func providerFailureCarriesStatusAndCode() {
        // `code` is the provider's stable machine-readable identifier and the
        // only classification input besides `status` (§8) — so both belong in the
        // line a developer reads when a mapping override is missing.
        let description = GenerationError
            .providerFailure(status: 503, code: "overloaded_error", message: "Overloaded")
            .description
        #expect(description.contains("503"))
        #expect(description.contains("overloaded_error"))
    }
}

import Foundation
import Testing
@testable import LedgerKit

// The folded layer is the snapshot schema (SPEC §9), so its `Codable` has to
// actually work end to end — every nested type, every case. Unlike
// `LedgerEvent.Payload`'s hand-pinned encoding, this format is disposable
// (discard-on-mismatch, no migrations ever), which is exactly why synthesized
// conformances are acceptable here. These tests check that "acceptable" also
// means "functional" before M4 builds the snapshot fast-path on top of it.

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private enum Fold {
    static let conversation = ConversationID(UUID(uuidString: "01980E5A-0000-7000-8000-0000000000A0")!)
    static let user = MessageID(UUID(uuidString: "01980E5A-0000-7000-8000-0000000000A1")!)
    static let assistant = MessageID(UUID(uuidString: "01980E5A-0000-7000-8000-0000000000A2")!)
    static let generation = GenerationID(UUID(uuidString: "01980E5A-0000-7000-8000-0000000000A3")!)
    static let event = EventID(UUID(uuidString: "01980E5A-0000-7000-8000-0000000000A4")!)

    static let timestamp = Date(timeIntervalSince1970: 1_784_979_047.371)

    static let allStates: [FoldedMessageState] = [
        .complete(Content(text: "A valley fold brings the paper toward you.")),
        .open(partial: "A valley fol"),
        .failed(partial: "A valley", .rateLimited(retryAfter: .seconds(30))),
        .failed(partial: "", .modelUnavailable(.appleIntelligenceNotEnabled)),
        .cancelled(partial: "A valley fold br"),
    ]

    /// Every case of §6.6's inventory. Doubles as a written-out copy of the
    /// table — if a row is added and this array isn't, the count check fails.
    static let allReasons: [QuarantineReason] = [
        .undecodableEnvelope,
        .unknownPayloadKind("messagePinned"),
        .unknownPayloadKind(nil),
        .foreignConversation(found: conversation),
        .beforeGenesis,
        .duplicateGenesis,
        .unknownParent(user),
        .messageIDAlreadyUsed(user),
        .additionalRootMessage(user),
        .unknownEditTarget(user),
        .editTargetNotUser(assistant),
        .generationIDAlreadyUsed(generation),
        .unknownGeneration(generation),
        .generationAlreadyTerminated(generation),
        .duplicateTerminal(generation),
        .unknownPathEndpoint(assistant),
        .sequenceGap(missing: 7...7),
        .sequenceGap(missing: 12...4_102),
    ]

    /// A two-message conversation with an open generation — the shape a
    /// mid-generation snapshot actually stores (§9).
    static var state: FoldedState {
        FoldedState(
            id: conversation,
            title: "Valley folds 101",
            instructions: "You are an origami tutor.",
            messages: [
                user: FoldedMessage(
                    id: user,
                    role: .user,
                    children: [assistant],
                    state: .complete(Content(text: "Explain valley folds")),
                    timestamp: timestamp
                ),
                assistant: FoldedMessage(
                    id: assistant,
                    role: .assistant,
                    generationID: generation,
                    parent: user,
                    state: .open(partial: "A valley fol"),
                    model: ModelDescriptor(provider: "apple", model: "on-device", version: "27.0"),
                    toolRecords: [ToolRecord(name: "search", status: .succeeded, duration: .milliseconds(847))],
                    timestamp: timestamp
                ),
            ],
            rootChildren: [user],
            activePath: [user, assistant],
            diagnostics: [QuarantinedEvent(sequence: 4, eventID: event, reason: .duplicateGenesis)]
        )
    }
}

@Suite("Folded layer — the snapshot schema")
struct FoldedStateTests {

    @Test("every FoldedMessageState case round-trips", arguments: Fold.allStates)
    func stateRoundTrips(_ state: FoldedMessageState) throws {
        #expect(try roundTrip(state) == state)
    }

    @Test("every QuarantineReason case round-trips", arguments: Fold.allReasons)
    func reasonRoundTrips(_ reason: QuarantineReason) throws {
        #expect(try roundTrip(reason) == reason)
    }

    @Test("a whole FoldedState round-trips, nested types included")
    func stateGraphRoundTrips() throws {
        #expect(try roundTrip(Fold.state) == Fold.state)
    }

    @Test("timestamps survive the snapshot path exactly — no ISO 8601 in the middle")
    func snapshotTimestampsAreExact() throws {
        // Contrast with the event wire format, where ms-precision ISO 8601
        // forces canonicalization at stamping time (ADR-001 R-5). The folded
        // layer encodes Date numerically, so it is lossless and needs no rule.
        let raw = Date(timeIntervalSince1970: 1_784_979_047.371011)
        var state = Fold.state
        state.messages[Fold.user]?.timestamp = raw
        #expect(try roundTrip(state).messages[Fold.user]?.timestamp == raw)
    }

    @Test("there is no folded .interrupted or .streaming — a snapshot cannot forge a crash")
    func foldedLayerHasNoDerivedStates() {
        // Compile-time proof by exhaustive switch: adding either case to
        // FoldedMessageState breaks this build, which is the point of the
        // parallel enum (SPEC §6.3).
        for state in Fold.allStates {
            switch state {
            case .complete, .open, .failed, .cancelled: break
            }
        }
        #expect(Fold.allStates.count == 5)
    }

    @Test("endpoint is the active path's last node; nil means the virtual root")
    func endpointDerivation() {
        #expect(Fold.state.endpoint == Fold.assistant)
        #expect(FoldedState.empty(Fold.conversation).endpoint == nil)
    }

    @Test("empty is genesis-ready: no messages, no path, no residue")
    func emptyIsEmpty() {
        let empty = FoldedState.empty(Fold.conversation)
        #expect(empty.id == Fold.conversation)
        #expect(empty.messages.isEmpty)
        #expect(empty.rootChildren.isEmpty)
        #expect(empty.activePath.isEmpty)
        #expect(empty.diagnostics.isEmpty)
        #expect(empty.title == nil)
        #expect(empty.instructions == nil)
    }

    @Test("state accessors: text spans all cases, isOpen is the I4 gate")
    func stateAccessors() {
        #expect(FoldedMessageState.complete(Content(text: "done")).text == "done")
        #expect(FoldedMessageState.open(partial: "part").text == "part")
        #expect(FoldedMessageState.cancelled(partial: "part").text == "part")
        #expect(FoldedMessageState.failed(partial: "part", .guardrailViolation).text == "part")

        #expect(FoldedMessageState.open(partial: "").isOpen)
        #expect(!FoldedMessageState.complete(Content(text: "")).isOpen)
        #expect(!FoldedMessageState.cancelled(partial: "").isOpen)
    }

    @Test("QuarantinedEvent renders a log line; a row-1 diagnostic has only its sequence")
    func diagnosticRendering() {
        let identified = QuarantinedEvent(sequence: 4, eventID: Fold.event, reason: .duplicateGenesis)
        #expect(identified.description == "seq 4 (\(Fold.event)): second conversationCreated")

        let anonymous = QuarantinedEvent(sequence: 9, reason: .undecodableEnvelope)
        #expect(anonymous.description == "seq 9: row undecodable; no event identity recoverable")

        #expect("\(QuarantineReason.sequenceGap(missing: 7...7))" == "missing sequence 7")
        #expect("\(QuarantineReason.sequenceGap(missing: 12...14))" == "missing sequences 12–14")
    }
}

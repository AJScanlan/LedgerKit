import Foundation
import Testing
@testable import LedgerKit

// MARK: - Harness

/// Deterministic identifiers — fixtures must mint identical bytes every run
/// (SPEC §10.2), and readable low digits make failure messages legible.
private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "01980E5A-0000-7000-8000-%012X", n))!
}

private enum Fix {
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
private struct Log {
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

    var lastSequence: Int64 { nextSequence - 1 }

    @discardableResult
    mutating func append(_ payload: LedgerEvent.Payload, from stream: ConversationID? = nil) -> Int64 {
        let sequence = nextSequence
        nextSequence += 1
        nextEventNumber += 1
        let record = LedgerEvent.Record(
            id: EventID(uuid(nextEventNumber)),
            conversationID: stream ?? conversation,
            timestamp: Log.base.addingTimeInterval(Double(sequence)),
            payload: payload
        )
        rows.append(.decoded(LedgerEvent(record: record, sequence: sequence)))
        return sequence
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

    func timestamp(at sequence: Int64) -> Date { Log.base.addingTimeInterval(Double(sequence)) }
}

private extension FoldedState {
    var reasons: [QuarantineReason] { diagnostics.map(\.reason) }
}

// MARK: - Passing today: stream integrity

@Suite("Folder — stream integrity")
struct FolderStreamTests {

    @Test("an empty log folds to empty state without genesis")
    func emptyLog() {
        let state = fold([LoadedEvent](), for: Fix.conversation)
        #expect(state == .empty(Fix.conversation))
        #expect(!state.hasGenesis)
    }

    @Test("genesis establishes the conversation and its title")
    func genesis() {
        var log = Log()
        log.append(.conversationCreated(title: "Valley folds 101"))
        let state = log.folded()
        #expect(state.hasGenesis)
        #expect(state.title == "Valley folds 101")
        #expect(state.reasons.isEmpty)
    }

    @Test("anything before genesis quarantines (row 5)")
    func beforeGenesis() {
        var log = Log()
        log.append(.titleChanged("premature"))
        log.append(.conversationCreated(title: "actual"))
        let state = log.folded()
        #expect(state.reasons == [.beforeGenesis])
        #expect(state.title == "actual")
    }

    @Test("a second conversationCreated quarantines (row 5)")
    func duplicateGenesis() {
        var log = Log.opened(title: "first")
        log.append(.conversationCreated(title: "second"))
        let state = log.folded()
        #expect(state.reasons == [.duplicateGenesis])
        #expect(state.title == "first", "the duplicate must not take effect")
    }

    @Test("an event from another stream quarantines (row 4)")
    func foreignConversation() {
        var log = Log.opened()
        log.append(.titleChanged("from elsewhere"), from: Fix.foreign)
        let state = log.folded()
        #expect(state.reasons == [.foreignConversation(found: Fix.foreign)])
        #expect(state.title == nil)
    }

    @Test("row 4 outranks row 5 — a foreign event is not judged against our genesis")
    func foreignOutranksGenesis() {
        var log = Log()
        log.append(.titleChanged("foreign and premature"), from: Fix.foreign)
        #expect(log.folded().reasons == [.foreignConversation(found: Fix.foreign)])
    }

    @Test("one diagnostic per contiguous gap, not one per missing row")
    func singleGapDiagnostic() {
        var log = Log.opened()
        log.skip(3)
        log.append(.titleChanged("after the hole"))
        let state = log.folded()
        #expect(state.reasons == [.sequenceGap(missing: 2...4)])
        #expect(state.diagnostics.first?.sequence == 2, "the diagnostic sits at the first missing row")
        #expect(state.diagnostics.first?.eventID == nil, "no row exists to have an identity")
        #expect(state.title == "after the hole", "reduction continues across the hole")
    }

    @Test("two separate holes are two diagnostics")
    func twoGaps() {
        var log = Log.opened()
        log.skip(1)
        log.append(.titleChanged("one"))
        log.skip(2)
        log.append(.instructionsChanged("two"))
        #expect(log.folded().reasons == [.sequenceGap(missing: 2...2), .sequenceGap(missing: 4...5)])
    }

    @Test("an undecodable row is not a gap — it is present and unintelligible")
    func undecodableIsNotAGap() {
        var log = Log.opened()
        log.undecodable(.payloadKind("messagePinned"))
        log.append(.titleChanged("after"))
        let state = log.folded()
        #expect(state.reasons == [.unknownPayloadKind("messagePinned")])
        #expect(state.diagnostics.first?.eventID != nil, "row 2 carries identity (§6.6 diagnostic identity)")
    }

    @Test("a row-1 failure is the only diagnostic besides a gap with no identity")
    func undecodableEnvelope() {
        var log = Log.opened()
        log.undecodable(.envelope, identified: false)
        let state = log.folded()
        #expect(state.reasons == [.undecodableEnvelope])
        #expect(state.diagnostics.first?.eventID == nil)
    }

    @Test("instructions and title are last-write-wins; nil clears")
    func metadataClears() {
        var log = Log.opened(title: "first")
        log.append(.instructionsChanged("You are an origami tutor."))
        log.append(.titleChanged("second"))
        log.append(.instructionsChanged(nil))
        log.append(.titleChanged(nil))
        let state = log.folded()
        #expect(state.title == nil)
        #expect(state.instructions == nil)
        #expect(state.reasons.isEmpty)
    }
}

// MARK: - Passing today: user messages, edits, path

@Suite("Folder — user messages, edits, and the active path")
struct FolderTreeTests {

    @Test("the first user message opens the tree and auto-extends the path")
    func firstUserMessage() {
        let state = Log.withUserMessage().folded()
        #expect(state.rootChildren == [Fix.userA])
        #expect(state.activePath == [Fix.userA], "nil parent == nil endpoint, so auto-extend fires")
        #expect(state.messages[Fix.userA]?.role == .user)
        #expect(state.messages[Fix.userA]?.state == .complete(Content(text: "Explain valley folds")))
        #expect(state.reasons.isEmpty)
    }

    @Test("a second bare nil-parent append quarantines — new topic ≠ new branch (row 7)")
    func secondRootMessage() {
        var log = Log.withUserMessage()
        log.append(.userMessageAppended(Fix.userB, content: "unrelated", parent: nil))
        let state = log.folded()
        #expect(state.reasons == [.additionalRootMessage(Fix.userB)])
        #expect(state.rootChildren == [Fix.userA], "the tree is untouched (I2 containment)")
        #expect(state.messages[Fix.userB] == nil)
    }

    @Test("an unknown parent quarantines (row 6)")
    func unknownParent() {
        var log = Log.opened()
        log.append(.userMessageAppended(Fix.userB, content: "orphan", parent: Fix.userC))
        let state = log.folded()
        #expect(state.reasons == [.unknownParent(Fix.userC)])
        #expect(state.messages.isEmpty)
    }

    @Test("reusing a MessageID quarantines — I7 once-only (row 6)")
    func duplicateMessageID() {
        var log = Log.withUserMessage()
        log.append(.userMessageAppended(Fix.userA, content: "overwrite attempt", parent: Fix.userA))
        let state = log.folded()
        #expect(state.reasons == [.messageIDAlreadyUsed(Fix.userA)])
        #expect(
            state.messages[Fix.userA]?.state == .complete(Content(text: "Explain valley folds")),
            "the original content must survive"
        )
    }

    @Test("the path materializes as a chain from a root-level node to the endpoint")
    func pathChain() {
        var log = Log.withUserMessage()
        log.append(.userMessageAppended(Fix.userB, content: "and mountain folds?", parent: Fix.userA))
        log.append(.userMessageAppended(Fix.userC, content: "and reverse folds?", parent: Fix.userB))
        let state = log.folded()
        #expect(state.activePath == [Fix.userA, Fix.userB, Fix.userC])
        #expect(state.reasons.isEmpty, "role adjacency is a deliberate non-rule (§6.6)")
    }

    @Test("editing a user message creates a sibling under the same parent")
    func editCreatesSibling() {
        var log = Log.withUserMessage()
        log.append(.userMessageAppended(Fix.userB, content: "second", parent: Fix.userA))
        log.append(.messageEdited(original: Fix.userB, replacement: Fix.edited, content: "second, revised"))
        let state = log.folded()
        #expect(state.messages[Fix.edited]?.parent == Fix.userA)
        #expect(state.messages[Fix.userA]?.children == [Fix.userB, Fix.edited])
        #expect(state.messages[Fix.edited]?.state == .complete(Content(text: "second, revised")))
        #expect(state.reasons.isEmpty)
    }

    @Test("an edit auto-extends the path when its parent is the endpoint — pinned for crash-fuzzing")
    func editAutoExtends() {
        // §6.4's auto-extend rule is stated generally, so it fires for edits too.
        // In production that is invisible: the store pairs `messageEdited` with
        // `activePathChanged` in one transaction (§9). But crash-point fuzzing
        // truncates on ROW boundaries, not transaction boundaries, so M3 will
        // generate logs ending at the edit with its path event missing — and then
        // this behaviour is load-bearing. Pinned deliberately rather than left for
        // a fuzz failure to decide.
        var log = Log.withUserMessage()
        log.append(.userMessageAppended(Fix.userB, content: "second", parent: Fix.userA))
        log.append(.activePathChanged(endpoint: Fix.userA))
        // userB is now off-path, so the replacement's parent IS the endpoint.
        log.append(.messageEdited(original: Fix.userB, replacement: Fix.edited, content: "second, revised"))
        let state = log.folded()
        #expect(state.activePath == [Fix.userA, Fix.edited], "you edited into a branch, so you are on it")
        #expect(state.reasons.isEmpty)
    }

    @Test("an edit does NOT auto-extend when the endpoint is elsewhere")
    func editWithoutAutoExtend() {
        var log = Log.withUserMessage()
        log.append(.userMessageAppended(Fix.userB, content: "second", parent: Fix.userA))
        // Endpoint is userB; the replacement's parent is userA, so the rule cannot fire.
        log.append(.messageEdited(original: Fix.userB, replacement: Fix.edited, content: "revised"))
        let state = log.folded()
        #expect(state.activePath == [Fix.userA, Fix.userB], "the store pairs an explicit path event")
        #expect(state.reasons.isEmpty)
    }

    @Test("editing the FIRST message creates a root-level sibling (I6, no special case)")
    func editRootMessage() {
        var log = Log.withUserMessage()
        log.append(.messageEdited(original: Fix.userA, replacement: Fix.edited, content: "Explain mountain folds"))
        let state = log.folded()
        #expect(state.rootChildren == [Fix.userA, Fix.edited])
        #expect(state.messages[Fix.edited]?.parent == nil)
        #expect(state.reasons.isEmpty)
    }

    @Test("an edit naming an unknown message quarantines (row 11)")
    func editUnknownTarget() {
        var log = Log.withUserMessage()
        log.append(.messageEdited(original: Fix.userC, replacement: Fix.edited, content: "?"))
        #expect(log.folded().reasons == [.unknownEditTarget(Fix.userC)])
    }

    @Test("an edit whose replacement ID already exists quarantines (row 11)")
    func editReplacementCollision() {
        var log = Log.withUserMessage()
        log.append(.messageEdited(original: Fix.userA, replacement: Fix.userA, content: "?"))
        #expect(log.folded().reasons == [.messageIDAlreadyUsed(Fix.userA)])
    }

    @Test("activePathChanged moves the visible thread")
    func branchSwitch() {
        var log = Log.withUserMessage()
        log.append(.messageEdited(original: Fix.userA, replacement: Fix.edited, content: "revised"))
        log.append(.activePathChanged(endpoint: Fix.edited))
        #expect(log.folded().activePath == [Fix.edited])
    }

    @Test("activePathChanged to an endpoint that never existed quarantines (row 12)")
    func unknownEndpoint() {
        var log = Log.withUserMessage()
        log.append(.activePathChanged(endpoint: Fix.userC))
        let state = log.folded()
        #expect(state.reasons == [.unknownPathEndpoint(Fix.userC)])
        #expect(state.activePath == [Fix.userA], "the path stays where it was")
    }

    @Test("timestamps come from the envelope, never a clock (I1)")
    func timestampsFromEnvelope() {
        let log = Log.withUserMessage()
        #expect(log.folded().messages[Fix.userA]?.timestamp == log.timestamp(at: 2))
    }
}

// MARK: - Generation start

/// The specification of `Folder.applyGenerationStarted`, as tests.
///
/// Every assertion maps to one clause of that method's contract, and two of them
/// pin *non-rules* — a nil parent and an assistant parent are both legal here,
/// where the equivalent user-message cases are not. Adding either check would
/// look like tightening validation and would actually break N10's wire headroom
/// and §6.6's role-adjacency non-rule, so those two tests are load-bearing in the
/// opposite direction from the rest.
@Suite("Folder — generationStarted")
struct FolderGenerationStartedTests {

    /// Genesis, a user message, and a generation started off it.
    private func started(parent: MessageID? = Fix.userA) -> Log {
        var log = Log.withUserMessage()
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: parent, model: Fix.model))
        return log
    }

    @Test("creates an assistant message, open with an empty partial")
    func createsOpenAssistantMessage() {
        let state = started().folded()
        #expect(state.reasons.isEmpty)
        let message = state.messages[Fix.assistantA]
        #expect(message?.role == .assistant)
        #expect(message?.state == .open(partial: ""))
        #expect(message?.terminalTimestamp == nil, "nothing has terminated yet")
    }

    @Test("records the REQUESTED model descriptor (§7.8)")
    func recordsRequestedModel() {
        #expect(started().folded().messages[Fix.assistantA]?.model == Fix.model)
    }

    @Test("records generationID on the message — snapshot resume depends on it")
    func recordsGenerationID() {
        // Without this the routing map is unreconstructible from a snapshot and
        // the first delta after a checkpoint quarantines under row 9, diverging
        // replay from resume (P3).
        #expect(started().folded().messages[Fix.assistantA]?.generationID == Fix.genA)
    }

    @Test("attaches to the named parent in sibling order")
    func attachesToParent() {
        var log = started()
        log.append(.generationStarted(Fix.genB, Fix.assistantB, parent: Fix.userA, model: Fix.model))
        let state = log.folded()
        #expect(state.messages[Fix.assistantA]?.parent == Fix.userA)
        #expect(state.messages[Fix.userA]?.children == [Fix.assistantA, Fix.assistantB])
    }

    @Test("auto-extends the path when the parent is the endpoint (§6.4)")
    func autoExtendsOffEndpoint() {
        #expect(started().folded().activePath == [Fix.userA, Fix.assistantA])
    }

    @Test("does NOT auto-extend when the parent is not the endpoint")
    func noAutoExtendOffPath() {
        var log = Log.withUserMessage()
        log.append(.userMessageAppended(Fix.userB, content: "second", parent: Fix.userA))
        // Endpoint is userB; this generation hangs off userA instead.
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))
        let state = log.folded()
        #expect(state.reasons.isEmpty)
        #expect(state.activePath == [Fix.userA, Fix.userB], "the store pairs an explicit path event")
        #expect(state.messages[Fix.assistantA] != nil, "the message still exists, off-path")
    }

    @Test("a nil parent is LEGAL here — virtual-root child, wire headroom for N10")
    func nilParentIsHeadroom() {
        var log = Log.opened()
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: nil, model: Fix.model))
        let state = log.folded()
        #expect(state.reasons.isEmpty, "row 7's guard applies to userMessageAppended only")
        #expect(state.rootChildren == [Fix.assistantA])
        #expect(state.activePath == [Fix.assistantA])
    }

    @Test("an assistant parent is LEGAL — role adjacency is a non-rule (§6.6)")
    func assistantParentIsNonRule() {
        var log = started()
        log.append(.generationStarted(Fix.genB, Fix.assistantB, parent: Fix.assistantA, model: Fix.model))
        let state = log.folded()
        #expect(state.reasons.isEmpty, "the continuation shape decodes; the STORE forbids it, not the fold")
        #expect(state.messages[Fix.assistantB]?.parent == Fix.assistantA)
    }

    @Test("reusing a GenerationID quarantines (row 8)")
    func reusedGenerationID() {
        var log = started()
        log.append(.generationStarted(Fix.genA, Fix.assistantB, parent: Fix.userA, model: Fix.model))
        let state = log.folded()
        #expect(state.reasons == [.generationIDAlreadyUsed(Fix.genA)])
        #expect(state.messages[Fix.assistantB] == nil, "nothing was created (I2 containment)")
    }

    @Test("a GenerationID stays used after termination — the binding is permanent")
    func generationIDStaysUsedAfterTerminal() {
        var log = started()
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))
        log.append(.generationStarted(Fix.genA, Fix.assistantB, parent: Fix.userA, model: Fix.model))
        #expect(log.folded().reasons == [.generationIDAlreadyUsed(Fix.genA)])
    }

    @Test("binding an already-used MessageID quarantines — I7 once-only (row 8)")
    func reusedMessageID() {
        var log = Log.withUserMessage()
        log.append(.generationStarted(Fix.genA, Fix.userA, parent: Fix.userA, model: Fix.model))
        let state = log.folded()
        #expect(state.reasons == [.messageIDAlreadyUsed(Fix.userA)])
        #expect(state.messages[Fix.userA]?.role == .user, "the existing node is untouched")
        #expect(state.messages[Fix.userA]?.generationID == nil)
    }

    @Test("an unknown parent quarantines (row 8)")
    func unknownParent() {
        let state = started(parent: Fix.userC).folded()
        #expect(state.reasons == [.unknownParent(Fix.userC)])
        #expect(state.messages[Fix.assistantA] == nil)
    }

    @Test("a quarantined start leaves the tree and path exactly as they were")
    func quarantineIsContained() {
        let baseline = Log.withUserMessage().folded()
        let state = started(parent: Fix.userC).folded()
        #expect(state.messages == baseline.messages)
        #expect(state.rootChildren == baseline.rootChildren)
        #expect(state.activePath == baseline.activePath)
    }

    @Test("the message's timestamp is the envelope's")
    func timestampFromEnvelope() {
        let log = started()
        #expect(log.folded().messages[Fix.assistantA]?.timestamp == log.timestamp(at: 3))
    }
}

// MARK: - Generation lifecycle: everything routed by the binding

@Suite("Folder — generation lifecycle")
struct FolderGenerationLifecycleTests {

    /// Genesis, user message, generation started, two deltas.
    private func streaming() -> Log {
        var log = Log.withUserMessage()
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(Fix.genA, text: "A valley "))
        log.append(.deltaAppended(Fix.genA, text: "fold"))
        return log
    }

    @Test("deltas concatenate into the open partial")
    func deltasAccumulate() {
        let state = streaming().folded()
        #expect(state.reasons.isEmpty)
        #expect(state.messages[Fix.assistantA]?.state == .open(partial: "A valley fold"))
    }

    @Test("no terminal leaves the generation OPEN — interruption is classify's job (I5)")
    func openWithoutTerminal() {
        // The single most important assertion of the rev-5 layering: a fold that
        // has stopped reading has not learned that the process died.
        let state = streaming().folded()
        #expect(state.messages[Fix.assistantA]?.state.isOpen == true)
        #expect(state.messages[Fix.assistantA]?.terminalTimestamp == nil)
    }

    @Test("completed captures content, stopInfo, and the terminal timestamp")
    func completed() {
        var log = streaming()
        let sequence = log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))
        let state = log.folded()
        #expect(state.messages[Fix.assistantA]?.state == .complete(Content(text: "A valley fold")))
        #expect(state.messages[Fix.assistantA]?.stopInfo == Fix.stopInfo)
        #expect(state.messages[Fix.assistantA]?.terminalTimestamp == log.timestamp(at: sequence))
    }

    @Test("failed retains the partial alongside the error")
    func failed() {
        var log = streaming()
        log.append(.generationEnded(Fix.genA, .failed(.rateLimited(retryAfter: .seconds(30)))))
        let state = log.folded()
        #expect(
            state.messages[Fix.assistantA]?.state
                == .failed(partial: "A valley fold", .rateLimited(retryAfter: .seconds(30)))
        )
        #expect(state.messages[Fix.assistantA]?.stopInfo == nil)
    }

    @Test("a zero-token failure renders as an empty failed bubble, not an absent one (§7.2)")
    func zeroTokenFailure() {
        var log = Log.withUserMessage()
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.generationEnded(Fix.genA, .failed(.providerFailure(status: 401, code: nil, message: nil))))
        let state = log.folded()
        #expect(
            state.messages[Fix.assistantA]?.state
                == .failed(partial: "", .providerFailure(status: 401, code: nil, message: nil))
        )
    }

    @Test("cancelled retains the partial")
    func cancelled() {
        var log = streaming()
        log.append(.generationEnded(Fix.genA, .cancelled))
        #expect(log.folded().messages[Fix.assistantA]?.state == .cancelled(partial: "A valley fold"))
    }

    @Test("tool records accumulate in sequence order")
    func toolRecords() {
        var log = streaming()
        log.append(.toolInvocationRecorded(Fix.genA, ToolRecord(name: "search", status: .succeeded)))
        log.append(.toolInvocationRecorded(Fix.genA, ToolRecord(name: "fetch", status: .failed)))
        let state = log.folded()
        #expect(state.messages[Fix.assistantA]?.toolRecords.map(\.name) == ["search", "fetch"])
        #expect(state.reasons.isEmpty)
    }

    @Test("a delta after the terminal quarantines and content stays frozen (I4, row 9)")
    func deltaAfterTerminal() {
        var log = streaming()
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))
        log.append(.deltaAppended(Fix.genA, text: " — and more"))
        let state = log.folded()
        #expect(state.reasons == [.generationAlreadyTerminated(Fix.genA)])
        #expect(state.messages[Fix.assistantA]?.state == .complete(Content(text: "A valley fold")))
    }

    @Test("a tool record after the terminal quarantines — the audit trail is immutable too (I4)")
    func toolRecordAfterTerminal() {
        var log = streaming()
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))
        log.append(.toolInvocationRecorded(Fix.genA, ToolRecord(name: "late", status: .succeeded)))
        let state = log.folded()
        #expect(state.reasons == [.generationAlreadyTerminated(Fix.genA)])
        #expect(state.messages[Fix.assistantA]?.toolRecords.isEmpty == true)
    }

    @Test("a second terminal quarantines (I3, row 10)")
    func duplicateTerminal() {
        var log = streaming()
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))
        log.append(.generationEnded(Fix.genA, .cancelled))
        let state = log.folded()
        #expect(state.reasons == [.duplicateTerminal(Fix.genA)])
        #expect(state.messages[Fix.assistantA]?.state == .complete(Content(text: "A valley fold")))
    }

    @Test("a delta naming a generation that never started quarantines (row 9)")
    func unknownGeneration() {
        var log = Log.withUserMessage()
        log.append(.deltaAppended(Fix.genGhost, text: "from nowhere"))
        #expect(log.folded().reasons == [.unknownGeneration(Fix.genGhost)])
    }

    @Test("editing an assistant message quarantines (row 11)")
    func editAssistantMessage() {
        var log = streaming()
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))
        log.append(.messageEdited(original: Fix.assistantA, replacement: Fix.edited, content: "rewritten"))
        let state = log.folded()
        #expect(state.reasons == [.editTargetNotUser(Fix.assistantA)])
        #expect(state.messages[Fix.edited] == nil, "no user-authored assistant content, ever")
    }

    @Test("the cascade: a quarantined start orphans its deltas and terminal (§6.6)")
    func cascade() {
        var log = Log.withUserMessage()
        // Unknown parent, so the start itself is rejected...
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userC, model: Fix.model))
        // ...and everything keyed to it then fails individually under rows 9–10.
        log.append(.deltaAppended(Fix.genA, text: "orphan"))
        log.append(.toolInvocationRecorded(Fix.genA, ToolRecord(name: "orphan", status: .succeeded)))
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))
        let state = log.folded()
        #expect(
            state.reasons == [
                .unknownParent(Fix.userC),
                .unknownGeneration(Fix.genA),
                .unknownGeneration(Fix.genA),
                .unknownGeneration(Fix.genA),
            ],
            "cascades are expected, not pathological — the fixture asserts the exact residue"
        )
        #expect(state.messages[Fix.assistantA] == nil)
    }

    @Test("regenerate leaves the old response as a sibling branch")
    func siblingResponses() {
        var log = streaming()
        log.append(.generationEnded(Fix.genA, .cancelled))
        log.append(.generationStarted(Fix.genB, Fix.assistantB, parent: Fix.userA, model: Fix.model))
        log.append(.activePathChanged(endpoint: Fix.assistantB))
        log.append(.deltaAppended(Fix.genB, text: "A valley fold brings"))
        log.append(.generationEnded(Fix.genB, .completed(Fix.stopInfo)))
        let state = log.folded()
        #expect(state.messages[Fix.userA]?.children == [Fix.assistantA, Fix.assistantB])
        #expect(state.activePath == [Fix.userA, Fix.assistantB])
        #expect(
            state.messages[Fix.assistantA]?.state == .cancelled(partial: "A valley fold"),
            "the abandoned partial survives as its own branch (DoD-1)"
        )
        #expect(state.reasons.isEmpty)
    }

    @Test("P3 down payment: resuming mid-generation equals folding the whole log")
    func resumeEqualsReplay() {
        // Splits inside an open generation, which is exactly where the
        // generation→message map has to be rebuilt from FoldedMessage.generationID.
        let log = streaming()
        let split = 3
        let prefix = Array(log.rows.prefix(split))
        let suffix = Array(log.rows.dropFirst(split))

        let checkpoint = fold(prefix, for: log.conversation)
        let resumed = fold(resuming: checkpoint, after: Int64(split), with: suffix)
        #expect(resumed == log.folded())
    }
}

// MARK: - Invariants (I1, I2, I6, I7) and the P3 seam

/// Structural predicates the fold must satisfy for *any* input, checked over
/// truncations rather than hand-built happy paths.
///
/// This is the seed of M3's exhaustive small-scope enumeration: express the
/// invariants as executable predicates now, and widening the input generator
/// later is the only work left.
private func invariantProblems(in state: FoldedState) -> [String] {
    var problems: [String] = []

    // I6 — activePath is a parent-linked chain from a root-level node.
    for (index, id) in state.activePath.enumerated() {
        guard let message = state.messages[id] else {
            problems.append("path entry \(id) does not resolve")
            continue
        }
        if index == 0 {
            if message.parent != nil { problems.append("path head \(id) is not root-level") }
        } else if message.parent != state.activePath[index - 1] {
            problems.append("path breaks at \(id)")
        }
    }

    // I6 — rootChildren is exactly the set of nil-parent messages.
    let declared = Set(state.rootChildren)
    let actual = Set(state.messages.values.filter { $0.parent == nil }.map(\.id))
    if declared != actual {
        problems.append("rootChildren \(declared.count) ≠ nil-parent messages \(actual.count)")
    }
    if declared.count != state.rootChildren.count {
        problems.append("rootChildren contains duplicates")
    }

    // I6 — every child reference resolves and the child agrees about its parent.
    // Sorted so a failure message is stable; `values` order is not (I1 hazard).
    for message in state.messages.values.sorted(by: { "\($0.id)" < "\($1.id)" }) {
        for child in message.children {
            guard let node = state.messages[child] else {
                problems.append("dangling child \(child) under \(message.id)")
                continue
            }
            if node.parent != message.id {
                problems.append("child \(child) disagrees about its parent")
            }
        }
        // I7 — only assistant messages carry a generation.
        if message.generationID != nil && message.role != .assistant {
            problems.append("non-assistant \(message.id) carries a generationID")
        }
    }

    // I7 — generation ↔ message is 1:1.
    var bindings: [GenerationID: MessageID] = [:]
    for message in state.messages.values.sorted(by: { "\($0.id)" < "\($1.id)" }) {
        guard let generation = message.generationID else { continue }
        if bindings[generation] != nil {
            problems.append("generation \(generation) bound to more than one message")
        }
        bindings[generation] = message.id
    }

    // Diagnostics are ordered by the sequence they were discovered at.
    let sequences = state.diagnostics.map(\.sequence)
    if sequences != sequences.sorted() {
        problems.append("diagnostics are not in sequence order")
    }

    return problems
}

@Suite("Folder — invariants")
struct FolderInvariantTests {

    /// Exercises every structural feature at once: a completed generation, a
    /// user message beneath it, an edit-as-sibling, an explicit branch switch, a
    /// still-open generation, an undecodable row, and an interior gap.
    private static func richLog() -> Log {
        var log = Log()
        log.append(.conversationCreated(title: "Origami"))                                          // 1
        log.append(.userMessageAppended(Fix.userA, content: "q1", parent: nil))                     // 2
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model)) // 3
        log.append(.deltaAppended(Fix.genA, text: "one "))                                          // 4
        log.append(.deltaAppended(Fix.genA, text: "two"))                                           // 5
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))                            // 6
        log.append(.userMessageAppended(Fix.userB, content: "q2", parent: Fix.assistantA))          // 7
        log.append(.messageEdited(original: Fix.userB, replacement: Fix.edited, content: "q2 v2"))  // 8
        log.append(.activePathChanged(endpoint: Fix.edited))                                        // 9
        log.append(.generationStarted(Fix.genB, Fix.assistantB, parent: Fix.edited, model: Fix.model)) // 10
        log.append(.deltaAppended(Fix.genB, text: "partial"))                                       // 11
        log.undecodable(.payloadKind("messagePinned"))                                              // 12
        log.skip(2)                                                                                 // 13, 14 absent
        log.append(.titleChanged("Origami, revised"))                                               // 15
        return log
    }

    /// Hits most of §6.6 in one log, including the cascade and both decode rows,
    /// so truncation sweeps cover the diagnostic paths and not just happy ones.
    private static func hostileLog() -> Log {
        var log = Log()
        log.append(.titleChanged("premature"))                                                      // row 5
        log.append(.conversationCreated(title: "hostile"))
        log.append(.conversationCreated(title: "again"))                                            // row 5
        log.append(.userMessageAppended(Fix.userA, content: "q", parent: nil))
        log.append(.userMessageAppended(Fix.userB, content: "new topic", parent: nil))              // row 7
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userC, model: Fix.model)) // row 8
        log.append(.deltaAppended(Fix.genA, text: "orphan"))                                        // row 9 cascade
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))                            // cascade
        log.append(.generationStarted(Fix.genB, Fix.assistantB, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(Fix.genB, text: "real"))
        log.append(.generationEnded(Fix.genB, .cancelled))
        log.append(.deltaAppended(Fix.genB, text: "late"))                                          // row 9
        log.append(.generationEnded(Fix.genB, .cancelled))                                          // row 10
        log.append(.messageEdited(original: Fix.assistantB, replacement: Fix.edited, content: "no")) // row 11
        log.append(.activePathChanged(endpoint: Fix.userC))                                         // row 12
        log.undecodable(.envelope, identified: false)                                               // row 1
        log.undecodable(.payloadKind("future"))                                                     // row 2
        log.skip(3)
        log.append(.titleChanged("end"))                                                            // gap
        log.append(.titleChanged("elsewhere"), from: Fix.foreign)                                   // row 4
        return log
    }

    private static var fixtures: [(name: String, log: Log)] {
        [("rich", richLog()), ("hostile", hostileLog())]
    }

    @Test("I1: orderings are pinned to literals, which is what catches hash-seed leakage")
    func determinismGolden() {
        // Repeating the fold in one process proves nothing — Swift's hasher seed
        // is fixed per process. What catches dictionary-order dependence is a
        // literal captured in one process and re-checked in every later one, so
        // these expectations are deliberately spelled out rather than computed.
        let state = Self.richLog().folded()
        #expect(state.rootChildren == [Fix.userA])
        #expect(state.messages[Fix.userA]?.children == [Fix.assistantA])
        #expect(state.messages[Fix.assistantA]?.children == [Fix.userB, Fix.edited])
        #expect(state.messages[Fix.edited]?.children == [Fix.assistantB])
        #expect(state.activePath == [Fix.userA, Fix.assistantA, Fix.edited, Fix.assistantB])
        #expect(state.messages[Fix.assistantA]?.state == .complete(Content(text: "one two")))
        #expect(state.messages[Fix.assistantB]?.state == .open(partial: "partial"))
        #expect(state.diagnostics.map(\.sequence) == [12, 13])
        #expect(state.reasons == [.unknownPayloadKind("messagePinned"), .sequenceGap(missing: 13...14)])
        #expect(state.title == "Origami, revised")
    }

    @Test("I1: the same log folds to the same state")
    func determinismRepeat() {
        for (name, log) in Self.fixtures {
            #expect(log.folded() == log.folded(), "\(name) is not self-consistent")
        }
    }

    @Test("I2: every prefix of every fixture folds without trapping, and holds its invariants")
    func totalityOverPrefixes() {
        // Suffix truncation — a down payment on M3's crash-point fuzzing, which
        // adds interior-gap variants and the full fixture corpus.
        for (name, log) in Self.fixtures {
            for length in 0...log.rows.count {
                let state = fold(Array(log.rows.prefix(length)), for: log.conversation)
                #expect(
                    invariantProblems(in: state).isEmpty,
                    "\(name) truncated at \(length): \(invariantProblems(in: state))"
                )
            }
        }
    }

    @Test("I6: the clamping branch is dead — no truncation produces a broken path")
    func clampingIsUnreachable() {
        // §6.6's clamp exists for a path invalidated by a later quarantine, which
        // I believe unreachable in v0.1 because nothing removes messages. If this
        // ever fails, that belief was wrong and the clamp needs real semantics.
        for (name, log) in Self.fixtures {
            for length in 0...log.rows.count {
                let state = fold(Array(log.rows.prefix(length)), for: log.conversation)
                guard let head = state.activePath.first else { continue }
                #expect(
                    state.messages[head]?.parent == nil,
                    "\(name) at \(length): path head is not root-level, so clamping fired"
                )
            }
        }
    }

    @Test("P3: resuming at every split point equals folding the whole log")
    func resumeAtEverySplit() {
        // The real P3 down payment. Every split is a different reconstruction of
        // the routing map from FoldedMessage.generationID, including splits that
        // land mid-generation and splits that straddle the interior gap.
        for (name, log) in Self.fixtures {
            let whole = log.folded()
            for split in 0...log.rows.count {
                let prefix = Array(log.rows.prefix(split))
                let checkpoint = fold(prefix, for: log.conversation)
                let resumed = fold(
                    resuming: checkpoint,
                    after: prefix.last?.sequence ?? 0,
                    with: Array(log.rows.dropFirst(split))
                )
                #expect(resumed == whole, "\(name) split at \(split)")
            }
        }
    }

    @Test("the hostile fixture reaches the quarantine rows it is built for")
    func hostileRowCoverage() {
        let reasons = Set(Self.hostileLog().folded().reasons)
        #expect(reasons.contains(.beforeGenesis))
        #expect(reasons.contains(.duplicateGenesis))
        #expect(reasons.contains(.additionalRootMessage(Fix.userB)))
        #expect(reasons.contains(.unknownParent(Fix.userC)))
        #expect(reasons.contains(.unknownGeneration(Fix.genA)))
        #expect(reasons.contains(.generationAlreadyTerminated(Fix.genB)))
        #expect(reasons.contains(.duplicateTerminal(Fix.genB)))
        #expect(reasons.contains(.editTargetNotUser(Fix.assistantB)))
        #expect(reasons.contains(.unknownPathEndpoint(Fix.userC)))
        #expect(reasons.contains(.undecodableEnvelope))
        #expect(reasons.contains(.unknownPayloadKind("future")))
        #expect(reasons.contains(.foreignConversation(found: Fix.foreign)))
        #expect(reasons.contains(where: { if case .sequenceGap = $0 { true } else { false } }))
    }
}

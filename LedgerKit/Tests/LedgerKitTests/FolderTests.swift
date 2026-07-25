import Foundation
import Testing
@testable import LedgerKit

// The `Log` builder, `Fix` identifiers and `reasons` accessor live in
// `ReducerFixtures.swift`, shared with the classify suites.

// MARK: - Stream integrity

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

// MARK: - Ordering: a precondition the reducer does not police (§6.6 non-rule)

/// Rev 5 records row ordering as a **non-rule**: reduction requires ascending
/// `sequence` and neither verifies nor repairs violations, because the store's
/// UNIQUE `(conversation_id, sequence)` key and ordered reads make enforcement
/// unreachable code.
///
/// These tests pin what the reducer *actually does* on each side of that line, so
/// M3's fuzz generators and any future import or log-shipping tooling (§12)
/// inherit a documented answer rather than discovering one. Asserting the
/// behaviour is not endorsing replayed input — the spec's point is that only two
/// payload kinds are non-idempotent, and these fixtures are what keep that claim
/// true as the fold changes.
@Suite("Folder — ordering is a precondition, not a rule")
struct FolderOrderingTests {

    /// Replays the log's final row — same sequence, applied twice.
    private func replayingLastRow(of log: Log) -> [LoadedEvent] {
        var rows = log.rows
        if let last = rows.last { rows.append(last) }
        return rows
    }

    @Test("deltas are one of the two non-idempotent kinds: a replay doubles the partial, silently")
    func replayedDeltaAccumulates() {
        var log = Log.withUserMessage()
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(Fix.genA, text: "half"))

        let state = fold(replayingLastRow(of: log), for: log.conversation)
        #expect(state.messages[Fix.assistantA]?.state == .open(partial: "halfhalf"))
        #expect(state.reasons.isEmpty, "no diagnostic — ordering is a precondition, not a quarantine row")
    }

    @Test("tool records are the other non-idempotent kind")
    func replayedToolRecordAccumulates() {
        var log = Log.withUserMessage()
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.toolInvocationRecorded(Fix.genA, ToolRecord(name: "search", status: .succeeded)))

        let state = fold(replayingLastRow(of: log), for: log.conversation)
        #expect(state.messages[Fix.assistantA]?.toolRecords.map(\.name) == ["search", "search"])
        #expect(state.reasons.isEmpty)
    }

    @Test("last-write-wins kinds are idempotent under replay")
    func replayedMetadataIsIdempotent() {
        var log = Log.opened()
        log.append(.titleChanged("final"))

        let state = fold(replayingLastRow(of: log), for: log.conversation)
        #expect(state.title == "final")
        #expect(state.reasons.isEmpty)
    }

    @Test("node-introducing kinds contain a replay on their own once-only rule (I7)")
    func replayedNodeIntroductionQuarantines() {
        // The exposure is narrow *because* I7's allocate-once rule already covers
        // every kind that introduces a message — the ordering non-rule is only
        // safe to state given this.
        let state = fold(replayingLastRow(of: Log.withUserMessage()), for: Fix.conversation)
        #expect(state.reasons == [.messageIDAlreadyUsed(Fix.userA)])
        #expect(state.rootChildren == [Fix.userA], "one node, not two")
    }

    @Test("a replayed terminal is caught by I3, not by ordering")
    func replayedTerminalQuarantines() {
        let state = fold(replayingLastRow(of: Log.withCompletedTurn()), for: Fix.conversation)
        #expect(state.reasons == [.duplicateTerminal(Fix.genA)])
    }

    @Test("an out-of-order row cannot manufacture a gap — the cursor is a running max, never a rewind")
    func outOfOrderRowDoesNotRewindGapDetection() {
        var log = Log.opened()
        log.append(.titleChanged("one"))              // 2
        log.append(.instructionsChanged("i"))         // 3

        var rows = log.rows
        rows.append(rows[1])                          // sequence 2, arriving after sequence 3

        let state = fold(rows, for: log.conversation)
        #expect(state.reasons.isEmpty, "2-after-3 is below the expected cursor, so gap detection stays silent")
        #expect(state.title == "one")
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

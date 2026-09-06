import Foundation
import Testing
@testable import LedgerKit

@Suite("classify — finalization and projection")
struct ClassifyTests {

    /// Genesis, user message, generation started, one delta, **no terminal** —
    /// the crash shape.
    private func interrupted() -> Log {
        var log = Log.withUserMessage()
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(generation: Fix.genA, text: "A valley fol"))
        return log
    }

    @Test("the headline: an open generation classifies as .interrupted (I5)")
    func openBecomesInterrupted() {
        // The fold said `.open` — it had merely stopped reading. Classification
        // is the moment that becomes a claim about the process having died.
        let log = interrupted()
        #expect(log.folded().messages[Fix.assistantA]?.state == .open(partial: "A valley fol"))
        #expect(log.reduced().messages[Fix.assistantA]?.state == .interrupted(partial: "A valley fol"))
    }

    @Test("no reduction of any log yields .streaming — liveness is the projection's (§7.4)")
    func streamingIsUnreachable() {
        var switched = Log.withCompletedTurn()
        switched.append(.generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.userA, model: Fix.model))
        switched.append(.deltaAppended(generation: Fix.genB, text: "second attempt"))

        for log in [Log.withUserMessage(), Log.withCompletedTurn(), interrupted(), switched] {
            let conversation = log.reduced()
            // Enumerated from the folded keys rather than a tree walk, so a node
            // that somehow escaped the tree is still checked.
            for id in log.folded().messages.keys {
                if case .streaming = conversation.messages[id]?.state {
                    Issue.record("a fold produced .streaming for \(id)")
                }
            }
        }
    }

    @Test(".failed carries the Recoverability the mapping produced")
    func failedCarriesRecoverability() {
        var log = Log.withUserMessage()
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.generationEnded(generation: Fix.genA, outcome: .failed(.providerFailure(status: 401, code: nil, message: "nope"))))

        #expect(
            log.reduced().messages[Fix.assistantA]?.state
                == .failed(
                    partial: "",
                    error: .providerFailure(status: 401, code: nil, message: "nope"),
                    recoverability: .recoverableUpstream(.reauthenticate)
                ),
            "the zero-token reauth bubble — §7.2's whole reason for the outcome boundary"
        )
    }

    @Test("complete and cancelled project 1:1")
    func terminalStatesProjectDirectly() {
        #expect(
            Log.withCompletedTurn().reduced().messages[Fix.assistantA]?.state
                == .complete(MessageContent(text: "A valley fold"))
        )

        var cancelled = Log.withUserMessage()
        cancelled.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        cancelled.append(.deltaAppended(generation: Fix.genA, text: "half"))
        cancelled.append(.generationEnded(generation: Fix.genA, outcome: .cancelled))
        #expect(cancelled.reduced().messages[Fix.assistantA]?.state == .cancelled(partial: "half"))
    }

    @Test("every non-state field passes through, generationID included")
    func fieldsPassThrough() {
        let log = Log.withCompletedTurn()
        let folded = log.folded()
        let message = log.reduced().messages[Fix.assistantA]
        let source = folded.messages[Fix.assistantA]

        #expect(message?.id == source?.id)
        #expect(message?.role == .assistant)
        #expect(message?.generationID == Fix.genA)
        #expect(message?.parent == Fix.userA)
        #expect(message?.children == source?.children)
        #expect(message?.model == Fix.model)
        #expect(message?.stopInfo == Fix.stopInfo)
        #expect(message?.timestamp == source?.timestamp)
        #expect(message?.terminalTimestamp == source?.terminalTimestamp)
    }

    @Test("tool records survive projection in sequence order")
    func toolRecordsPassThrough() {
        var log = Log.withUserMessage()
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.toolInvocationRecorded(generation: Fix.genA, record: ToolRecord(name: "search", status: .succeeded)))
        log.append(.toolInvocationRecorded(generation: Fix.genA, record: ToolRecord(name: "fetch", status: .failed)))
        log.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))

        #expect(log.reduced().messages[Fix.assistantA]?.toolRecords.map(\.name) == ["search", "fetch"])
    }

    @Test("conversation-level fields and diagnostics pass through")
    func conversationFieldsPassThrough() {
        var log = Log.opened(title: "Origami")
        log.append(.instructionsChanged("You are an origami tutor."))
        log.append(.userMessageAppended(message: Fix.userA, content: "q", parent: nil))
        log.append(.activePathChanged(endpoint: Fix.userC))

        let conversation = log.reduced()
        #expect(conversation.id == Fix.conversation)
        #expect(conversation.title == "Origami")
        #expect(conversation.instructions == "You are an origami tutor.")
        #expect(conversation.activePath == [Fix.userA])
        #expect(conversation.reasons == [.unknownPathEndpoint(Fix.userC)])
    }

    @Test("the projected tree supports the public read API end to end")
    func treeReadAPI() {
        var log = Log.withCompletedTurn()
        log.append(.generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.userA, model: Fix.model))
        log.append(.generationEnded(generation: Fix.genB, outcome: .cancelled))

        let tree = log.reduced().messages
        #expect(tree.rootChildren == [Fix.userA])
        #expect(tree.children(of: Fix.userA).map(\.id) == [Fix.assistantA, Fix.assistantB])
        #expect(tree.siblings(of: Fix.assistantA).map(\.id) == [Fix.assistantB])
        #expect(tree[Fix.assistantB]?.role == .assistant)
    }

    @Test("activeMessages resolves the visible thread in order")
    func activeMessages() {
        #expect(Log.withCompletedTurn().reduced().activeMessages.map(\.id) == [Fix.userA, Fix.assistantA])
    }

    @Test("Conversation(reducing:loadedFrom:) ≡ classify ∘ fold")
    func reduceIsTheComposition() {
        let log = Log.withCompletedTurn()
        #expect(
            Conversation(reducing: log.rows, loadedFrom: log.conversation)
                == classify(log.folded(), mapping: .default)
        )
    }

    @Test("the default mapping is §8's table — the zero-configuration path")
    func defaultMappingIsImplicit() {
        // The initializer's `mapping` default is what makes the 60-second
        // quickstart (DoD-4) a single call; assert it is genuinely `.default`
        // rather than merely present.
        let log = Log.withCompletedTurn()
        #expect(
            Conversation(reducing: log.rows, loadedFrom: log.conversation)
                == Conversation(reducing: log.rows, loadedFrom: log.conversation, mapping: .default)
        )
    }
}

@Suite("classify — I1's second half")
struct ClassifyDeterminismTests {

    private func failing() -> Log {
        var log = Log.withUserMessage()
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.generationEnded(generation: Fix.genA, outcome: .failed(.guardrailViolation)))
        return log
    }

    @Test("same FoldedState + same mapping ⇒ same Conversation")
    func sameInputsSameOutput() {
        // Assertable only because the mapping is a value. With a closure,
        // "same mapping" would have no meaning and this half of I1 would be
        // permanently untestable.
        let folded = failing().folded()
        #expect(classify(folded, mapping: .default) == classify(folded, mapping: .default))
    }

    @Test("the mapping is part of classification's identity — different mapping, different result")
    func mappingIsPartOfIdentity() {
        var lenient = RecoverabilityMapping.default
        lenient.guardrailViolation = .retryable(after: .seconds(1))

        let folded = failing().folded()
        #expect(classify(folded, mapping: .default) != classify(folded, mapping: lenient))
    }

    @Test("a mapping fix retroactively upgrades historical failures (§8)")
    func classificationBugsHeal() {
        // The point of never persisting Recoverability: the SAME log, reduced
        // again under a corrected mapping, yields better affordances. Nothing
        // migrates, nothing is rewritten.
        let log = failing()

        #expect(
            log.reduced().messages[Fix.assistantA]?.state
                == .failed(partial: "", error: .guardrailViolation, recoverability: .terminal)
        )

        var corrected = RecoverabilityMapping.default
        corrected.guardrailViolation = .recoverableUpstream(.reduceContext)
        #expect(
            log.reduced(mapping: corrected).messages[Fix.assistantA]?.state
                == .failed(
                    partial: "",
                    error: .guardrailViolation,
                    recoverability: .recoverableUpstream(.reduceContext)
                )
        )
    }

    @Test("classification never mutates the fold — the same FoldedState reclassifies identically")
    func classifyIsPure() {
        let folded = failing().folded()
        var mapping = RecoverabilityMapping.default
        _ = classify(folded, mapping: mapping)
        mapping.guardrailViolation = .retryable(after: nil)
        _ = classify(folded, mapping: mapping)
        #expect(folded == failing().folded(), "classify must not have touched its input")
    }
}

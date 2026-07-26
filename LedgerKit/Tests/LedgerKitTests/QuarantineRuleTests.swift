import Foundation
import Testing
@testable import LedgerKit

// The rules the M3 Phase 0 audit found unproven. Each suite here closes a gap
// where the spec is normative and the test suite was silent — not because the
// behaviour was wrong (it is right in every case), but because nothing stopped a
// later change from making it wrong.

// MARK: - I7: allocate-once is one rule, at three sites

/// Rev 5 states `MessageID` allocation as a single rule and §6.6 applies it at
/// rows 6, 8 and 11 — "one rule at three sites, not three coincidences."
///
/// The three sites had a test each already; what was missing is the assertion
/// that they *are* the same rule. If someone later gives one site its own reason
/// case, three green tests would stay green and the rule would have quietly
/// become three coincidences again.
@Suite("I7 — allocate-once at all three introduction sites")
struct AllocateOnceTests {

    @Test("all three sites reject a reused MessageID with the same reason")
    func oneRuleThreeSites() {
        // Site 1 — userMessageAppended (row 6).
        var userAppend = Log.withUserMessage()
        userAppend.append(.userMessageAppended(message: Fix.userA, content: "overwrite", parent: Fix.userA))

        // Site 2 — generationStarted binding an ID the tree holds (row 8).
        var generationStart = Log.withUserMessage()
        generationStart.append(.generationStarted(generation: Fix.genA, message: Fix.userA, parent: Fix.userA, model: Fix.model))

        // Site 3 — messageEdited's replacement (row 11).
        var edit = Log.withUserMessage()
        edit.append(.messageEdited(original: Fix.userA, replacement: Fix.userA, content: "overwrite"))

        for (site, log) in [
            ("userMessageAppended", userAppend),
            ("generationStarted", generationStart),
            ("messageEdited", edit),
        ] {
            #expect(
                log.folded().residue == [ExpectedDiagnostic(3, .messageIDAlreadyUsed(Fix.userA))],
                "\(site) must reject a reused MessageID under the same rule"
            )
        }
    }

    @Test("an ID stays used forever — reuse after the node's generation terminated still quarantines")
    func allocationIsPermanentNotCurrent() {
        // "Has ever named a node", not "currently names a live one" — otherwise
        // an append-only log would admit in-place rewrites of settled history.
        var log = Log.withCompletedTurn()
        log.append(.userMessageAppended(message: Fix.assistantA, content: "rewrite the answer", parent: Fix.userA))
        let state = log.folded()

        #expect(state.residue == [ExpectedDiagnostic(6, .messageIDAlreadyUsed(Fix.assistantA))])
        #expect(state.messages[Fix.assistantA]?.role == .assistant, "the settled node is untouched")
    }

    @Test("the back door: a user append cannot overwrite an IN-FLIGHT assistant message")
    func inFlightAssistantIDCannotBeReused() {
        // Rev 5 added row 6's ID check for exactly this shape (SPEC Appendix C,
        // first bullet). The assistant message's ID was bound at its
        // `generationStarted`, so while the generation streams there is a live
        // node whose ID a hostile — or merely buggy — writer could name.
        var log = Log.withUserMessage()
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 3
        log.append(.deltaAppended(generation: Fix.genA, text: "half an answer"))                                    // 4
        log.append(.userMessageAppended(message: Fix.assistantA, content: "hijacked", parent: Fix.userA))        // 5

        let state = log.folded()

        // Row 6's ID check: `generationStarted` already allocated assistantA, and
        // I7 makes allocation permanent. The rule that fires is about *allocation*,
        // not role — `oneRuleThreeSites` above raises the same reason for a reused
        // user ID. Not `unknownParent`: userA exists. Not `additionalRootMessage`:
        // the parent is non-nil.
        #expect(state.residue == [ExpectedDiagnostic(5, .messageIDAlreadyUsed(Fix.assistantA))])

        // Rev 4 was silent at this site, so the append would have been accepted
        // and rewritten the in-flight node in place — user-authored assistant
        // content by the back door, violating §6.1's "assistant messages exist
        // only as the product of a generation."
        let survivor = state.messages[Fix.assistantA]
        #expect(survivor?.state == .open(partial: "half an answer"))
        #expect(survivor?.role == .assistant, "the in-flight node must not have become user-authored")
        #expect(survivor?.generationID == Fix.genA, "and it must still be routable for the rest of the stream")
    }
}

// MARK: - §6.6 non-rules: what must NOT quarantine

/// The inventory claims completeness, which means the conditions it *declines*
/// to quarantine are as normative as the twelve rows. A non-rule that silently
/// becomes a rule is a regression no row-based test can see.
@Suite("§6.6 non-rules — conditions that must reduce without residue")
struct NonRuleTests {

    @Test("a tolerant terminal is still a terminal — the forgery hole, closed at the fold")
    func tolerantTerminalTerminatesTheGeneration() throws {
        var log = Log.withUserMessage()
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 3
        log.append(.deltaAppended(generation: Fix.genA, text: "half an answer"))                                    // 4
        // A terminal carrying an outcome kind this version has never heard of —
        // what a v0.2 log looks like to a v0.1 reader. Decoded through the real
        // decoder, not hand-constructed: the rule lives in `Payload.init(from:)`,
        // so building the degraded value by hand would assert what this test
        // typed rather than what the decoder decided.
        try log.appendDecoded(                                                                          // 5
            #"""
            {"kind":"generationEnded",
             "generationID":"01980E5A-0000-7000-8000-000000000030",
             "outcome":{"kind":"resolvedOffline","note":"from the future"}}
            """#
        )

        let state = log.folded()

        // Row 3 is the inventory's one non-quarantining row: the terminal lands,
        // degraded, rather than being skipped.
        #expect(state.residue.isEmpty)
        #expect(
            state.messages[Fix.assistantA]?.state
                == .failed(
                    partial: "half an answer",
                    .unrecognized(description: "undecodable outcome: resolvedOffline")
                )
        )
        #expect(
            state.messages[Fix.assistantA]?.terminalTimestamp == log.timestamp(at: 5),
            "terminal-ness is what I5 depends on, and it must be recorded"
        )

        // Why the tolerance exists: if row 3 quarantined, a v0.2 log's new error
        // case would re-render historical *failures* as *crashes* on v0.1
        // readers. That is worse than the cost §6.1 does accept (a corrupt
        // `completed` re-rendering as failed) on both counts — it is a false
        // claim about the process rather than a misreported kind, and every
        // future outcome case would trip it rather than one damaged row.
        if case .interrupted = log.reduced().messages[Fix.assistantA]?.state {
            Issue.record("an unfamiliar outcome was classified .interrupted — the forgery rev 3 closed")
        }
    }

    @Test("two rows sharing an EventID reduce without residue — sequence is the only identity")
    func duplicateEventIDIsNotAQuarantine() throws {
        // A collision is a generator defect worth finding, not contained loss
        // worth skipping an otherwise-valid fact over (§6.6 non-rules, rev 5).
        // `EventID` earns its keep in debugging, index locality and future
        // log-shipping — none of which the reducer consults.
        var log = Log.opened()
        log.append(.titleChanged("one"))                                            // 2
        let collided = try #require(log.eventID(at: 2))
        log.append(.instructionsChanged("two"), reusingEventID: collided)            // 3

        let state = log.folded()
        #expect(state.residue.isEmpty, "identity collision is not a quarantine condition")
        #expect(state.title == "one")
        #expect(state.instructions == "two", "both facts applied — neither was skipped")
    }
}

// MARK: - Rows 9 and 10: the terminal partition

/// Rev 5 widened row 9 to cover orphaned terminals, because the cascade prose in
/// §6.6, §10 and Appendix B all claimed rows 9–10 handled them while row 9 named
/// only deltas and tool records. The two rows answer different questions, and a
/// single log asks both.
@Suite("§6.6 rows 9 and 10 — the terminal partition")
struct TerminalPartitionTests {

    @Test("never-started is row 9; already-terminated is row 10")
    func partition() {
        var log = Log.withUserMessage()
        log.append(.generationEnded(generation: Fix.genGhost, outcome: .cancelled))                                          // 3
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 4
        log.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))                                // 5
        log.append(.generationEnded(generation: Fix.genA, outcome: .cancelled))                                              // 6

        #expect(
            log.folded().residue == [
                ExpectedDiagnostic(3, .unknownGeneration(Fix.genGhost)),
                ExpectedDiagnostic(6, .duplicateTerminal(Fix.genA)),
            ],
            "a terminal for a generation that never started is row 9, not a second terminal"
        )
    }

    // "First append wins" (§7.5's benign cancel-vs-completion race) is
    // deliberately *not* re-asserted here: `FolderTests.duplicateTerminal`
    // already pins that a second terminal leaves the first one's state intact.
}

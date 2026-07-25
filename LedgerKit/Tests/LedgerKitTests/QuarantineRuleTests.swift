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
        userAppend.append(.userMessageAppended(Fix.userA, content: "overwrite", parent: Fix.userA))

        // Site 2 — generationStarted binding an ID the tree holds (row 8).
        var generationStart = Log.withUserMessage()
        generationStart.append(.generationStarted(Fix.genA, Fix.userA, parent: Fix.userA, model: Fix.model))

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
        log.append(.userMessageAppended(Fix.assistantA, content: "rewrite the answer", parent: Fix.userA))
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
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 3
        log.append(.deltaAppended(Fix.genA, text: "half an answer"))                                    // 4
        log.append(.userMessageAppended(Fix.assistantA, content: "hijacked", parent: Fix.userA))        // 5

        let state = log.folded()

        // TODO(human) — derive both from the spec BEFORE running this test.
        //
        //   1. Which `QuarantineReason` case, at which sequence? Say why it is
        //      that case and not `unknownParent` (userA exists) or
        //      `additionalRootMessage` (the parent is not nil) — two rules that
        //      also govern `userMessageAppended` and do not fire here.
        //   2. I2's containment posture: after the event is skipped, what are
        //      assistantA's `role`, `state` and `generationID`? Write the state
        //      exactly, partial included.
        //
        // Then, in the `survivedAs` comment below, answer in one sentence: what
        // would rev 4 have produced at this site (it was silent here), and which
        // sentence of §6.1's role rule does that violate?
        // Row 6's ID check: `generationStarted` already allocated assistantA, and
        // I7 makes allocation permanent. The rule that fires is about *allocation*,
        // not role — `oneRuleThreeSites` above raises the same reason for a reused
        // user ID. Not `unknownParent`: userA exists. Not `additionalRootMessage`:
        // the parent is non-nil.
        let expectedResidue: [ExpectedDiagnostic]? = [.init(5, .messageIDAlreadyUsed(Fix.assistantA))]
        let expectedState: FoldedMessageState? = .open(partial: "half an answer")

        guard let expectedResidue, let expectedState else {
            Issue.record("TODO(human): derive the residue and the surviving state from §6.6 row 6 + I7")
            return
        }

        #expect(state.residue == expectedResidue)

        // survivedAs: rev 4 was silent at this site, so the append would have been
        // accepted and rewritten the in-flight node in place — user-authored
        // assistant content by the back door, violating §6.1's "assistant messages
        // exist only as the product of a generation."
        let survivor = state.messages[Fix.assistantA]
        #expect(survivor?.state == expectedState)
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
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 3
        log.append(.deltaAppended(Fix.genA, text: "half an answer"))                                    // 4
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

        // TODO(human) — derive both from the spec BEFORE running this test.
        //
        // The decoder's half is already pinned: `WireFormatTests` proves this
        // JSON decodes to `.generationEnded(genA, .failed(.unrecognized(…)))`.
        // What the *fold* then does with it is the audit's most valuable gap —
        // nothing in the package asserts it today.
        //
        //   1. §6.6 row 3's disposition column is the only one that does not say
        //      "quarantine". What does that make `expectedResidue`?
        //   2. §6.1, "Interruption is not an outcome — and terminals are
        //      decode-tolerant": which `FoldedMessageState` does assistantA end
        //      in, with what partial and what exact `description` string? (The
        //      string is ADR-001-non-contractual as *prose*, but here it is data
        //      inside the case you are asserting, so it must match.)
        //   3. The reason the rule exists, for the comment below: if row 3
        //      quarantined instead, what would a v0.2 log's new error case
        //      render as on a v0.1 reader — and why is that worse than the
        //      "corrupt `completed` re-renders as failed" cost §6.1 accepts?
        let expectedResidue: [ExpectedDiagnostic]? = [] // No quarantine, no residue
        let expectedState: FoldedMessageState? = .failed(partial: "half an answer", .unrecognized(description: "undecodable outcome: resolvedOffline"))

        guard let expectedResidue, let expectedState else {
            Issue.record("TODO(human): derive the residue and terminal state from §6.6 row 3 + §6.1")
            return
        }

        #expect(expectedResidue.isEmpty, "row 3 is the inventory's one non-quarantining row")
        #expect(state.residue == expectedResidue)
        #expect(state.messages[Fix.assistantA]?.state == expectedState)
        #expect(
            state.messages[Fix.assistantA]?.terminalTimestamp == log.timestamp(at: 5),
            "terminal-ness is what I5 depends on, and it must be recorded"
        )

        // whyItMatters: v0.2 log's new error case would have re-rendered historical *failures* as *crashes* on v0.1 readers
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
        log.append(.generationEnded(Fix.genGhost, .cancelled))                                          // 3
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 4
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))                                // 5
        log.append(.generationEnded(Fix.genA, .cancelled))                                              // 6

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

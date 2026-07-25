import Foundation
import Testing
@testable import LedgerKit

/// Tests for the test harness — deliberately, and only here.
///
/// Phase 2's crash-point fuzzing derives *all* of its value from
/// `invariantProblems`: it feeds thousands of mutated logs through a predicate
/// and reports what it finds. A predicate that silently cannot fail would make
/// that entire suite a very expensive `#expect(true)`, and nothing else in the
/// package would notice. So each check is fed a state that violates it, and is
/// required to object.
///
/// These build `FoldedState` values by hand rather than by folding a log —
/// which is the point. Several of the conditions below are ones the fold is
/// believed incapable of producing; if that belief were the only thing under
/// test, the predicate could be vacuous and still look green.
@Suite("Invariant predicates — the checks can actually fail")
struct InvariantCheckTests {

    private static let stamp = Date(timeIntervalSince1970: 1_784_979_000)

    private func node(
        _ id: MessageID,
        role: Role = .user,
        generationID: GenerationID? = nil,
        parent: MessageID? = nil,
        children: [MessageID] = [],
        state: FoldedMessageState = .complete(Content(text: "x")),
        stopInfo: StopInfo? = nil,
        terminalTimestamp: Date? = nil
    ) -> FoldedMessage {
        FoldedMessage(
            id: id,
            role: role,
            generationID: generationID,
            parent: parent,
            children: children,
            state: state,
            stopInfo: stopInfo,
            timestamp: Self.stamp,
            terminalTimestamp: terminalTimestamp
        )
    }

    /// A minimal healthy state: one root user message, path sitting on it.
    private func healthy(
        messages: [FoldedMessage]? = nil,
        rootChildren: [MessageID] = [Fix.userA],
        activePath: [MessageID] = [Fix.userA],
        diagnostics: [QuarantinedEvent] = []
    ) -> FoldedState {
        let nodes = messages ?? [node(Fix.userA)]
        return FoldedState(
            id: Fix.conversation,
            messages: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
            rootChildren: rootChildren,
            activePath: activePath,
            diagnostics: diagnostics,
            hasGenesis: true
        )
    }

    private func expectDetected(_ state: FoldedState, _ what: Comment) {
        #expect(!invariantProblems(in: state).isEmpty, what)
    }

    @Test("the baseline is genuinely clean — otherwise every check below is meaningless")
    func healthyStatePasses() {
        #expect(invariantProblems(in: healthy()).isEmpty)
    }

    @Test("I6: tree corruption is detected")
    func treeCorruption() {
        expectDetected(
            healthy(messages: [node(Fix.userA, parent: Fix.userB), node(Fix.userB)], rootChildren: [Fix.userB]),
            "path head is not root-level"
        )
        expectDetected(
            healthy(messages: [node(Fix.userA, children: [Fix.userC])]),
            "dangling child reference"
        )
        expectDetected(
            healthy(messages: [node(Fix.userA, children: [Fix.userB]), node(Fix.userB, parent: Fix.userC)]),
            "child disagrees about its parent"
        )
        expectDetected(
            healthy(rootChildren: []),
            "rootChildren omits a nil-parent message"
        )
        expectDetected(
            healthy(rootChildren: [Fix.userA, Fix.userA], activePath: [Fix.userA]),
            "rootChildren contains a duplicate"
        )
        expectDetected(
            healthy(activePath: [Fix.userA, Fix.userB]),
            "path entry does not resolve"
        )
    }

    @Test("I7 and §6.2: role-scoped and lifecycle field corruption is detected")
    func fieldCorruption() {
        expectDetected(
            healthy(messages: [node(Fix.userA, generationID: Fix.genA)]),
            "a user message carrying a generationID — the back door I7 closes"
        )
        expectDetected(
            healthy(messages: [node(Fix.userA, stopInfo: Fix.stopInfo)]),
            "a user message carrying stopInfo"
        )
        expectDetected(
            healthy(messages: [node(Fix.userA, state: .open(partial: "x"))]),
            "a user message that is not .complete"
        )
        expectDetected(
            healthy(messages: [
                node(Fix.userA, role: .assistant, generationID: Fix.genA, state: .cancelled(partial: "x"), stopInfo: Fix.stopInfo)
            ]),
            "stopInfo on a non-completed generation"
        )
        expectDetected(
            healthy(messages: [
                node(Fix.userA, role: .assistant, generationID: Fix.genA, state: .open(partial: ""), terminalTimestamp: Self.stamp)
            ]),
            "an open generation carrying a terminal timestamp"
        )
        expectDetected(
            healthy(
                messages: [
                    node(Fix.userA, role: .assistant, generationID: Fix.genA),
                    node(Fix.userB, role: .assistant, generationID: Fix.genA, parent: Fix.userA),
                ],
                rootChildren: [Fix.userA]
            ),
            "one generation bound to two messages — I7's 1:1 broken"
        )
    }

    @Test("§6.6: diagnostic ordering and identity corruption is detected")
    func diagnosticCorruption() {
        expectDetected(
            healthy(diagnostics: [
                QuarantinedEvent(sequence: 9, eventID: EventID(uuid(1)), reason: .beforeGenesis),
                QuarantinedEvent(sequence: 2, eventID: EventID(uuid(2)), reason: .duplicateGenesis),
            ]),
            "diagnostics out of sequence order"
        )
        expectDetected(
            healthy(diagnostics: [QuarantinedEvent(sequence: 2, eventID: nil, reason: .duplicateGenesis)]),
            "a non-row-1 diagnostic that lost its eventID — the row-2 degradation §6.6 warns about"
        )
        expectDetected(
            healthy(diagnostics: [
                QuarantinedEvent(sequence: 2, eventID: EventID(uuid(1)), reason: .sequenceGap(missing: 2...3))
            ]),
            "a gap diagnostic carrying an eventID — no row exists to have one"
        )
    }

    @Test("§6.3: fold → classify correspondence corruption is detected")
    func classificationCorruption() {
        let folded = healthy(messages: [
            node(Fix.userA, role: .assistant, generationID: Fix.genA, state: .open(partial: "half"))
        ])

        let faithful = classify(folded, mapping: .default)
        #expect(
            invariantProblems(in: faithful, foldedFrom: folded).isEmpty,
            "the baseline classification must be clean"
        )
        #expect(
            faithful.messages[Fix.userA]?.state == .interrupted(partial: "half"),
            "I5's finalization is what the bridge is checking against"
        )

        // A node the classifier lost. `classify` walks the message dictionary
        // rather than the tree precisely so this cannot happen silently (M2
        // audit) — the predicate is what keeps that decision enforced.
        let dropped = Conversation(
            id: folded.id,
            messages: MessageTree(nodes: [:], rootChildren: folded.rootChildren),
            activePath: folded.activePath
        )
        #expect(!invariantProblems(in: dropped, foldedFrom: folded).isEmpty, "a dropped message")

        // `.streaming` from a fold is the forgery §7.4 forbids: no log can know
        // the process is alive.
        let streaming = Message(
            id: Fix.userA,
            role: .assistant,
            generationID: Fix.genA,
            state: .streaming(partial: "half"),
            timestamp: Self.stamp
        )
        let forged = Conversation(
            id: folded.id,
            messages: MessageTree(nodes: [Fix.userA: streaming], rootChildren: folded.rootChildren),
            activePath: folded.activePath
        )
        #expect(
            !invariantProblems(in: forged, foldedFrom: folded).isEmpty,
            "a fold that produced .streaming"
        )

        // Pass-through fields must survive finalization untouched.
        var retitled = faithful
        retitled.title = "changed by classification"
        #expect(!invariantProblems(in: retitled, foldedFrom: folded).isEmpty, "a mutated pass-through field")
    }
}

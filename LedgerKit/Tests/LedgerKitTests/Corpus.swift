import Foundation
@testable import LedgerKit

// The fixture corpus (SPEC §10.2) — one registry every sweep iterates, so a
// fixture added here automatically earns truncation, interior-gap, P3-split and
// determinism coverage rather than only the assertions someone remembered to
// write for it.
//
// Fixtures live in `LedgerKitTests` rather than a separate package because the
// fold-level sweeps need `@testable` internals (`fold`, `FoldedState`). They
// build on `ReducerFixtures.swift`'s `Log` builder and `Fix` identifiers.
//
// Three files, three roles: this one holds the fixtures and their pinned data,
// `CorpusTests` asserts each fixture's own expectations, `CorpusSweepTests`
// runs the generic predicates over all of them.

/// One expected diagnostic, pinned in both dimensions.
///
/// Residue assertions check the sequence as well as the reason because §6.6's
/// diagnostics are a claim about *which row* was skipped: a reason-only
/// assertion passes even when the reducer blames the wrong event, which is
/// exactly the bug a developer reading diagnostics would be misled by.
struct ExpectedDiagnostic: Equatable, CustomStringConvertible {
    var sequence: Int64
    var reason: QuarantineReason

    init(_ sequence: Int64, _ reason: QuarantineReason) {
        self.sequence = sequence
        self.reason = reason
    }

    var description: String { "seq \(sequence): \(reason)" }
}

extension FoldedState {
    /// Residue in the comparable shape — `diagnostics` minus the event IDs,
    /// which vary with fixture construction and are checked structurally by
    /// `invariantProblems(in:)` instead.
    var residue: [ExpectedDiagnostic] {
        diagnostics.map { ExpectedDiagnostic($0.sequence, $0.reason) }
    }
}

extension Conversation {
    var residue: [ExpectedDiagnostic] {
        diagnostics.map { ExpectedDiagnostic($0.sequence, $0.reason) }
    }
}

/// A named log plus whatever the corpus pins about it.
struct CorpusFixture {

    /// What the fixture is *for*. Sweeps treat both alike — the distinction is
    /// for reading the corpus, and for suites that want only healthy logs (a
    /// golden must reduce with empty residue; a hostile must not).
    enum Kind {
        /// Reduces cleanly. Doubles as living documentation of semantics.
        case golden
        /// Exercises §6.6. Its residue is pinned exactly.
        case hostile
    }

    let name: String
    let kind: Kind
    /// One line on what the fixture demonstrates — surfaces in failure messages.
    let summary: String
    let log: Log
    /// Expected quarantine residue, in discovery order. Always pinned: a golden
    /// fixture's `[]` is as load-bearing an assertion as a hostile one's list.
    let residue: [ExpectedDiagnostic]
}

enum Corpus {

    // MARK: Golden — logs a healthy store produces (SPEC §10.2)
    //
    // Every one of these must reduce with empty residue, and together they are
    // the sweeps' only exposure to healthy state: before Phase 1 the corpus held
    // `rich` and `hostile` alone, so every mutation sweep started from a log that
    // was already damaged. A reducer bug that only manifests on clean input —
    // the likeliest kind, since clean input is what ships — had nothing to fail.

    /// The 95% path: one user message, one generation, completed.
    static var ordinaryTurn: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: "Valley folds 101"))
        log.append(.userMessageAppended(message: Fix.userA, content: "Explain valley folds", parent: nil))
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(generation: Fix.genA, text: "A valley fold "))
        log.append(.deltaAppended(generation: Fix.genA, text: "brings the paper down."))
        log.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))

        return CorpusFixture(
            name: "ordinaryTurn",
            kind: .golden,
            summary: "the 95% path — user message, generation, completed",
            log: log,
            residue: []
        )
    }

    /// Two completed turns and a third user message with no generation yet —
    /// the state a conversation sits in between `send` and the first delta.
    static var multiTurn: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: "Origami"))
        log.append(.userMessageAppended(message: Fix.userA, content: "q1", parent: nil))
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(generation: Fix.genA, text: "a1"))
        log.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))
        log.append(.userMessageAppended(message: Fix.userB, content: "q2", parent: Fix.assistantA))
        log.append(.generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.userB, model: Fix.model))
        log.append(.deltaAppended(generation: Fix.genB, text: "a2"))
        log.append(.generationEnded(generation: Fix.genB, outcome: .completed(Fix.stopInfo)))
        log.append(.userMessageAppended(message: Fix.userC, content: "q3", parent: Fix.assistantB))

        return CorpusFixture(
            name: "multiTurn",
            kind: .golden,
            summary: "two completed turns plus a trailing user message with no generation",
            log: log,
            residue: []
        )
    }

    /// Edit-as-branch: the replacement is a sibling of the original under the
    /// same parent, and the store's paired path event moves onto it (§6.4).
    static var editBranch: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: "Origami"))
        log.append(.userMessageAppended(message: Fix.userA, content: "q1", parent: nil))
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(generation: Fix.genA, text: "a1"))
        log.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))
        log.append(.userMessageAppended(message: Fix.userB, content: "q2", parent: Fix.assistantA))
        log.append(.messageEdited(original: Fix.userB, replacement: Fix.edited, content: "q2, revised"))
        log.append(.activePathChanged(endpoint: Fix.edited))

        return CorpusFixture(
            name: "editBranch",
            kind: .golden,
            summary: "edit-as-branch — sibling under the same parent, path moved onto it",
            log: log,
            residue: []
        )
    }

    /// Editing the *first* message, which rev 2 accidentally forbade: the
    /// replacement is a root-level sibling under the virtual root, no special
    /// case anywhere (I6).
    static var rootEdit: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: nil))
        log.append(.userMessageAppended(message: Fix.userA, content: "Explain valley folds", parent: nil))
        log.append(.messageEdited(original: Fix.userA, replacement: Fix.edited, content: "Explain mountain folds"))
        log.append(.activePathChanged(endpoint: Fix.edited))

        return CorpusFixture(
            name: "rootEdit",
            kind: .golden,
            summary: "editing the first message yields a root-level sibling (I6, no special case)",
            log: log,
            residue: []
        )
    }

    /// **DoD-1's shape.** A generation dies without a terminal, and the user
    /// regenerates: the abandoned partial survives as its own branch, reachable
    /// via the branch switcher, and the new generation completes beside it.
    ///
    /// Legal with zero residue even though two generations overlap — single
    /// flight is a *store* rule; the log and reducer tolerate concurrency (§6.5).
    static var regenerateAfterInterruption: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: "Origami"))
        log.append(.userMessageAppended(message: Fix.userA, content: "Explain valley folds", parent: nil))
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.deltaAppended(generation: Fix.genA, text: "A valley fol"))
        log.append(.generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.userA, model: Fix.model))
        log.append(.activePathChanged(endpoint: Fix.assistantB))
        log.append(.deltaAppended(generation: Fix.genB, text: "A valley fold brings the paper down."))
        log.append(.generationEnded(generation: Fix.genB, outcome: .completed(Fix.stopInfo)))

        return CorpusFixture(
            name: "regenerateAfterInterruption",
            kind: .golden,
            summary: "DoD-1 — an interrupted partial survives as a sibling branch beside the regeneration",
            log: log,
            residue: []
        )
    }

    /// Metadata and the audit trail: instructions set, title set then cleared,
    /// tool records inside the generation's bounds under both recording
    /// policies' shapes (§7.6).
    static var toolsAndMetadata: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: nil))
        log.append(.instructionsChanged("You are an origami tutor."))
        log.append(.titleChanged("Valley folds 101"))
        log.append(.userMessageAppended(message: Fix.userA, content: "Look it up", parent: nil))
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))
        log.append(.toolInvocationRecorded(
            generation: Fix.genA,
            record: ToolRecord(name: "search", status: .succeeded, duration: .milliseconds(120))
        ))
        log.append(.deltaAppended(generation: Fix.genA, text: "Found it: "))
        log.append(.toolInvocationRecorded(
            generation: Fix.genA,
            record: ToolRecord(name: "fetch", status: .failed, duration: .milliseconds(35), argumentsJSON: #"{"url":"…"}"#)
        ))
        log.append(.deltaAppended(generation: Fix.genA, text: "a valley fold."))
        log.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))
        log.append(.titleChanged(nil))

        return CorpusFixture(
            name: "toolsAndMetadata",
            kind: .golden,
            summary: "instructions, title set then cleared, in-bounds tool records",
            log: log,
            residue: []
        )
    }

    /// No rows at all. Degenerate, and cheap to keep honest: a conversation
    /// exists before its genesis is written, and every sweep should survive it.
    static var empty: CorpusFixture {
        CorpusFixture(
            name: "empty",
            kind: .golden,
            summary: "a log with no rows — the state before genesis",
            log: Log(),
            residue: []
        )
    }

    // MARK: Hostile — §6.6 exercised

    /// A gap that swallowed the terminal. The single most important interaction
    /// in the corpus: I5 reads "no terminal exists anywhere in the log," and a
    /// hole is one of the two ways that becomes true (process death is the
    /// other). Reduction continues past the hole, one diagnostic is raised, and
    /// the generation is honestly `.open` — you truly do not know how it ended.
    static var gapSwallowedTerminal: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: "Origami"))                                              // 1
        log.append(.userMessageAppended(message: Fix.userA, content: "q", parent: nil))                          // 2
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 3
        log.append(.deltaAppended(generation: Fix.genA, text: "half an answer"))                                    // 4
        log.skip(1)                                                                                     // 5 — the terminal
        log.append(.titleChanged("after the hole"))                                                     // 6

        return CorpusFixture(
            name: "gapSwallowedTerminal",
            kind: .hostile,
            summary: "an interior gap swallows the terminal — I5 through absence",
            log: log,
            residue: [ExpectedDiagnostic(5, .sequenceGap(missing: 5...5))]
        )
    }

    /// Every structural feature at once: a completed generation, a user message
    /// beneath it, an edit-as-sibling, an explicit branch switch, a still-open
    /// generation, an undecodable row, and an interior gap.
    ///
    /// The breadth is the point — sweeps mutate it into thousands of logs, and a
    /// feature absent here is a feature no sweep can reach.
    static var rich: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: "Origami"))                                              // 1
        log.append(.userMessageAppended(message: Fix.userA, content: "q1", parent: nil))                         // 2
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 3
        log.append(.deltaAppended(generation: Fix.genA, text: "one "))                                              // 4
        log.append(.deltaAppended(generation: Fix.genA, text: "two"))                                               // 5
        log.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))                                // 6
        log.append(.userMessageAppended(message: Fix.userB, content: "q2", parent: Fix.assistantA))              // 7
        log.append(.messageEdited(original: Fix.userB, replacement: Fix.edited, content: "q2 v2"))      // 8
        log.append(.activePathChanged(endpoint: Fix.edited))                                            // 9
        log.append(.generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.edited, model: Fix.model))  // 10
        log.append(.deltaAppended(generation: Fix.genB, text: "partial"))                                           // 11
        log.unknownPayloadKind("messagePinned")                                                         // 12 row 2
        log.skip(2)                                                                                     // 13, 14 absent
        log.append(.titleChanged("Origami, revised"))                                                   // 15

        return CorpusFixture(
            name: "rich",
            kind: .hostile,
            summary: "every structural feature, plus one undecodable row and one interior gap",
            log: log,
            residue: [
                ExpectedDiagnostic(12, .undecodablePayload(kind: "messagePinned")),
                ExpectedDiagnostic(13, .sequenceGap(missing: 13...14)),
            ]
        )
    }

    /// Most of §6.6 in one log, including the cascade and both decode rows, so
    /// truncation sweeps cover the diagnostic paths and not just happy ones.
    ///
    /// Phase 1 adds one fixture *per row* so a failure names the row it broke;
    /// this composite stays, because rows interacting is its own risk — row 4
    /// outranking row 5, a cascade landing beside an unrelated gap.
    static var hostile: CorpusFixture {
        var log = Log()
        log.append(.titleChanged("premature"))                                                          // 1  row 5
        log.append(.conversationCreated(title: "hostile"))                                              // 2
        log.append(.conversationCreated(title: "again"))                                                // 3  row 5
        log.append(.userMessageAppended(message: Fix.userA, content: "q", parent: nil))                          // 4
        log.append(.userMessageAppended(message: Fix.userB, content: "new topic", parent: nil))                  // 5  row 7
        log.append(.generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userC, model: Fix.model))   // 6  row 8
        log.append(.deltaAppended(generation: Fix.genA, text: "orphan"))                                            // 7  cascade
        log.append(.generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo)))                                // 8  cascade
        log.append(.generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.userA, model: Fix.model))   // 9
        log.append(.deltaAppended(generation: Fix.genB, text: "real"))                                              // 10
        log.append(.generationEnded(generation: Fix.genB, outcome: .cancelled))                                              // 11
        log.append(.deltaAppended(generation: Fix.genB, text: "late"))                                              // 12 row 9
        log.append(.generationEnded(generation: Fix.genB, outcome: .cancelled))                                              // 13 row 10
        log.append(.messageEdited(original: Fix.assistantB, replacement: Fix.edited, content: "no"))    // 14 row 11
        log.append(.activePathChanged(endpoint: Fix.userC))                                             // 15 row 12
        log.corruptRow()                                                                                // 16 row 1
        log.unknownPayloadKind("future")                                                                // 17 row 2
        log.skip(3)                                                                                     // 18–20 absent
        log.append(.titleChanged("end"))                                                                // 21
        log.append(.titleChanged("elsewhere"), from: Fix.foreign)                                       // 22 row 4

        return CorpusFixture(
            name: "hostile",
            kind: .hostile,
            summary: "most of §6.6 in one log — cascade, both decode rows, a gap, a foreign event",
            log: log,
            residue: [
                ExpectedDiagnostic(1, .beforeGenesis),
                ExpectedDiagnostic(3, .duplicateGenesis),
                ExpectedDiagnostic(5, .additionalRootMessage(Fix.userB)),
                ExpectedDiagnostic(6, .unknownParent(Fix.userC)),
                ExpectedDiagnostic(7, .unknownGeneration(Fix.genA)),
                ExpectedDiagnostic(8, .unknownGeneration(Fix.genA)),
                ExpectedDiagnostic(12, .generationAlreadyTerminated(Fix.genB)),
                ExpectedDiagnostic(13, .duplicateTerminal(Fix.genB)),
                ExpectedDiagnostic(14, .editTargetNotUser(Fix.assistantB)),
                ExpectedDiagnostic(15, .unknownPathEndpoint(Fix.userC)),
                ExpectedDiagnostic(16, .undecodableEnvelope),
                ExpectedDiagnostic(17, .undecodablePayload(kind: "future")),
                ExpectedDiagnostic(18, .sequenceGap(missing: 18...20)),
                ExpectedDiagnostic(22, .foreignConversation(found: Fix.foreign)),
            ]
        )
    }

    /// The whole corpus. Every sweep iterates this; nothing iterates a subset
    /// without a stated reason.
    static var all: [CorpusFixture] {
        [
            ordinaryTurn,
            multiTurn,
            editBranch,
            rootEdit,
            regenerateAfterInterruption,
            toolsAndMetadata,
            empty,
            gapSwallowedTerminal,
            rich,
            hostile,
        ]
    }
}

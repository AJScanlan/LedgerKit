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

    /// Every structural feature at once: a completed generation, a user message
    /// beneath it, an edit-as-sibling, an explicit branch switch, a still-open
    /// generation, an undecodable row, and an interior gap.
    ///
    /// The breadth is the point — sweeps mutate it into thousands of logs, and a
    /// feature absent here is a feature no sweep can reach.
    static var rich: CorpusFixture {
        var log = Log()
        log.append(.conversationCreated(title: "Origami"))                                              // 1
        log.append(.userMessageAppended(Fix.userA, content: "q1", parent: nil))                         // 2
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))   // 3
        log.append(.deltaAppended(Fix.genA, text: "one "))                                              // 4
        log.append(.deltaAppended(Fix.genA, text: "two"))                                               // 5
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))                                // 6
        log.append(.userMessageAppended(Fix.userB, content: "q2", parent: Fix.assistantA))              // 7
        log.append(.messageEdited(original: Fix.userB, replacement: Fix.edited, content: "q2 v2"))      // 8
        log.append(.activePathChanged(endpoint: Fix.edited))                                            // 9
        log.append(.generationStarted(Fix.genB, Fix.assistantB, parent: Fix.edited, model: Fix.model))  // 10
        log.append(.deltaAppended(Fix.genB, text: "partial"))                                           // 11
        log.undecodable(.payloadKind("messagePinned"))                                                  // 12
        log.skip(2)                                                                                     // 13, 14 absent
        log.append(.titleChanged("Origami, revised"))                                                   // 15

        return CorpusFixture(
            name: "rich",
            kind: .hostile,
            summary: "every structural feature, plus one undecodable row and one interior gap",
            log: log,
            residue: [
                ExpectedDiagnostic(12, .unknownPayloadKind("messagePinned")),
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
        log.append(.userMessageAppended(Fix.userA, content: "q", parent: nil))                          // 4
        log.append(.userMessageAppended(Fix.userB, content: "new topic", parent: nil))                  // 5  row 7
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userC, model: Fix.model))   // 6  row 8
        log.append(.deltaAppended(Fix.genA, text: "orphan"))                                            // 7  cascade
        log.append(.generationEnded(Fix.genA, .completed(Fix.stopInfo)))                                // 8  cascade
        log.append(.generationStarted(Fix.genB, Fix.assistantB, parent: Fix.userA, model: Fix.model))   // 9
        log.append(.deltaAppended(Fix.genB, text: "real"))                                              // 10
        log.append(.generationEnded(Fix.genB, .cancelled))                                              // 11
        log.append(.deltaAppended(Fix.genB, text: "late"))                                              // 12 row 9
        log.append(.generationEnded(Fix.genB, .cancelled))                                              // 13 row 10
        log.append(.messageEdited(original: Fix.assistantB, replacement: Fix.edited, content: "no"))    // 14 row 11
        log.append(.activePathChanged(endpoint: Fix.userC))                                             // 15 row 12
        log.undecodable(.envelope, identified: false)                                                   // 16 row 1
        log.undecodable(.payloadKind("future"))                                                         // 17 row 2
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
                ExpectedDiagnostic(17, .unknownPayloadKind("future")),
                ExpectedDiagnostic(18, .sequenceGap(missing: 18...20)),
                ExpectedDiagnostic(22, .foreignConversation(found: Fix.foreign)),
            ]
        )
    }

    /// The whole corpus. Every sweep iterates this; nothing iterates a subset
    /// without a stated reason.
    static var all: [CorpusFixture] { [rich, hostile] }

    static var golden: [CorpusFixture] { all.filter { $0.kind == .golden } }

    static var hostileFixtures: [CorpusFixture] { all.filter { $0.kind == .hostile } }
}

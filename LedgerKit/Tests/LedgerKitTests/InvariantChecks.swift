import Foundation
@testable import LedgerKit

// Executable forms of the reduction invariants (SPEC §6.3, I1–I7), expressed as
// predicates over *any* input rather than as expectations about one hand-built
// log. Sweeps in the corpus suites feed them thousands of mutated logs; a
// fixture-specific expectation belongs in that fixture's own test.
//
// These return `[String]` rather than recording issues themselves so a caller
// can attach its own context — "hostile truncated at 14" is a far more useful
// failure than "path breaks at 0198…".

/// `if case .complete = state {} else { … }` reads as a typo; this does not.
private func isComplete(_ state: FoldedMessageState) -> Bool {
    if case .complete = state { true } else { false }
}

// MARK: - Fold level

/// Structural predicates the **fold** must satisfy for any log whatsoever.
///
/// Everything here is universal: no fixture may exempt itself, and a violation
/// is a reducer bug rather than a surprising-but-legal input. Conditions that
/// depend on *which* log was folded belong in fixture tests.
func invariantProblems(in state: FoldedState) -> [String] {
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

        // Role-scoped fields (§6.2): everything below `role` is assistant-only,
        // and a user message carrying any of it means an event routed to the
        // wrong node — the shape I7's allocate-once rule exists to prevent.
        if message.role != .assistant {
            if message.generationID != nil { problems.append("user \(message.id) carries a generationID") }
            if message.model != nil { problems.append("user \(message.id) carries a model") }
            if message.stopInfo != nil { problems.append("user \(message.id) carries stopInfo") }
            if !message.toolRecords.isEmpty { problems.append("user \(message.id) carries tool records") }
            if !isComplete(message.state) {
                problems.append("user \(message.id) is \(message.state), not .complete")
            }
        }

        // §7.7 — stopInfo comes from `Outcome.completed` and nowhere else.
        if message.stopInfo != nil && !isComplete(message.state) {
            problems.append("\(message.id) has stopInfo but is \(message.state)")
        }

        // I5 — an open generation has no terminal, so it has no terminal stamp.
        if message.state.isOpen && message.terminalTimestamp != nil {
            problems.append("open \(message.id) carries a terminalTimestamp")
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

    // §6.6 "Diagnostic identity" — every row *except* row 1 and a gap carries the
    // offending event's ID. Stated one-directionally on purpose: the converse
    // (row 1 ⇒ nil) is the loader's contract, not the fold's, so only the gap
    // half — which the fold mints itself — is asserted here.
    for diagnostic in state.diagnostics {
        switch diagnostic.reason {
        case .undecodableEnvelope:
            break
        case .sequenceGap:
            if diagnostic.eventID != nil {
                problems.append("gap diagnostic at \(diagnostic.sequence) has an eventID; no row exists to have one")
            }
        default:
            if diagnostic.eventID == nil {
                problems.append("diagnostic at \(diagnostic.sequence) (\(diagnostic.reason)) lost its eventID")
            }
        }
    }

    return problems
}

// MARK: - Classify level

/// Structural predicates relating a fold to its classification (SPEC §6.3).
///
/// Takes the `FoldedState` rather than standing alone because `MessageTree`
/// keeps its storage private, so the only honest enumeration of "every node the
/// reducer produced" comes from the folded layer. Walking down from
/// `rootChildren` instead would be unable to notice a node that fell *out* of
/// the tree — precisely the failure the M2 audit chose a dictionary over a tree
/// walk to keep detectable.
///
/// The payoff is that the check became stronger than a standalone one could be:
/// it asserts the rev-5 three-name correspondence directly, so I5's
/// `.open ⇒ .interrupted` finalization is verified against every log a sweep can
/// build rather than against the handful that have a hand-written expectation.
func invariantProblems(in conversation: Conversation, foldedFrom folded: FoldedState) -> [String] {
    var problems: [String] = []

    // Classification changes message *states*. Everything else is pass-through,
    // and a difference here means finalization did something it has no business
    // doing — which would also put I1's second half at risk.
    if conversation.id != folded.id { problems.append("id changed in classification") }
    if conversation.title != folded.title { problems.append("title changed in classification") }
    if conversation.instructions != folded.instructions { problems.append("instructions changed in classification") }
    if conversation.activePath != folded.activePath { problems.append("activePath changed in classification") }
    if conversation.messages.rootChildren != folded.rootChildren { problems.append("rootChildren changed in classification") }
    if conversation.diagnostics != folded.diagnostics { problems.append("diagnostics changed in classification") }

    for source in folded.messages.values.sorted(by: { "\($0.id)" < "\($1.id)" }) {
        guard let message = conversation.messages[source.id] else {
            problems.append("\(source.id) was dropped in classification")
            continue
        }

        if message.role != source.role { problems.append("\(source.id) changed role") }
        if message.generationID != source.generationID { problems.append("\(source.id) changed generationID") }
        if message.parent != source.parent { problems.append("\(source.id) changed parent") }
        if message.children != source.children { problems.append("\(source.id) changed children") }
        if message.model != source.model { problems.append("\(source.id) changed model") }
        if message.stopInfo != source.stopInfo { problems.append("\(source.id) changed stopInfo") }
        if message.toolRecords != source.toolRecords { problems.append("\(source.id) changed toolRecords") }
        if message.timestamp != source.timestamp { problems.append("\(source.id) changed timestamp") }
        if message.terminalTimestamp != source.terminalTimestamp {
            problems.append("\(source.id) changed terminalTimestamp")
        }

        // The §6.3 three-name table, executable. `.open ⇒ .interrupted` is I5's
        // finalization; every other case must survive classification unchanged,
        // and `.streaming` must be unreachable from any log (§7.4 — liveness is
        // the projection's, and no fold can know the process is alive).
        switch (source.state, message.state) {
        case (.complete(let before), .complete(let after)) where before == after:
            break
        case (.open(let before), .interrupted(let after)) where before == after:
            break
        case (.failed(let before, let error), .failed(let after, let classifiedError, _))
            where before == after && error == classifiedError:
            break
        case (.cancelled(let before), .cancelled(let after)) where before == after:
            break
        default:
            problems.append("\(source.id): folded \(source.state) classified as \(message.state)")
        }

        // I5 — `.interrupted` means no terminal exists, so it can carry no stamp.
        if case .interrupted = message.state, message.terminalTimestamp != nil {
            problems.append("interrupted \(source.id) carries a terminalTimestamp")
        }
    }

    if conversation.activeMessages.count != conversation.activePath.count {
        problems.append("activeMessages dropped a path entry — some entry does not resolve")
    }

    return problems
}

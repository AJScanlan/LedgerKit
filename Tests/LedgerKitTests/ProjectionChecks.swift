import Foundation
@testable import LedgerKit

// **P2 (overlay correctness) as an executable predicate** — SPEC §10.6, §7.4.
// M4 Phase 4 ships the *harness*; `overlay_live` itself is M7's.
//
// P2 has three clauses, and the spec states them together:
//
//   1. for every live `GenerationID`, the projection shows `.streaming` with
//      partial equal to **the live set's value** for that generation;
//   2. for everything else the projection equals the fold;
//   3. the live set is always a subset of *open* (started, un-terminated)
//      generations.
//
// And one line that is the reason this file exists at M4 rather than M7:
// **"crash recovery is P2's degenerate case: empty live set ⇒ overlay is identity
// ⇒ `.interrupted` shows through."** That case is testable today, because it needs
// no overlay — which means the predicates can be written, reviewed and
// *mutation-tested* now, and M7 arrives to a suite that already knows what
// correct looks like. The scaffolding is the parameterization: the overlay is an
// argument, so M7 changes what is passed in, never what is asserted.
//
// ⚠️ **Clause 1's scope, and rev 10 exists because this file was ahead of the spec
// on it.** The predicate compares the shown partial against the **live set** — which
// is the only thing available when the live set is synthetic, and is *tautological*
// against a live store, since the overlay constructs what it shows from the live set.
// Through rev 9, §10.6 phrased clause 1 against the *log* rather than against the
// live set; that stronger property is the **store's** obligation and needs a source
// neither layer computed (the script the provider was driven by). Paraphrased rather
// than quoted, deliberately — quoting the retired sentence would make every future
// retired-phrase sweep re-report this already-fixed site (M6-PLAN Phase 0's finding).
// Discovered by a mutation that
// survived this predicate and was caught only by a script-comparing test; rev 10
// splits the two. So a green P2 means the overlay is faithful to its input — not that
// the input is faithful to the log.
//
// Predicates return `[String]` rather than recording issues, matching
// `InvariantChecks.swift` — the caller attaches the context ("hostile at split
// 7") that makes a failure legible.

// `LiveSet` was declared here from M4 until M7 Phase 1, when `Projection/` began
// shipping the real one. It is the *same* type — `[GenerationID: String]`, the value
// being the full partial to show — so the harness now speaks the production
// vocabulary rather than a parallel copy of it. Deleting the duplicate is the only
// change this file needed to accept `overlay(_:live:)`; no assertion moved.

/// The shape `overlay_live` will have (SPEC §6.3's third pipeline stage).
///
/// Taking it as a value is the whole of "P2 scaffolding": the identity overlay
/// below stands in until M7, and swapping in the real one must not require
/// touching a single assertion.
/// `@Sendable` because the overlay is pure by construction — it reads a
/// conversation and a live set and returns a conversation, capturing nothing
/// mutable. Tenet 6 wants that stated in the type rather than trusted, and M7's
/// projection is `@MainActor`, so the annotation is what lets the same value be
/// held anywhere the actor needs it.
typealias LiveOverlay = @Sendable (Conversation, LiveSet) -> Conversation

/// The overlay a *dead* store applies: none at all.
///
/// Not a placeholder — it is the literally correct overlay for an empty live set,
/// which is the state after a cold open, and the state DoD-1 recovers into. §7.4's
/// composition `overlay_live(classify(fold(log)), ∅) ≡ classify(fold(log))` is a
/// theorem about the real overlay, and this is its degenerate instance.
let identityOverlay: LiveOverlay = { conversation, _ in conversation }

/// P2's three clauses over one projection.
///
/// - Parameters:
///   - projected: what the overlay produced.
///   - classified: `classify(fold(log))` — the dead-log answer the overlay starts
///     from, and the answer it must preserve everywhere it is not live.
///   - folded: the fold beneath it, needed for clause 3: openness is a property of
///     the *folded* layer (`.open`), since classification has already turned open
///     generations into `.interrupted` (I5) and could no longer tell you which
///     ones a live store might legitimately be streaming.
///   - live: the generations this process is generating.
func projectionProblems(
    in projected: Conversation,
    overlaying classified: Conversation,
    foldedFrom folded: FoldedState,
    live: LiveSet
) -> [String] {
    var problems: [String] = []

    // generation → message, from the folded layer. This is the same map a
    // snapshot resume has to rebuild, and the reason `Message.generationID` is
    // public at all.
    var messageForGeneration: [GenerationID: MessageID] = [:]
    for message in folded.messages.values {
        guard let generation = message.generationID else { continue }
        messageForGeneration[generation] = message.id
    }

    // Clause 3 — the live set is a subset of open generations.
    //
    // Checked first because it is a claim about the *store*, not the projection:
    // a live generation that the log says already terminated means the actor
    // failed to unregister it, and every `.streaming` bubble downstream of that is
    // a lie the other two clauses would happily confirm.
    for generation in live.keys.sorted(by: { "\($0)" < "\($1)" }) {
        guard let id = messageForGeneration[generation] else {
            problems.append("live generation \(generation) names no message in the fold")
            continue
        }
        guard let message = folded.messages[id] else {
            problems.append("live generation \(generation) maps to missing message \(id)")
            continue
        }
        if !message.state.isOpen {
            problems.append("live generation \(generation) is \(message.state) in the log, not open")
        }
    }

    // Clauses 1 and 2, per message. Iterated over the folded layer's ids because
    // `MessageTree` keeps its storage private — the same reason
    // `invariantProblems(in:foldedFrom:)` takes the fold.
    for id in folded.messages.keys.sorted(by: { "\($0)" < "\($1)" }) {
        guard let overlaid = projected.messages[id] else {
            problems.append("\(id) was dropped by the overlay")
            continue
        }
        guard let dead = classified.messages[id] else {
            problems.append("\(id) is missing from the classified state")
            continue
        }

        let generation = folded.messages[id]?.generationID
        if let generation, let partial = live[generation] {
            // Clause 1 — live means `.streaming`, carrying exactly the deltas.
            guard case .streaming(let shown) = overlaid.state else {
                problems.append("live \(id) projects as \(overlaid.state), not .streaming")
                continue
            }
            if shown != partial {
                problems.append("live \(id) shows \(shown.count) chars, live set holds \(partial.count)")
            }
            // The overlay changes state and nothing else — a projection that also
            // moved a parent or invented tool records would be rewriting history
            // on the way to the screen.
            var expected = dead
            expected.state = overlaid.state
            if overlaid != expected {
                problems.append("live \(id) had more than its state overlaid")
            }
        } else {
            // Clause 2 — not live, so the projection *is* the fold. With an empty
            // live set this is every message, which is the whole of crash
            // recovery: `.interrupted` reaches the screen untouched.
            if overlaid != dead {
                problems.append("\(id): projected \(overlaid.state) but classified \(dead.state)")
            }
        }
    }

    // Nothing outside the message states belongs to the overlay. `.streaming` is a
    // per-message fact (§6.2); a projection that also rewrote the title, the path
    // or the diagnostics would make live state leak into what the log is supposed
    // to determine (I1).
    if projected.id != classified.id { problems.append("overlay changed the conversation id") }
    if projected.title != classified.title { problems.append("overlay changed the title") }
    if projected.instructions != classified.instructions { problems.append("overlay changed instructions") }
    if projected.activePath != classified.activePath { problems.append("overlay changed activePath") }
    if projected.messages.rootChildren != classified.messages.rootChildren {
        problems.append("overlay changed root-level sibling order")
    }
    if projected.diagnostics != classified.diagnostics { problems.append("overlay changed diagnostics") }

    return problems
}

// MARK: - Test-side overlays

/// Rebuilds a conversation with `transform` applied to each message's state.
///
/// The only way a test can *construct* a differing projection: `Message`'s and
/// `Conversation`'s initializers went internal at M4 Phase 0, so this reaches them
/// through `@testable` — which is exactly the arrangement D13 intended, since
/// nothing outside the reducer is entitled to mint derived state.
func mappingStates(
    of conversation: Conversation,
    ids: [MessageID],
    _ transform: (Message) -> MessageState
) -> Conversation {
    var nodes: [MessageID: Message] = [:]
    for id in ids {
        guard var message = conversation.messages[id] else { continue }
        message.state = transform(message)
        nodes[id] = message
    }
    var projected = conversation
    projected.messages = MessageTree(nodes: nodes, rootChildren: conversation.messages.rootChildren)
    return projected
}

/// A **reference** overlay: live generations become `.streaming` with the live
/// partial, everything else is left alone.
///
/// Deliberately not shipped, and deliberately not the thing under test — M7's real
/// `overlay_live` reads its partials from the store actor's buffer and lives in
/// `Projection/`. It exists here for one reason: without *some* correct overlay,
/// clause 1 and clause 3 would never be exercised on a satisfying input, and a
/// predicate that has only ever been shown failing inputs might be one that
/// nothing can satisfy. This is the control, in the sense `SnapshotDiscardTests`
/// uses the word.
func referenceOverlay(ids: [MessageID], generationOf: [MessageID: GenerationID]) -> LiveOverlay {
    { conversation, live in
        mappingStates(of: conversation, ids: ids) { message in
            guard let generation = generationOf[message.id], let partial = live[generation] else {
                return message.state
            }
            return .streaming(partial: partial)
        }
    }
}

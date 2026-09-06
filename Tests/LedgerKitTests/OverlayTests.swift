import Foundation
import Testing
@testable import LedgerKit

// M7 Phase 1: the real `overlay_live`, against the harness that has been waiting
// for it since M4.
//
// `ProjectionChecks.swift` shipped P2's predicate parameterized over the overlay
// two milestones before the overlay existed, swept over every truncation of every
// fixture with an empty live set, with the predicate itself mutation-tested against
// deliberately wrong projections. Phase 1's whole criterion is that passing the
// real function in **changes no assertion there** — if one had to move, either the
// harness was wrong for two milestones or the overlay is.
//
// It did not. The only edit that file needed was deleting its `LiveSet` typealias,
// now that `Projection/` ships the same type.
//
// Two things are worth knowing about what this file can and cannot falsify.
//
//  - **P2 clause 1 is no longer reachable by a bad *input*.** The plan expected a
//    negative sweep where "a live partial shorter than the folded text" trips the
//    exactness check. That assumed D40's original shape, where the *projection*
//    assembled the shown partial from the folded text plus an accumulator. D47
//    moved that computation into the store, so the overlay now shows `live[gen]`
//    verbatim and `shown == live[gen]` holds by construction. Clause 1 therefore
//    polices the store's arithmetic, not the overlay's — and remains reachable
//    here only as a *mutation*, which is exactly how it is exercised below.
//    That is D47 working: the illegal state became unrepresentable instead of
//    checked.
//  - **Clause 3's two branches are reachable by input**, and both are swept: a
//    live generation the log says terminated, and a live generation naming no
//    message at all.

/// Open (started, un-terminated) generations, sorted for determinism.
///
/// Read off the **folded** layer, because openness is a folded property: `classify`
/// has already turned open generations into `.interrupted` (I5) and could no longer
/// tell you which ones a live store might legitimately be streaming.
private func openGenerations(in folded: FoldedState) -> [GenerationID] {
    folded.messages.values
        .filter(\.state.isOpen)
        .compactMap(\.generationID)
        .sorted { "\($0)" < "\($1)" }
}

/// The text each generation has accumulated in the log so far, keyed for lookup.
private func foldedText(in folded: FoldedState) -> [GenerationID: String] {
    var text: [GenerationID: String] = [:]
    for message in folded.messages.values {
        guard let generation = message.generationID else { continue }
        text[generation] = message.state.text
    }
    return text
}

/// The suffix a store would be holding in its delta buffer but not yet on disk —
/// the difference between what the screen shows and what a crash would recover
/// (§7.4's documented recovery granularity).
private let unflushedTail = "…and the unflushed tail"

@Suite("P2 — the real overlay_live")
struct OverlayTests {

    // MARK: - The function itself

    /// §7.4 states `overlay_live(classify(fold(log)), ∅) ≡ classify(fold(log))` as a
    /// theorem. Asserted as **value equality**, not merely as P2-cleanliness: the
    /// implementation returns its argument untouched, and that is stronger than
    /// "returns something the predicate accepts".
    @Test("an empty live set returns the argument unchanged")
    func emptyLiveSetIsTheIdentity() {
        for fixture in Corpus.all {
            let classified = classify(fixture.log.folded(), mapping: .default)
            #expect(overlay(classified, live: [:]) == classified, "\(fixture.name)")
        }
    }

    /// The one thing the overlay does, and the exact value it must show (D40/D47).
    @Test("a live generation becomes .streaming carrying the live set's value verbatim")
    func liveGenerationStreamsTheGivenPartial() {
        let folded = Corpus.regenerateAfterInterruption.log.folded()
        let classified = classify(folded, mapping: .default)
        // `genA` is the abandoned generation — started, never terminated — so it is
        // the one a live store could legitimately still be streaming.
        #expect(classified.messages[Fix.assistantA]?.state == .interrupted(partial: "A valley fol"))

        let shown = "A valley fol" + unflushedTail
        let projected = overlay(classified, live: [Fix.genA: shown])

        // Verbatim, not "starts with", not "contains": the store computed the whole
        // partial, so any transformation here would be the projection inventing
        // text (D47).
        #expect(projected.messages[Fix.assistantA]?.state == .streaming(partial: shown))
        // The completed sibling is untouched — liveness is per-generation, and the
        // branch beside it is dead history (§6.4).
        #expect(projected.messages[Fix.assistantB]?.state == classified.messages[Fix.assistantB]?.state)
    }

    /// **State, and provably nothing else** (D49). The narrow `updateStates` makes
    /// most of this unrepresentable rather than merely untrue, which is why the
    /// assertions read as a formality — that is the point of moving the guarantee
    /// into the type.
    @Test("the overlay changes message state and nothing else")
    func overlayTouchesOnlyState() throws {
        let folded = Corpus.regenerateAfterInterruption.log.folded()
        let classified = classify(folded, mapping: .default)

        let projected = overlay(classified, live: [Fix.genA: "anything"])

        #expect(projected.id == classified.id)
        #expect(projected.title == classified.title)
        #expect(projected.instructions == classified.instructions)
        #expect(projected.activePath == classified.activePath)
        #expect(projected.diagnostics == classified.diagnostics)
        #expect(projected.messages.rootChildren == classified.messages.rootChildren)

        // Per-node, on the very message that *was* overlaid — the only place a
        // sloppy rebuild could have lost something.
        let before = try #require(classified.messages[Fix.assistantA])
        let after = try #require(projected.messages[Fix.assistantA])
        #expect(after.id == before.id)
        #expect(after.role == before.role)
        #expect(after.generationID == before.generationID)
        #expect(after.parent == before.parent)
        #expect(after.children == before.children)
        #expect(after.model == before.model)
        #expect(after.stopInfo == before.stopInfo)
        #expect(after.toolRecords == before.toolRecords)
        #expect(after.timestamp == before.timestamp)
        #expect(after.terminalTimestamp == before.terminalTimestamp)
    }

    // MARK: - P2 over the corpus

    /// **P2, completed.** Every fixture, every truncation, every subset of that
    /// truncation's open generations.
    ///
    /// A truncation *is* a crash, so this sweeps the states a killed process
    /// actually leaves behind — and then asks what a *live* store would render over
    /// each of them. The live partial is the folded text plus a synthetic unflushed
    /// tail, which is the shape D47 says the store computes: what the screen shows
    /// minus what disk has is exactly the delta a crash would cost.
    ///
    /// Exhaustive rather than sampled, per §10.6: fixtures are ≤22 rows and open
    /// generations are few, so there is no seed to manage and a failure reproduces
    /// by re-running.
    @Test("every truncation, overlaid with every subset of its open generations, satisfies P2")
    func p2OverTheCorpus() {
        var checks = 0
        var liveChecks = 0
        var streamingSeen = 0
        var interruptedSeen = 0
        var widestLiveSet = 0

        for fixture in Corpus.all {
            for length in 0...fixture.log.rows.count {
                let rows = Array(fixture.log.rows.prefix(length))
                let folded = fold(rows, for: fixture.log.conversation)
                let classified = classify(folded, mapping: .default)

                let open = openGenerations(in: folded)
                let text = foldedText(in: folded)

                // Every subset, by bitmask over the sorted list — including the
                // empty one, which is the cold open and the state DoD-1 recovers
                // into.
                for mask in 0..<(1 << open.count) {
                    var live: LiveSet = [:]
                    for (index, generation) in open.enumerated() where mask & (1 << index) != 0 {
                        live[generation] = (text[generation] ?? "") + unflushedTail
                    }

                    let projected = overlay(classified, live: live)
                    let problems = projectionProblems(
                        in: projected,
                        overlaying: classified,
                        foldedFrom: folded,
                        live: live
                    )
                    #expect(problems.isEmpty, "\(fixture.name) at \(length), live \(live.count): \(problems)")

                    checks += 1
                    if !live.isEmpty { liveChecks += 1 }
                    widestLiveSet = max(widestLiveSet, live.count)
                    for id in folded.messages.keys {
                        switch projected.messages[id]?.state {
                        case .streaming: streamingSeen += 1
                        case .interrupted: interruptedSeen += 1
                        default: break
                        }
                    }
                }
            }
        }

        // **Non-vacuity in four dimensions**, because this sweep's failure mode is
        // silently checking nothing interesting. The bounds are the *measured*
        // values rounded down rather than guesses — a guessed bound is a test that
        // fails later for the wrong reason, and the first draft of this one did.
        #expect(checks >= 120, "only \(checks) projections swept")           // measured 132
        #expect(liveChecks >= 30, "only \(liveChecks) had anything live")    // measured 38
        // Two concurrent live generations is the only shape that can catch an
        // overlay keyed on the wrong generation — §6.5's log-level concurrency,
        // which the reducer has always tolerated even though the v0.1 store
        // enforces single-flight above it.
        #expect(widestLiveSet >= 2, "never reached two concurrent live generations")
        // Both ends of the three-name table were actually reached: `.streaming`
        // where a live store is generating, `.interrupted` where the same
        // truncation has no overlay to hide it. Without these the sweep could pass
        // over a corpus of nothing but completed turns, having never once shown
        // that either half works.
        #expect(streamingSeen > 0, "no projection ever rendered .streaming")
        #expect(interruptedSeen > 0, "no truncation left an interrupted message to show through")
    }

    // MARK: - Live sets that lie (clause 3)

    /// Clause 3, branch one: the store claims a generation the log says finished.
    ///
    /// The overlay flips it anyway, deliberately (see its own note): declining
    /// would make the projection disagree with the live set it was handed, and P2
    /// would then report a clause-1 mismatch *as well*, pointing two fingers at the
    /// overlay for a defect one layer up. Flipping leaves exactly one failure,
    /// naming the store.
    @Test("a live set naming a terminated generation is caught, and only clause 3 fires")
    func liveSetOutrunsTheLog() {
        let folded = Corpus.regenerateAfterInterruption.log.folded()
        let classified = classify(folded, mapping: .default)
        // `genB` completed, so no store may claim it is live.
        let live: LiveSet = [Fix.genB: "A valley fold brings the paper down."]

        let problems = projectionProblems(
            in: overlay(classified, live: live),
            overlaying: classified,
            foldedFrom: folded,
            live: live
        )

        #expect(problems.contains { $0.contains("not open") })
        // One finding, not two — the diagnostic-clarity claim the overlay's
        // unconditional flip buys.
        #expect(problems.count == 1, "expected clause 3 alone, got \(problems)")
    }

    /// Clause 3, branch two: a generation that names no message at all — a live set
    /// that has outlived its conversation, or was keyed from the wrong one.
    @Test("a live generation naming no message is caught")
    func liveSetNamesNoMessage() {
        let folded = Corpus.ordinaryTurn.log.folded()
        let classified = classify(folded, mapping: .default)
        let live: LiveSet = [Fix.genB: "text for a generation this log never had"]

        let problems = projectionProblems(
            in: overlay(classified, live: live),
            overlaying: classified,
            foldedFrom: folded,
            live: live
        )

        #expect(problems.contains { $0.contains("names no message") })
    }
}

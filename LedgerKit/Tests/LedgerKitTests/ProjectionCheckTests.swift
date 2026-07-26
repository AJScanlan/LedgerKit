import Foundation
import Testing
@testable import LedgerKit

// P2's harness, exercised (M4 Phase 4). Two halves, and both are necessary:
//
//  - **The sweep** runs the empty-live-set case over the whole corpus. That case
//    is not a placeholder — it is the state every cold open lands in, so this is
//    DoD-1's guarantee stated as a projection property: with nothing live,
//    `.interrupted` reaches the screen.
//  - **The predicate tests** feed `projectionProblems` deliberately wrong
//    projections. This is `InvariantCheckTests`' argument, transplanted: a
//    predicate that returns `[]` for everything would make the sweep above pass
//    while enforcing nothing, and the sweep is the part that will still be running
//    at M7 when a real overlay is wired in.

@Suite("P2 — projection equivalence, empty live set")
struct ProjectionEquivalenceTests {

    @Test("with nothing live, the overlay is the identity and the fold shows through")
    func emptyLiveSetIsIdentity() {
        // §10.6: "crash recovery is P2's degenerate case: empty live set ⇒ overlay
        // is identity ⇒ `.interrupted` shows through." Run over every fixture and
        // every truncation, because a truncation *is* a crash — so this sweeps
        // exactly the states a killed process leaves behind.
        var interrupted = 0
        var checks = 0

        for fixture in Corpus.all {
            for length in 0...fixture.log.rows.count {
                let rows = Array(fixture.log.rows.prefix(length))
                let folded = fold(rows, for: fixture.log.conversation)
                let classified = classify(folded, mapping: .default)
                let projected = identityOverlay(classified, [:])

                let problems = projectionProblems(
                    in: projected,
                    overlaying: classified,
                    foldedFrom: folded,
                    live: [:]
                )
                #expect(problems.isEmpty, "\(fixture.name) at \(length): \(problems)")
                checks += 1

                for id in folded.messages.keys.sorted(by: { "\($0)" < "\($1)" }) {
                    if case .interrupted = projected.messages[id]?.state { interrupted += 1 }
                }
            }
        }

        // Non-vacuity, both dimensions: the sweep ran, and it reached the state the
        // clause above is *about*. Without the second bound this test would pass on
        // a corpus of nothing but completed generations, having never once shown
        // that a crash survives the projection.
        #expect(checks >= 80, "only \(checks) projections swept")
        #expect(interrupted > 0, "no truncation left an interrupted message to show through")
    }

    @Test("a live generation projects as .streaming, and only it does")
    func liveGenerationStreams() {
        // Clause 1 and clause 3 on a satisfying input, via the reference overlay.
        // The point is not to test that overlay — M7 writes the real one — but to
        // prove the predicate is satisfiable with a non-empty live set, so the
        // failing cases below mean something.
        let log = Corpus.regenerateAfterInterruption.log
        let folded = log.folded()
        let classified = classify(folded, mapping: .default)

        let ids = folded.messages.keys.sorted { "\($0)" < "\($1)" }
        var generationOf: [MessageID: GenerationID] = [:]
        for id in ids {
            generationOf[id] = folded.messages[id]?.generationID
        }

        // `genA` is the abandoned generation — started, never terminated — so it is
        // the one a live store could legitimately still be streaming.
        let live: LiveSet = [Fix.genA: "A valley fol"]
        let projected = referenceOverlay(ids: ids, generationOf: generationOf)(classified, live)

        #expect(
            projectionProblems(in: projected, overlaying: classified, foldedFrom: folded, live: live).isEmpty
        )
        #expect(projected.messages[Fix.assistantA]?.state == .streaming(partial: "A valley fol"))
        // The completed sibling is untouched: liveness is per-generation, and the
        // branch beside it is dead history (§6.4).
        #expect(projected.messages[Fix.assistantB]?.state == classified.messages[Fix.assistantB]?.state)
    }
}

@Suite("P2 — the harness itself")
struct ProjectionCheckTests {

    /// A log with one interrupted generation (`genA`) and one completed (`genB`).
    private var fixture: (folded: FoldedState, classified: Conversation, ids: [MessageID]) {
        let folded = Corpus.regenerateAfterInterruption.log.folded()
        let classified = classify(folded, mapping: .default)
        return (folded, classified, folded.messages.keys.sorted { "\($0)" < "\($1)" })
    }

    @Test("an overlay that fakes .streaming with nothing live is caught")
    func streamingWithoutLiveness() {
        // The failure this whole property exists to prevent, and the one that would
        // be invisible in a screenshot: a dead conversation rendering a spinner
        // forever, because the projection claimed liveness the store never had.
        let (folded, classified, ids) = fixture
        let projected = mappingStates(of: classified, ids: ids) { message in
            if case .interrupted(let partial) = message.state { .streaming(partial: partial) } else { message.state }
        }

        let problems = projectionProblems(in: projected, overlaying: classified, foldedFrom: folded, live: [:])
        #expect(!problems.isEmpty, "an .interrupted message shown as .streaming must be caught")
    }

    @Test("an overlay that ignores a live generation is caught")
    func liveGenerationLeftDead() {
        // The dual, and the one that ships as "the bubble never updates": the store
        // is generating, and the projection is still showing the dead-log answer.
        let (folded, classified, _) = fixture
        let live: LiveSet = [Fix.genA: "A valley fol"]

        let problems = projectionProblems(in: classified, overlaying: classified, foldedFrom: folded, live: live)
        #expect(problems.contains { $0.contains("not .streaming") })
    }

    @Test("a live projection showing the wrong partial is caught")
    func wrongPartial() {
        // §10.6 says the partial equals *the concatenated deltas*, so an overlay
        // that streams stale or truncated text is a P2 violation rather than a
        // cosmetic one — it is the difference between the screen and the log.
        let (folded, classified, ids) = fixture
        let live: LiveSet = [Fix.genA: "A valley fol"]
        let projected = mappingStates(of: classified, ids: ids) { message in
            message.generationID == Fix.genA ? .streaming(partial: "A valley") : message.state
        }

        let problems = projectionProblems(in: projected, overlaying: classified, foldedFrom: folded, live: live)
        #expect(problems.contains { $0.contains("chars") })
    }

    @Test("a live set naming an already-terminated generation is caught")
    func liveSetOutrunsTheLog() {
        // Clause 3. `genB` completed, so no store may claim it is live — that is
        // the store failing to unregister an in-flight generation (§6.5), and the
        // projection would then stream over a finished message forever.
        let (folded, classified, ids) = fixture
        let live: LiveSet = [Fix.genB: "A valley fold brings the paper down."]
        let projected = mappingStates(of: classified, ids: ids) { message in
            message.generationID == Fix.genB ? .streaming(partial: live[Fix.genB] ?? "") : message.state
        }

        let problems = projectionProblems(in: projected, overlaying: classified, foldedFrom: folded, live: live)
        #expect(problems.contains { $0.contains("not open") })
    }

    @Test("an overlay that changes anything but message state is caught")
    func overlayTouchesMoreThanState() {
        // The overlay's whole remit is `.streaming` (§6.3). Everything else on a
        // `Conversation` is what the *log* determined, and a projection allowed to
        // edit it would put live state on the wrong side of I1.
        let (folded, classified, _) = fixture
        var projected = classified
        projected.title = "live edit"

        let problems = projectionProblems(in: projected, overlaying: classified, foldedFrom: folded, live: [:])
        #expect(problems.contains { $0.contains("title") })

        var dropped = classified
        dropped.diagnostics = []
        var withResidue = classified
        withResidue.diagnostics = [QuarantinedEvent(sequence: 1, reason: .beforeGenesis)]
        #expect(
            projectionProblems(in: dropped, overlaying: withResidue, foldedFrom: folded, live: [:])
                .contains { $0.contains("diagnostics") }
        )
    }

    @Test("an overlay that drops a message is caught")
    func overlayDropsAMessage() {
        // A projection is a *view* of the fold, so it has no license to lose a
        // node — and a dropped one would otherwise sail past clause 2, which only
        // ever compares messages it can find on both sides.
        let (folded, classified, ids) = fixture
        let projected = mappingStates(of: classified, ids: Array(ids.dropFirst())) { $0.state }

        let problems = projectionProblems(in: projected, overlaying: classified, foldedFrom: folded, live: [:])
        #expect(problems.contains { $0.contains("dropped by the overlay") })
    }

    @Test("the identity overlay on a healthy log produces no problems")
    func identityIsClean() {
        // The control (`SnapshotDiscardTests`' pattern): without it, every test
        // above could pass because the predicate complains about *everything*,
        // which would be a very quiet way to make the M7 sweep useless.
        let (folded, classified, _) = fixture
        #expect(
            projectionProblems(
                in: identityOverlay(classified, [:]),
                overlaying: classified,
                foldedFrom: folded,
                live: [:]
            ).isEmpty
        )
    }
}

import Foundation
import Testing
@testable import LedgerKit

// Generic predicates run over every corpus fixture and every mutation of it.
// Nothing here knows what a fixture contains — that is the point: adding a
// fixture to `Corpus.all` buys it all of this coverage for free.
//
// Phase 2 grows this file into the crash-point fuzzing suite (SPEC §10.3):
// interior-gap variants, the compound truncation × gap sweep, and the I5
// partial-content sweep. The truncation and split sweeps below are the shape
// those inherit.

@Suite("Corpus — invariant sweeps")
struct CorpusSweepTests {

    @Test("I1: the same log folds to the same state")
    func determinismRepeat() {
        for fixture in Corpus.all {
            #expect(fixture.log.folded() == fixture.log.folded(), "\(fixture.name) is not self-consistent")
        }
    }

    @Test("I2: every prefix of every fixture reduces without trapping, and holds its invariants")
    func totalityOverPrefixes() {
        // Suffix truncation — a down payment on Phase 2's crash-point fuzzing,
        // which adds interior-gap variants on top of this.
        //
        // Both layers are checked at every prefix: the fold's structural
        // invariants, and the fold→classify correspondence, which is where I5's
        // `.open ⇒ .interrupted` finalization lives. A truncation is exactly a
        // process death, so every prefix that ends mid-generation is a crash the
        // reducer has to survive *and* classify honestly.
        for fixture in Corpus.all {
            for length in 0...fixture.log.rows.count {
                let rows = Array(fixture.log.rows.prefix(length))
                let state = fold(rows, for: fixture.log.conversation)
                #expect(
                    invariantProblems(in: state).isEmpty,
                    "\(fixture.name) truncated at \(length): \(invariantProblems(in: state))"
                )

                let conversation = Conversation(reducing: rows, loadedFrom: fixture.log.conversation)
                let problems = invariantProblems(in: conversation, foldedFrom: state)
                #expect(problems.isEmpty, "\(fixture.name) classified at \(length): \(problems)")
            }
        }
    }

    @Test("I6: the clamping branch is dead — no truncation produces a broken path")
    func clampingIsUnreachable() {
        // §6.6's clamp exists for a path invalidated by a later quarantine, which
        // I believe unreachable in v0.1 because nothing removes messages. If this
        // ever fails, that belief was wrong and the clamp needs real semantics.
        for fixture in Corpus.all {
            for length in 0...fixture.log.rows.count {
                let state = fold(Array(fixture.log.rows.prefix(length)), for: fixture.log.conversation)
                guard let head = state.activePath.first else { continue }
                #expect(
                    state.messages[head]?.parent == nil,
                    "\(fixture.name) at \(length): path head is not root-level, so clamping fired"
                )
            }
        }
    }

    @Test("P3: resuming at every split point equals folding the whole log")
    func resumeAtEverySplit() {
        // The snapshot fast-path is a second reduction path, and rev 3 shipped it
        // untested. Every split is a different reconstruction of the routing map
        // from `FoldedMessage.generationID`, including splits that land
        // mid-generation and splits that straddle an interior gap.
        for fixture in Corpus.all {
            let whole = fixture.log.folded()
            for split in 0...fixture.log.rows.count {
                let prefix = Array(fixture.log.rows.prefix(split))
                let checkpoint = fold(prefix, for: fixture.log.conversation)
                let resumed = fold(
                    resuming: checkpoint,
                    after: prefix.last?.sequence ?? 0,
                    with: Array(fixture.log.rows.dropFirst(split))
                )
                #expect(resumed == whole, "\(fixture.name) split at \(split)")
            }
        }
    }
}

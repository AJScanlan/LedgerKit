import Foundation
import Testing
@testable import LedgerKit

// Generic predicates run over every corpus fixture and every mutation of it.
// Nothing here knows what a fixture contains — that is the point: adding a
// fixture to `Corpus.all` buys it all of this coverage for free.
//
// The crash-point fuzzing suite (SPEC §10.3, "the single highest-value suite")
// lives at the bottom of this file. Enumeration is exhaustive rather than
// randomised: fixture logs are ≤ 22 rows, so every prefix and every interior
// window fits in milliseconds, and exhaustive beats random here on all three
// axes that matter — no seed to manage, no flake, and a failure that reproduces
// by re-running rather than by recovering a seed from CI logs.

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

// MARK: - Crash-point fuzzing (SPEC §10.3)

/// Truncate every fixture at every prefix; knock every contiguous interior
/// window out of every fixture; then do both at once. Assert a valid state,
/// correct `.interrupted` synthesis (I5) and no traps (I2) throughout.
///
/// Two of these sweeps carry an *independent* oracle rather than only structural
/// predicates — a property test whose expectation is computed by the code under
/// test proves nothing. Both oracles are deliberately simpler than the fold:
/// one counts contiguous holes in a sequence run, the other concatenates delta
/// text. Neither reimplements routing, tree-building or quarantine.
@Suite("Corpus — crash-point fuzzing")
struct CrashFuzzTests {

    /// Contiguous holes a sequence run has, by the §6.1 rule: one diagnostic per
    /// hole, positioned at its first missing sequence. Mirrors the fold's cursor
    /// — a running maximum that never rewinds, which is why an out-of-order row
    /// cannot manufacture a gap (§6.6, ordering non-rule).
    private func expectedGaps(in rows: [LoadedEvent]) -> [ClosedRange<Int64>] {
        var expected: Int64 = 1
        var gaps: [ClosedRange<Int64>] = []
        for row in rows {
            if row.sequence > expected { gaps.append(expected...(row.sequence - 1)) }
            expected = max(expected, row.sequence + 1)
        }
        return gaps
    }

    private func actualGaps(in state: FoldedState) -> [ClosedRange<Int64>] {
        state.diagnostics.compactMap {
            if case .sequenceGap(let missing) = $0.reason { missing } else { nil }
        }
    }

    // MARK: Suffix truncation — the crash

    @Test("the fold is incremental: every prefix is a state the full log passed through")
    func truncationIsMonotone() {
        // The crash-recovery guarantee, stated as a property. Process death can
        // land between any two rows, so the state at every prefix must be one the
        // full reduction genuinely passed through — messages only appear, text
        // only accumulates, terminals never move, diagnostics only append. A fold
        // that revised an earlier conclusion on later evidence would break this
        // while every fixed-point expectation stayed green.
        for fixture in Corpus.all {
            let rows = fixture.log.rows
            guard !rows.isEmpty else { continue }

            for length in 0..<rows.count {
                let before = fold(Array(rows.prefix(length)), for: fixture.log.conversation)
                let after = fold(Array(rows.prefix(length + 1)), for: fixture.log.conversation)
                let context = "\(fixture.name) \(length)→\(length + 1)"

                for (id, source) in before.messages.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                    guard let grown = after.messages[id] else {
                        Issue.record("\(context): message \(id) disappeared")
                        continue
                    }
                    #expect(
                        grown.state.text.hasPrefix(source.state.text),
                        "\(context): \(id) text is not an extension of what it was"
                    )
                    if !source.state.isOpen {
                        #expect(grown.state == source.state, "\(context): terminal \(id) changed state")
                    }
                    #expect(
                        grown.toolRecords.starts(with: source.toolRecords),
                        "\(context): \(id) tool records were rewritten, not appended"
                    )
                }

                #expect(
                    after.diagnostics.starts(with: before.diagnostics),
                    "\(context): diagnostics were rewritten, not appended"
                )
                #expect(
                    after.rootChildren.starts(with: before.rootChildren),
                    "\(context): root-level sibling order was rewritten"
                )
            }
        }
    }

    @Test("I5: at every truncation of a healthy log, the partial is exactly the surviving deltas")
    func interruptionIsExactAcrossTruncations() {
        // Restricted to golden fixtures on purpose: the oracle below assumes
        // every event applied, which is precisely what zero residue means. On a
        // hostile log it would have to replicate the quarantine table to know
        // which deltas counted — i.e. become the fold, and prove nothing.
        var partialsChecked = 0

        for fixture in Corpus.all where fixture.kind == .golden {
            for length in 0...fixture.log.rows.count {
                let rows = Array(fixture.log.rows.prefix(length))
                let conversation = Conversation(reducing: rows, loadedFrom: fixture.log.conversation)

                var message: [GenerationID: MessageID] = [:]
                var partial: [GenerationID: String] = [:]
                var terminated: Set<GenerationID> = []
                var order: [GenerationID] = []

                for row in rows {
                    guard case .decoded(let event) = row else { continue }
                    switch event.payload {
                    case .generationStarted(generation: let generation, let id, _, _):
                        message[generation] = id
                        order.append(generation)
                    case .deltaAppended(generation: let generation, let text):
                        partial[generation, default: ""] += text
                    case .generationEnded(let generation, _):
                        terminated.insert(generation)
                    default:
                        break
                    }
                }

                for generation in order {
                    guard let id = message[generation] else { continue }
                    let context = "\(fixture.name) at \(length), generation \(generation)"
                    if terminated.contains(generation) {
                        if case .interrupted = conversation.messages[id]?.state {
                            Issue.record("\(context): terminated, yet classified .interrupted")
                        }
                    } else {
                        let text = partial[generation] ?? ""
                        if !text.isEmpty { partialsChecked += 1 }
                        #expect(
                            conversation.messages[id]?.state == .interrupted(partial: text),
                            "\(context): interruption must carry exactly the deltas that survived"
                        )
                    }
                }
            }
        }

        // Without this, a corpus of only-completed generations would make the
        // interesting branch unreachable and the sweep would pass by never
        // testing interruption at all.
        #expect(partialsChecked > 0, "no truncation left a generation open with text — I5 was never exercised")
    }

    @Test("truncating a healthy log cannot manufacture residue — every rule looks backwards")
    func goldenPrefixesStayClean() {
        // Worth stating because it is what makes the oracle above legitimate:
        // no quarantine rule consults a *later* row, so removing the tail can
        // never retroactively invalidate what came before.
        for fixture in Corpus.all where fixture.kind == .golden {
            for length in 0...fixture.log.rows.count {
                let state = fold(Array(fixture.log.rows.prefix(length)), for: fixture.log.conversation)
                #expect(state.residue.isEmpty, "\(fixture.name) truncated at \(length) grew residue")
            }
        }
    }

    // MARK: Interior gaps — partial restore, tampering, bit rot

    @Test("interior gaps: one diagnostic per contiguous hole, however the holes merge")
    func interiorGapSweep() {
        // Every contiguous window removed from every fixture. Windows adjacent to
        // a fixture's existing `skip` are the interesting ones: they must *merge*
        // into a single wider diagnostic rather than produce two, which is what
        // the oracle checks without knowing anything about how the fold counts.
        var mutations = 0
        var widened = 0

        for fixture in Corpus.all {
            let rows = fixture.log.rows
            guard !rows.isEmpty else { continue }

            for start in rows.indices {
                for length in 1...(rows.count - start) {
                    var mutated = rows
                    mutated.removeSubrange(start..<(start + length))
                    let context = "\(fixture.name) minus rows \(start)..<\(start + length)"
                    mutations += 1

                    let state = fold(mutated, for: fixture.log.conversation)
                    let problems = invariantProblems(in: state)
                    #expect(problems.isEmpty, "\(context): \(problems)")

                    let gaps = expectedGaps(in: mutated)
                    if gaps.contains(where: { $0.count > 1 }) { widened += 1 }
                    #expect(
                        actualGaps(in: state) == gaps,
                        "\(context): gap diagnostics do not match the holes in the run"
                    )

                    let conversation = Conversation(reducing: mutated, loadedFrom: fixture.log.conversation)
                    let bridged = invariantProblems(in: conversation, foldedFrom: state)
                    #expect(bridged.isEmpty, "\(context) classified: \(bridged)")
                }
            }
        }

        // Non-vacuity, in the spirit of `InvariantCheckTests`: a sweep narrowed
        // to nothing passes silently, and this is the package's highest-value
        // suite to lose that way. The second bound is the one that matters —
        // it proves holes adjacent to a fixture's existing `skip` really did
        // merge into one wider diagnostic, rather than that case never arising.
        #expect(mutations >= 400, "the interior-gap sweep collapsed to \(mutations) mutations")
        #expect(widened > 0, "no mutation produced a multi-row hole; merging was never exercised")
    }

    // MARK: Compound — a crash during a partial restore

    @Test("truncation on top of an interior gap still reduces to a valid state")
    func compoundSweep() {
        // The shape a real disaster has: a log restored with a hole in it, from a
        // process that then died mid-generation. Run on the two richest fixtures
        // only — the cost is cubic in row count, and narrower fixtures explore no
        // interaction the wide ones don't already contain.
        var iterations = 0

        for fixture in [Corpus.rich, Corpus.hostile] {
            let rows = fixture.log.rows

            for start in rows.indices {
                for length in 1...(rows.count - start) {
                    var gapped = rows
                    gapped.removeSubrange(start..<(start + length))

                    for prefix in 0...gapped.count {
                        let mutated = Array(gapped.prefix(prefix))
                        let context = "\(fixture.name) minus \(start)..<\(start + length), truncated at \(prefix)"
                        iterations += 1

                        let state = fold(mutated, for: fixture.log.conversation)
                        let problems = invariantProblems(in: state)
                        #expect(problems.isEmpty, "\(context): \(problems)")

                        let conversation = Conversation(reducing: mutated, loadedFrom: fixture.log.conversation)
                        let bridged = invariantProblems(in: conversation, foldedFrom: state)
                        #expect(bridged.isEmpty, "\(context) classified: \(bridged)")
                    }
                }
            }
        }

        #expect(iterations >= 3_000, "the compound sweep collapsed to \(iterations) iterations")
    }

    @Test("P3 survives mutation: resume equals replay on gapped and truncated logs")
    func resumeEqualsReplayUnderMutation() {
        // The snapshot fast-path is a second reduction path, and a damaged log is
        // exactly when a stale checkpoint is most likely to be resumed from.
        for fixture in Corpus.all {
            let rows = fixture.log.rows
            guard !rows.isEmpty else { continue }

            for start in rows.indices {
                var mutated = rows
                mutated.remove(at: start)
                let whole = fold(mutated, for: fixture.log.conversation)

                for split in 0...mutated.count {
                    let head = Array(mutated.prefix(split))
                    let resumed = fold(
                        resuming: fold(head, for: fixture.log.conversation),
                        after: head.last?.sequence ?? 0,
                        with: Array(mutated.dropFirst(split))
                    )
                    #expect(
                        resumed == whole,
                        "\(fixture.name) minus row \(start), split at \(split)"
                    )
                }
            }
        }
    }
}

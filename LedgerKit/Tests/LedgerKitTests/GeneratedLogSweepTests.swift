import Foundation
import Testing
@testable import LedgerKit

// Sweeps over bounded-exhaustive generated logs (see `LogGenerator.swift` for
// what is generated and why). Nothing here knows what any particular log
// contains — every assertion is a predicate that must hold for *any* log
// whatsoever, which is the only kind of assertion a generated input can carry.
//
// **The oracle problem, and how it is already solved here.** The usual reason
// property-based testing stalls is that a generated input has no expected
// output: you cannot hand-write the `FoldedState` for a log you have never seen,
// and computing one means writing a second reducer — which is the same reducer's
// bugs, twice. This package sidestepped that at M3 without setting out to:
// `invariantProblems(in:)` and `invariantProblems(in:foldedFrom:)` are
// *universal* predicates over any state, and `InvariantCheckTests` already tests
// them against deliberately wrong states so they cannot pass vacuously. They
// were built for the corpus sweeps; they cost nothing to point at new inputs.
//
// Two oracles below are new, and both are metamorphic — they compare the
// reducer against *itself* under a transformation, so neither needs an expected
// value:
//
// - **Containment** makes I2's normative sentence executable for the first time.
//   §6.2 says a quarantined event is skipped and "reduction continues as if the
//   event were absent". Until now that was asserted per-fixture as an expected
//   diagnostic list, which checks that the *right* rows were rejected but never
//   that a rejected row left nothing behind. A guard that mutates before
//   returning its rejection passes every existing test.
// - **Accounting** checks the diagnostic list is a faithful census of the rows:
//   one entry per rejected row, no more, each naming a row that exists.
//
// **On `#expect` at this scale.** The sweeps below call it once per *test*, not
// once per log. Half a million recorded expectations is minutes of bookkeeping
// for the same information, and the failure that matters is the first
// counterexample, not the millionth. `SweepFailures` accumulates instead,
// keeping the first few reproductions and counting the rest — and takes its
// message as an `@autoclosure` so the happy path never builds a string it
// throws away, which at these iteration counts is the difference between a
// sweep that runs in CI and one that does not.
//
// **Two tiers, and the split is a measurement rather than a preference.** The
// whole of the rest of this package's suite runs in about a second. A length-4
// sweep is 457k logs and takes ~25s on this machine — 96% of the total, which
// in a project with a one-second feedback loop is not a tax but a different
// regime. So length 3 (17.5k logs, ~1s) runs on every invocation, and length 4
// is env-gated. The gated tier is not a nicety: length 4 is the shortest that
// reaches an event whose meaning depends on a *complete* generation lifecycle —
// a delta after its own terminal (I4), a second terminal (I3/row 10), a start
// reusing the message a finished generation bound (I7). Its home is the weekly
// scheduled CI run, which exists precisely to run things when nothing in the
// repo changed.

/// Set `LEDGERKIT_DEEP=1` for the length-4 sweep (~25s). Spelled as a trait
/// rather than an early `return`, per the house rule the session gates already
/// follow: a `guard` that bails turns a test that did not run into a silent
/// green tick, where `.enabled(if:)` reports it as *skipped*.
let deepSweepEnabled = ProcessInfo.processInfo.environment["LEDGERKIT_DEEP"] == "1"

/// Accumulates counterexamples so a sweep reports once rather than per input.
private struct SweepFailures {
    /// Enough to see whether a failure is one bug or a family; past that the
    /// count carries the information and more examples only bury the first.
    static let exampleLimit = 5

    private(set) var count = 0
    private(set) var examples: [String] = []

    var isEmpty: Bool { count == 0 }

    /// - Parameter description: Built only when something has actually failed.
    mutating func record(_ description: @autoclosure () -> String) {
        count += 1
        if examples.count < Self.exampleLimit { examples.append(description()) }
    }

    func summary(over logs: Int) -> String {
        """
        \(count) of \(logs) generated logs failed. First \(examples.count):
        \(examples.joined(separator: "\n"))
        """
    }
}

/// Everything a single generated log must satisfy, in one pass.
///
/// Bundled rather than split across one test per oracle because the enumeration
/// — not the checking — is the expensive part, and running it five times to
/// assert five things buys nothing but five times the runtime. The failure
/// message names which oracle fired, so isolation survives the bundling.
private func problems(in log: Log) -> [String] {
    var problems: [String] = []
    let rows = log.rows
    let folded = fold(rows, for: log.conversation)

    // The two predicates the corpus sweeps already use, pointed at new inputs.
    problems += invariantProblems(in: folded).map { "fold: \($0)" }

    let conversation = Conversation(reducing: rows, loadedFrom: log.conversation)
    problems += invariantProblems(in: conversation, foldedFrom: folded).map { "classify: \($0)" }

    // Accounting — the diagnostic list as a census. Generated logs are
    // contiguous by construction (`Log` assigns sequences with no holes), so
    // there are no gap diagnostics and every entry must name a row that exists.
    // Strictly increasing is the load-bearing half: `invariantProblems` already
    // checks the list is *sorted*, which a row quarantined twice would satisfy.
    let rowSequences = Set(rows.map(\.sequence))
    let diagnosed = folded.diagnostics.map(\.sequence)
    if diagnosed != Array(Set(diagnosed)).sorted() {
        problems.append("accounting: a row was quarantined more than once (\(diagnosed))")
    }
    for sequence in diagnosed where !rowSequences.contains(sequence) {
        problems.append("accounting: diagnostic at \(sequence) names no row")
    }

    // Containment (I2) — refolding without the rejected rows must reproduce the
    // state exactly. Pruning leaves the surviving rows' sequences untouched, so
    // their timestamps are unchanged and only *diagnostics* may legitimately
    // differ: the holes left behind register as gaps, which is why the
    // comparison drops them. Anything else differing means a quarantined event
    // changed the fold on its way to being rejected.
    let rejected = Set(diagnosed)
    if !rejected.isEmpty {
        let survivors = rows.filter { !rejected.contains($0.sequence) }
        let pruned = fold(survivors, for: log.conversation)
        if ignoringDiagnostics(pruned) != ignoringDiagnostics(folded) {
            problems.append("containment: quarantined rows \(rejected.sorted()) changed the fold")
        }
    }

    return problems
}

/// `FoldedState` minus its diagnostics, for comparisons where the residue is
/// expected to differ but nothing else may.
private func ignoringDiagnostics(_ state: FoldedState) -> FoldedState {
    var copy = state
    copy.diagnostics = []
    return copy
}

@Suite("Generated logs — bounded-exhaustive sweeps")
struct GeneratedLogSweepTests {

    /// Runs all four oracles over every log of `length` generated events.
    ///
    /// Shared by both tiers so they cannot drift: the deep sweep must be the
    /// same assertions over a longer enumeration, never a second set of
    /// expectations that happens to be gated.
    private static func sweep(ofLength length: Int) {
        var failures = SweepFailures()
        LogGenerator.forEachLog(ofLength: length) { log, shapes in
            let found = problems(in: log)
            if !found.isEmpty {
                failures.record("  [\(shapes.reproduction)] \(found.joined(separator: "; "))")
            }
        }
        #expect(failures.isEmpty, "\(failures.summary(over: LogGenerator.logCount(ofLength: length)))")
    }

    @Test("every log of three generated events folds, classifies, contains and accounts")
    func mainSweep() {
        Self.sweep(ofLength: 3)
    }

    @Test(
        "the same four oracles over every log of four generated events",
        .enabled(if: deepSweepEnabled)
    )
    func deepSweep() {
        // Length 5 is another 26× (≈11.9M logs) and would be an overnight run,
        // not a weekly one. If it is ever wanted, it wants a machine and a
        // schedule of its own rather than a bigger constant here.
        Self.sweep(ofLength: 4)
    }

    @Test("logs with no genesis reduce to nothing but residue")
    func beforeGenesisSweep() {
        // Shorter, because without genesis almost every row takes the same
        // branch (row 5, `beforeGenesis`) and length buys little. What it does
        // buy is the one precedence `precheck` encodes and no fixture isolates:
        // a *foreign* row before genesis must quarantine as contamination, not
        // as before-genesis — an event that is not ours has no business being
        // judged against our genesis.
        var failures = SweepFailures()
        LogGenerator.forEachLog(ofLength: 3, openedWithGenesis: false) { log, shapes in
            var found = problems(in: log)

            // A genesis-less log has no tree, whatever it contains. The only
            // shapes that can change that are the two `conversationCreated`s,
            // and the foreign one must not.
            let folded = fold(log.rows, for: log.conversation)
            let opened = shapes.contains { $0.name == "genesis" }
            if !opened && !folded.messages.isEmpty {
                found.append("a genesis-less log built \(folded.messages.count) messages")
            }
            if !opened && folded.hasGenesis {
                found.append("a genesis-less log reports hasGenesis")
            }

            if !found.isEmpty {
                failures.record("  [\(shapes.reproduction)] \(found.joined(separator: "; "))")
            }
        }
        #expect(failures.isEmpty, "\(failures.summary(over: LogGenerator.logCount(ofLength: 3)))")
    }

    @Test("P3: resume equals replay at every split of every generated log")
    func resumeEqualsReplay() {
        // The snapshot fast-path over inputs no fixture author chose. Length 3
        // rather than 4: this multiplies the enumeration by the number of split
        // points, and every structure P3 can get wrong — a routing map rebuilt
        // mid-generation, a checkpoint taken between a start and its terminal,
        // an open partial carried across the seam — is already reachable in
        // three events after genesis.
        var failures = SweepFailures()
        LogGenerator.forEachLog(ofLength: 3) { log, shapes in
            let whole = log.folded()
            for split in 0...log.rows.count {
                let prefix = Array(log.rows.prefix(split))
                let checkpoint = fold(prefix, for: log.conversation)
                let resumed = fold(
                    resuming: checkpoint,
                    after: prefix.last?.sequence ?? 0,
                    with: Array(log.rows.dropFirst(split))
                )
                if resumed != whole {
                    failures.record("  [\(shapes.reproduction)] split at \(split)")
                    break
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.summary(over: LogGenerator.logCount(ofLength: 3)))")
    }

    @Test("I1: every generated log folds to the same state twice")
    func determinism() {
        // Weaker than it looks, and worth stating so nobody reads more into a
        // green tick than it earns: Swift seeds its hasher per *process*, so two
        // folds in one process cannot disagree about dictionary order however
        // badly that order leaks. What this catches is accidental
        // nondeterminism the fold could smuggle in another way — a clock read, a
        // freshly minted identifier, anything environmental. Hasher-order
        // leakage needs separate processes, and re-running CI is what supplies
        // them.
        var failures = SweepFailures()
        LogGenerator.forEachLog(ofLength: 3) { log, shapes in
            if log.folded() != log.folded() {
                failures.record("  [\(shapes.reproduction)]")
            }
        }
        #expect(failures.isEmpty, "\(failures.summary(over: LogGenerator.logCount(ofLength: 3)))")
    }
}

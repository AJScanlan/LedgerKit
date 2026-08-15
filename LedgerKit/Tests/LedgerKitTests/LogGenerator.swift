import Foundation
@testable import LedgerKit

// Bounded-exhaustive log generation — the input-diversity half of the reducer's
// coverage, and the complement to `Corpus.swift` rather than a replacement for
// it.
//
// **The gap this closes.** Every log the reducer has been shown until now is a
// subsequence of one of ten fixtures a human wrote: `Corpus.all` supplies the
// shapes, and the sweeps in `CorpusSweepTests` truncate, gap and compound them.
// SPEC §10 is explicit that mutation may only *remove or split* — reordering
// would violate §6.6's ordering precondition — so no existing sweep can produce
// an event ordering nobody thought of. Coverage is exhaustive along the
// transformation axis and thin along the shape axis. This file supplies the
// missing axis: logs assembled from scratch, in ascending sequence order (so the
// precondition holds by construction), covering orderings no fixture author
// enumerated.
//
// **Exhaustive, not randomized — the same rule, applied one level up.** §10's
// rule governs split points; the reasoning behind it (no seed to manage, no
// flake, failures that reproduce by re-running) applies just as well to
// generation, so this enumerates rather than samples. The consequence worth
// naming: **there is no shrinker here, and none is needed.** Random generation
// needs shrinking because it produces 40-event monsters whose failure is
// unreadable; a bounded enumeration never produces anything that isn't already
// minimal. A failing log is four events long and its shape names are in the
// failure message.
//
// **The honest limit.** This is not exhaustive over the true input space, which
// is unbounded (ten payload kinds over arbitrary identifiers). It is exhaustive
// over *every ordering of a curated alphabet*. The curation is a human
// judgement — ``LogGenerator/alphabet`` picks shapes that sit on §6.6's rule
// boundaries — and a rule no shape can reach stays unreached however long the
// sweep runs. Two categories are deliberately out of reach and stay with the
// hostile fixtures, which own them: rows 1–2 (undecodable bytes) need the
// production loader, not a typed payload.

/// One event shape the generator can place at any position in a log.
///
/// A value rather than a closure over prior state, deliberately: a shape that
/// could inspect the log built so far would be a *generator of well-formed
/// logs*, and well-formed logs are precisely the ones the fold already handles.
/// The interesting inputs are the ones where a shape lands somewhere its author
/// did not picture it — a delta before its generation started, an edit naming a
/// message that will not exist for two more events — and getting those requires
/// shapes that are indifferent to context.
struct LogShape {
    /// Short, stable, and legible in a failure message. Four of these joined
    /// together *are* the reproduction — see the no-shrinker note above.
    let name: String
    let payload: LedgerEvent.Payload
    /// Non-`nil` only for the one shape that forges a foreign envelope (§6.6
    /// row 4). `Log.append` puts it on the envelope without touching the stream
    /// the fold is told to load from, which is exactly the contamination row 4
    /// exists to detect.
    let stream: ConversationID?

    init(_ name: String, _ payload: LedgerEvent.Payload, stream: ConversationID? = nil) {
        self.name = name
        self.payload = payload
        self.stream = stream
    }
}

enum LogGenerator {

    /// The curated event vocabulary, ordered — never a `Set` or dictionary, per
    /// the I1 hazard: enumeration order must not vary between runs of the same
    /// binary or a failing index names a different log each time.
    ///
    /// Identifiers come from a deliberately tiny universe so that collisions and
    /// dangling references are *reachable in four events*: two user messages
    /// (`userA`/`userB`), two assistant messages (`assistantA`/`assistantB`), one
    /// edit replacement (`edited`), two generations (`genA`/`genB`), and two
    /// ghosts that **no shape ever introduces** — `Fix.userC` and `Fix.genGhost`.
    /// The ghosts are what make "names something that does not exist" reachable
    /// without waiting for an ordering that happens to omit a definition.
    ///
    /// Each entry notes the §6.6 row it can reach *when placed badly*. Most can
    /// also be placed well — that is the point of enumerating orderings rather
    /// than hand-writing hostile logs: the same shape is legal at one position
    /// and malformed at another, and the sweep sees both without being told
    /// which is which.
    static let alphabet: [LogShape] = [
        // Genesis (row 5 when repeated) and the one foreign envelope (row 4).
        // Placing these two adjacently is what reaches `precheck`'s precedence
        // decision: row 4 outranks row 5, because an event that is not ours has
        // no business being judged against *our* genesis.
        LogShape("genesis", .conversationCreated(title: nil)),
        LogShape("genesis@foreign", .conversationCreated(title: nil), stream: Fix.foreign),

        // User messages — rows 6 (unknown parent, ID reuse) and 7 (the
        // "new topic ≠ new branch" guard).
        LogShape("u0@root", .userMessageAppended(message: Fix.userA, content: "a", parent: nil)),
        LogShape("u1@root", .userMessageAppended(message: Fix.userB, content: "b", parent: nil)),
        LogShape("u1@u0", .userMessageAppended(message: Fix.userB, content: "b", parent: Fix.userA)),
        LogShape("u1@ghost", .userMessageAppended(message: Fix.userB, content: "b", parent: Fix.userC)),

        // Generation starts — row 8's three separate conditions, plus the two
        // documented *non*-rules. `g0→a0@root` is N10's wire headroom (a
        // nil-parent start is legal where a nil-parent user message is not), and
        // `g1→a1@a0` is the assistant-parent continuation shape §6.6 records as
        // tolerated by the reducer and refused by the store.
        LogShape("g0→a0@u0", .generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: Fix.userA, model: Fix.model)),
        LogShape("g0→a0@root", .generationStarted(generation: Fix.genA, message: Fix.assistantA, parent: nil, model: Fix.model)),
        LogShape("g1→a1@u0", .generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.userA, model: Fix.model)),
        LogShape("g1→a1@a0", .generationStarted(generation: Fix.genB, message: Fix.assistantB, parent: Fix.assistantA, model: Fix.model)),
        LogShape("g1→a0@u0", .generationStarted(generation: Fix.genB, message: Fix.assistantA, parent: Fix.userA, model: Fix.model)),
        LogShape("g0→a1@ghost", .generationStarted(generation: Fix.genA, message: Fix.assistantB, parent: Fix.userC, model: Fix.model)),

        // Generation content — row 9 (unknown generation, and the I4 bounds).
        // Two distinct delta texts so a concatenation oracle can tell which
        // arrived and in what order.
        LogShape("Δ0", .deltaAppended(generation: Fix.genA, text: "x")),
        LogShape("Δ1", .deltaAppended(generation: Fix.genB, text: "y")),
        LogShape("Δghost", .deltaAppended(generation: Fix.genGhost, text: "z")),
        LogShape("tool0", .toolInvocationRecorded(
            generation: Fix.genA,
            record: ToolRecord(name: "search", status: .succeeded, duration: .milliseconds(120))
        )),

        // Terminals — row 10 (I3's at-most-one) and, for a generation that never
        // started, row 9. All three outcome kinds appear: a terminal's *kind*
        // decides the folded state, so a sweep carrying only `.completed` would
        // never fold a `.cancelled` partial.
        LogShape("end0✓", .generationEnded(generation: Fix.genA, outcome: .completed(Fix.stopInfo))),
        LogShape("end0⊘", .generationEnded(generation: Fix.genA, outcome: .cancelled)),
        LogShape("end1✗", .generationEnded(generation: Fix.genB, outcome: .failed(.guardrailViolation))),

        // Edits — row 11's three conditions (assistant target, unknown target,
        // replacement collision). `edit u0→u1` is the collision when `u1` is
        // already in the tree and an ordinary root-level sibling when it is not.
        LogShape("edit u0→e", .messageEdited(original: Fix.userA, replacement: Fix.edited, content: "a′")),
        LogShape("edit a0→e", .messageEdited(original: Fix.assistantA, replacement: Fix.edited, content: "a′")),
        LogShape("edit u0→u1", .messageEdited(original: Fix.userA, replacement: Fix.userB, content: "a′")),

        // Path movement — row 12, and the interaction that matters more: an
        // explicit endpoint change disables §6.4's auto-extend for whatever
        // follows, which is the only way a generated log reaches a path shape
        // the auto-extend rule would not have produced on its own.
        LogShape("path→u0", .activePathChanged(endpoint: Fix.userA)),
        LogShape("path→ghost", .activePathChanged(endpoint: Fix.userC)),

        // Reference-free kinds. Cheap to include and worth one slot each: they
        // are the only shapes that must *never* quarantine after genesis, so
        // they hold the accounting oracle honest — a sweep of nothing but
        // malformed shapes could not tell "quarantines correctly" from
        // "quarantines everything".
        LogShape("instr", .instructionsChanged("be brief")),
        LogShape("title", .titleChanged("t")),
    ]

    /// Number of distinct logs `forEachLog(ofLength:)` will visit.
    ///
    /// Reported in the sweep's failure messages so a run states its own coverage
    /// rather than leaving a reader to work out `alphabet.count ** length`.
    static func logCount(ofLength length: Int) -> Int {
        (0..<length).reduce(1) { count, _ in count * alphabet.count }
    }

    /// Visits every sequence of `length` shapes, in a stable order.
    ///
    /// **Streamed through a closure rather than returned as an array**, which is
    /// not a micro-optimization: at length 4 this is a quarter of a million logs,
    /// and materializing them would cost gigabytes to hold values that are each
    /// examined once and discarded. The closure keeps peak memory at one log.
    ///
    /// **Prefix-shared, and the measurement is why.** Rebuilding every log from
    /// genesis re-appends each position `alphabet.count` times over: at length 4
    /// that is 1.83M appends for 457k logs, where sharing the walk down the tree
    /// costs 475k. It matters here specifically because `Log.append` mints an
    /// `EventID` through `uuid(_:)`, which formats a string and parses it back —
    /// measured as the dominant cost of the sweep, above the fold it exists to
    /// exercise (46% of total CPU, removed by this change). Depth-first order is
    /// unchanged by the sharing, and so are the logs themselves: sibling
    /// branches inherit the same `nextEventNumber`, exactly as independent
    /// rebuilds each restarting from the same base did.
    ///
    /// - Parameters:
    ///   - length: Events to generate. The genesis prefix, if any, is *not*
    ///     counted here — `openedWithGenesis: true` at length 4 yields five-row
    ///     logs.
    ///   - openedWithGenesis: Prepends `conversationCreated`. Almost always
    ///     wanted: without it every row quarantines under row 5 (`beforeGenesis`)
    ///     and the enumeration spends its whole budget re-proving one rule. The
    ///     `false` case is worth a small sweep of its own, which is why it is a
    ///     parameter rather than a constant.
    ///   - body: Receives the assembled log and the shapes it was built from.
    ///     The shapes are passed alongside because they, not the log, are the
    ///     legible reproduction.
    static func forEachLog(
        ofLength length: Int,
        openedWithGenesis: Bool = true,
        _ body: (Log, [LogShape]) throws -> Void
    ) rethrows {
        precondition(length >= 0, "negative length")
        var root = Log()
        if openedWithGenesis { root.append(.conversationCreated(title: nil)) }
        var shapes = [LogShape]()
        shapes.reserveCapacity(length)
        try extend(root, by: length, shapes: &shapes, body)
    }

    /// One level of the enumeration tree: append each shape in turn to `log` and
    /// recurse, restoring `shapes` on the way back up.
    ///
    /// Recursion depth is `length` — four or five — so this is a fixed shallow
    /// stack, not the tree-depth recursion the reducer itself is forbidden
    /// (I2 promises no hang, and there tree depth tracks message count; here it
    /// is a compile-time-ish constant).
    private static func extend(
        _ log: Log,
        by remaining: Int,
        shapes: inout [LogShape],
        _ body: (Log, [LogShape]) throws -> Void
    ) rethrows {
        guard remaining > 0 else {
            try body(log, shapes)
            return
        }
        for shape in alphabet {
            var next = log
            next.append(shape.payload, from: shape.stream)
            shapes.append(shape)
            try extend(next, by: remaining - 1, shapes: &shapes, body)
            shapes.removeLast()
        }
    }
}

extension Array where Element == LogShape {
    /// The reproduction line for a failure message: `u0@root · g0→a0@u0 · Δ0 · end0✓`.
    ///
    /// Sufficient on its own — every name is an entry in ``LogGenerator/alphabet``,
    /// so rebuilding a failing log by hand is a lookup, not an archaeology.
    var reproduction: String {
        isEmpty ? "(empty)" : map(\.name).joined(separator: " · ")
    }
}

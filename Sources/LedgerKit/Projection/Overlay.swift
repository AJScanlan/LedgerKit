import Foundation

// The third and last stage of §6.3's pipeline — `fold → classify → overlay_live`
// — and the only one that knows this process is alive.
//
// §7.4's formula, in full:
//
//     projection = overlay_live( reduce(persistedLog ++ unflushedTail, mapping) )
//
// Everything before the outermost call is pure reduction over a log. This file is
// what turns a *dead* log's honest "no terminal exists" into a *live* store's
// "still generating", for exactly the generations the store has in flight.
//
// **Read the three-name table right-to-left and you have the recovery story**
// (§6.3): folded `.open` → classified `.interrupted` → overlaid `.streaming`. On
// relaunch the live set is vacuously empty, so this stage is the identity, and the
// fold's `.interrupted` shows through. Recovery is the overlay *disappearing* —
// there is no repair pass anywhere in the package to point at, because there is
// nothing to repair.
//
// Pure, `nonisolated`, no clocks, no I/O — the same discipline as `Reduce/`, for
// the same reason: liveness is store state, and letting it anywhere near the fold
// would put a process's lifetime on the wrong side of I1.

/// The generations this process is currently generating, and **the full partial to
/// show** for each (SPEC §7.4).
///
/// The value is the whole partial, not a suffix (M7-PLAN D47): the store holds both
/// halves — the folded text already on disk plus its unflushed delta buffer — so it
/// computes this and the projection assigns it. That is what keeps display cadence
/// independent of flush cadence without anyone doing arithmetic: a projection
/// accumulating suffixes would double-count every flush that landed between a delta
/// and a re-pull, and would have nothing to start from when it was created
/// mid-generation.
///
/// A dictionary because the overlay is a **keyed lookup**, never an iteration into
/// output — the I1 hazard, which does not stop being a hazard on the projection
/// side of the seam.
typealias LiveSet = [GenerationID: String]

/// Applies liveness to a classified conversation — §6.3's `overlay_live`.
///
/// A free `nonisolated` function beside `fold` and `classify` rather than a method
/// on anything, because it is the third seam of the same pipeline and §6.3 names
/// the seams. The Swift spelling drops the spec's `_live` suffix the way `fold` and
/// `classify` already drop the pipeline notation around them; `live:` carries it at
/// every call site.
///
/// **What it does, exhaustively:** for a message whose `generationID` is in `live`,
/// replace its state with `.streaming(partial:)` carrying that entry's value.
/// Everything else — every other message, and everything on the conversation that
/// is not a message state — passes through untouched. `.streaming` exists *only*
/// here; no fold of any log yields it (§6.2).
///
/// - Parameters:
///   - classified: `classify(fold(log), mapping)` — the dead-log answer, which is
///     what this must preserve everywhere it is not live.
///   - live: The store's in-flight generations and their full partials.
nonisolated func overlay(_ classified: Conversation, live: LiveSet) -> Conversation {
    // **The empty case is the identity, structurally rather than incidentally.**
    // §7.4 states `overlay_live(classify(fold(log)), ∅) ≡ classify(fold(log))` as a
    // theorem, and this line is it — no tree is rebuilt, so the returned value is
    // the argument. It is also the hot path: every cold open, every conversation
    // nobody is generating into, and every launch after a crash lands here.
    guard !live.isEmpty else { return classified }

    var projected = classified
    projected.messages.updateStates { message in
        // Keyed lookup into `live`, driven by a walk over messages — never the
        // reverse. Iterating `live` would put a dictionary's order in charge of
        // which message is visited first, and Swift's hasher seed varies per
        // process (the I1 leak `Reduce/` is forbidden from).
        guard let generation = message.generationID, let partial = live[generation] else { return nil }

        // **Flipped unconditionally, not only from `.interrupted`** — and the
        // choice is about diagnostics rather than defence.
        //
        // For a well-formed live set the question never arises: P2's clause 3 says
        // the live set is a subset of *open* generations, and an open generation
        // classifies to `.interrupted` (I5). So the only way to reach this line
        // with a terminal message is a store that failed to unregister a finished
        // generation — a real bug, in the store.
        //
        // Declining to flip would *hide* it: the projection would silently
        // disagree with the live set it was handed, and P2 would then report a
        // clause-1 partial mismatch as well as clause 3's, pointing two fingers at
        // this function for a defect one layer up. Flipping reports what the store
        // said and lets clause 3 name the culprit exactly once. Repairing at the
        // read side is the same mistake as canonicalizing a timestamp at write
        // time (ADR-001 R-5): it gives one fact two identities depending on which
        // layer you ask.
        return .streaming(partial: partial)
    }
    return projected
}

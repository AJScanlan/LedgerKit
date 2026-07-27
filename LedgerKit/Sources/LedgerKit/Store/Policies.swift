import Foundation

// The two cadences a `ConversationStore` runs on (SPEC §7.4, §9; M5-PLAN D25).
//
// Both are **structs with static factories over internal storage**, per D12's
// rule: enums for values consumers destructure, structs-with-factories for
// instructions consumers construct. Nobody switches over a flush cadence — it is
// handed to a store and read only inside its generation routine — while the set
// of knobs is certain to grow. As enums, each new knob reshapes the type; as
// structs, each is additive, and call sites are identical either way.
//
// Phase 0 ships the defaults and nothing else, deliberately. A factory for
// varying them is trivial to add and impossible to remove, and the honest moment
// to price one is when the loop that reads these exists to price it against
// (Phase 3's review gate, which also settles where they attach).

/// How often a streaming generation's text reaches disk (SPEC §7.4).
///
/// Writing every token is wasteful; losing 30 s of stream to a crash is bad UX.
/// The unflushed tail is exactly what a crash costs, which is the whole of this
/// type's meaning.
///
/// **Only `deltaAppended` coalesces.** Every other event — `generationStarted`
/// and its transaction-mates, terminals, edits, path changes, metadata — appends
/// synchronously before the verb proceeds, and the rule earns its keep at the
/// start boundary: a `generationStarted` sitting in an unflushed tail would let
/// a crash erase the turn entirely — user message persisted, no `.interrupted`
/// bubble, nothing to recover. That is strictly worse than the artifact G4
/// exists to fix, so it is unrepresentable by rule rather than avoided by luck.
///
/// **This is the *disk* cadence, not the display cadence.** The observable
/// projection applies deltas in memory as they arrive, ahead of disk, so
/// streaming renders smoothly while the log fills at durability cadence — two
/// cadences, one truth hierarchy (§7.4). The main-actor hop is M7's own knob and
/// has nothing to do with this one.
public struct DeltaFlushPolicy: Sendable, Equatable {

    /// §7.4's default: every ~250 ms or N characters, whichever comes first, and
    /// **always before `generationEnded`** — the pre-terminal flush is not a
    /// policy choice, so it is not represented here.
    public static let `default` = Self(interval: .milliseconds(250), characterCount: 512)

    let interval: Duration
    let characterCount: Int

    /// Internal, not private: the *public* surface is `.default` alone until
    /// Phase 3 prices a factory against the loop that reads these, but the
    /// module's own tests need to vary the cadence — a flush-every-character
    /// policy is how "always flush before the terminal" gets a failing case.
    init(interval: Duration, characterCount: Int) {
        self.interval = interval
        self.characterCount = characterCount
    }
}

/// When the store refreshes a conversation's snapshot (SPEC §9).
///
/// Snapshots exist so a cold open of a 10k-event conversation does not replay
/// from genesis, and they are **disposable** — truth is the log — which is what
/// makes best-effort refresh safe: a missed one costs replay time, never
/// correctness. The store shrugs off a failed save for exactly that reason,
/// while `saveSnapshot` itself reports what happened, so a checkpoint the store
/// *chose* to skip stays distinguishable from one that failed.
public struct SnapshotPolicy: Sendable, Equatable {

    /// §9's default: refresh after each `generationEnded` — the natural
    /// quiescent point, and generations dominate event volume, so a cold open
    /// replays at most one generation's suffix — with a floor for logs that
    /// somehow avoid terminals entirely.
    public static let `default` = Self(refreshesAfterEachGeneration: true, maximumEventsBetweenRefreshes: 500)

    let refreshesAfterEachGeneration: Bool
    /// The floor, for pathological logs: a conversation of nothing but edits and
    /// branch switches reaches no terminal and would otherwise never checkpoint.
    let maximumEventsBetweenRefreshes: Int

    /// Internal for the same reason as ``DeltaFlushPolicy``'s: a test that wants
    /// to reach the floor without writing 500 events has to be able to lower it.
    init(refreshesAfterEachGeneration: Bool, maximumEventsBetweenRefreshes: Int) {
        self.refreshesAfterEachGeneration = refreshesAfterEachGeneration
        self.maximumEventsBetweenRefreshes = maximumEventsBetweenRefreshes
    }
}

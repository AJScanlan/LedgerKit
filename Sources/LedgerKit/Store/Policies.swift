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
// **Both are publicly constructible as of M6 Phase 0 (D32).** M5 shipped
// `.default` alone on the grounds that a factory is trivial to add and impossible
// to remove, and that the honest moment to price one is when the loop reading it
// exists. That loop has existed since M5 Phase 3 and is mutation-tested, and the
// spec has promised configurability since rev 2 (§7.4 "make both cadences
// configurable", §9 "both configurable") — so the halfway state was two `init`
// parameters that accepted exactly one value each: API noise pretending to be
// flexibility.
//
// Named factories rather than public memberwise inits, per D12: the phrasing is
// what carries the **or** semantics. `.flushing(every:orAfterCharacters:)` says
// *whichever comes first*, where `init(interval:characterCount:)` leaves a reader
// guessing whether both must be satisfied. The inits stay internal, so adding a
// third knob remains additive.

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
/// streaming renders at display cadence while the log fills at durability cadence
/// — two cadences, one truth hierarchy (§7.4). The main-actor side is M7's own
/// knob and has nothing to do with this one; note it defaults to *immediate*,
/// because `@Observable` already coalesces to about a frame and the knob buys
/// less work rather than more smoothness (rev 10).
public struct DeltaFlushPolicy: Sendable, Equatable {

    /// §7.4's default: every ~250 ms or 512 characters, whichever comes first,
    /// and **always before `generationEnded`** — the pre-terminal flush is not a
    /// policy choice, so it is not represented here.
    public static let `default` = Self(interval: .milliseconds(250), characterCount: 512)

    let interval: Duration
    let characterCount: Int

    /// Internal: ``flushing(every:orAfterCharacters:)`` is the public spelling,
    /// and keeping the memberwise shape unexported is what makes a third knob
    /// additive instead of source-breaking.
    init(interval: Duration, characterCount: Int) {
        self.interval = interval
        self.characterCount = characterCount
    }

    /// A cadence of *whichever comes first* (§7.4).
    ///
    /// ```swift
    /// let store = try ConversationStore(
    ///     persistence: .sqlite(at: dbURL),
    ///     deltaFlush: .flushing(every: .milliseconds(100), orAfterCharacters: 128)
    /// )
    /// ```
    ///
    /// Tighten it and a crash costs less text while the log grows more rows;
    /// loosen it and the reverse. Neither end changes what the *user* sees while
    /// streaming — that is the projection's display cadence, a separate knob
    /// (§7.4's truth hierarchy) — so this trades durability against write volume
    /// and nothing else.
    ///
    /// - Parameters:
    ///   - interval: Maximum time buffered text may wait for disk.
    ///   - characters: Character count that forces a flush sooner.
    public static func flushing(every interval: Duration, orAfterCharacters characters: Int) -> Self {
        Self(interval: interval, characterCount: characters)
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

    /// Internal for the same reason as ``DeltaFlushPolicy``'s:
    /// ``refreshing(afterEachGeneration:orAfterEvents:)`` is the public spelling.
    init(refreshesAfterEachGeneration: Bool, maximumEventsBetweenRefreshes: Int) {
        self.refreshesAfterEachGeneration = refreshesAfterEachGeneration
        self.maximumEventsBetweenRefreshes = maximumEventsBetweenRefreshes
    }

    /// A checkpoint cadence (§9).
    ///
    /// ```swift
    /// // A bulk importer: no generations to hang a checkpoint off, so only the
    /// // floor does any work.
    /// let store = try ConversationStore(
    ///     persistence: .sqlite(at: dbURL),
    ///     snapshots: .refreshing(afterEachGeneration: false, orAfterEvents: 5_000)
    /// )
    /// ```
    ///
    /// Both knobs only ever buy or spend **replay time** — snapshots are
    /// disposable and the log is the truth (§9), so no setting here can be
    /// incorrect, only slow. That is why `afterEachGeneration: false` is a
    /// supported shape rather than a foot-gun: a writer with no terminals to
    /// checkpoint after should not pay for a policy keyed on them.
    ///
    /// - Parameters:
    ///   - afterEachGeneration: Checkpoint at each `generationEnded` — the
    ///     natural quiescent point, and the reason a cold open replays at most
    ///     one generation's suffix.
    ///   - events: The floor: checkpoint once this many events have accumulated
    ///     since the last one, whatever they were.
    public static func refreshing(afterEachGeneration: Bool = true, orAfterEvents events: Int) -> Self {
        Self(refreshesAfterEachGeneration: afterEachGeneration, maximumEventsBetweenRefreshes: events)
    }
}

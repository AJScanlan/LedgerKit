import Foundation

// Snapshot coding, version policy, and the resume path (SPEC §9) — the
// "snapshot fast-path", so a cold open of a 10k-event conversation does not
// replay from genesis.
//
// **All of it lives above the seam, deliberately.** The backend stores a blob and
// four scalars and never interprets any of them (ADR-003 rule 2); whether a
// checkpoint may be *used* is a question about the reducer, not about storage. The
// version fields ride outside `payload` precisely so that decision costs no
// decode.

extension Snapshot {

    /// Encodes a folded state as a checkpoint at `sequence`.
    ///
    /// Stamped with **both** current versions, because they are checked
    /// independently and mean different things (``LedgerSchema``).
    ///
    /// The encoding is `FoldedState`'s synthesized `Codable`, and that conformance
    /// commits to nothing: snapshots are discard-on-mismatch with no migration
    /// ever (§9), so widening the folded layer is free in a way widening
    /// `LedgerEvent.Payload` emphatically is not. `WireJSON` is used anyway, for
    /// determinism rather than for contract — a byte-identical checkpoint from the
    /// same state is easier to reason about than one that varies.
    init(encoding state: FoldedState, upTo sequence: Int64) throws {
        self.init(
            conversationID: state.id,
            reducerVersion: LedgerSchema.reducerVersion,
            schemaVersion: LedgerSchema.payloadVersion,
            upToSequence: sequence,
            payload: try WireJSON.encoder().encode(state)
        )
    }

    /// The checkpoint's folded state, or `nil` if it must be discarded.
    ///
    /// Four ways a checkpoint is unusable, and **all four take the same branch** —
    /// discard, replay from genesis, never fail:
    ///
    /// - either version disagrees with this build (the designed case);
    /// - the payload does not decode (truncation, bit rot);
    /// - the payload decodes but names a *different* conversation than the row it
    ///   was stored under — the snapshot analogue of §6.6 row 4, and corrupt by
    ///   the same argument;
    /// - `upToSequence` is not a sequence a log can have.
    ///
    /// Collapsing them is the point: a snapshot is a cache of a fold, so the worst
    /// a bad one may ever cost is the replay it was avoiding. There is no
    /// migration path, by design — §9 forbids one, because the alternative is
    /// carrying every historical shape of the reducer's output forever.
    ///
    /// **A discard is silent, and the earlier claim that §9 requires otherwise was
    /// wrong** (corrected at the M5 Phase 5 sweep, by re-reading §9 rather than
    /// citing it from memory — the M4 audit's standing lesson). §9 asks only that
    /// the checkpoint be discarded, and silence is the right disposition anyway:
    /// this is a **cache miss**, not an error. It costs a replay, the store actor
    /// has no logging surface at all, and §9's privacy stance points the same way.
    /// If a diagnostic ever earns its keep it belongs above the seam, where a
    /// caller can be told; it does not belong to storage.
    var foldedState: FoldedState? {
        guard reducerVersion == LedgerSchema.reducerVersion,
              schemaVersion == LedgerSchema.payloadVersion,
              upToSequence >= 1,
              let state = try? WireJSON.decoder().decode(FoldedState.self, from: payload),
              state.id == conversationID
        else { return nil }
        return state
    }
}

/// A cold-loaded conversation: the fold, where it stopped, and where its newest
/// usable checkpoint sat (SPEC §9).
///
/// The third field exists only for §9's **event floor** — "refresh every 500
/// events for pathological logs". Without it a store that reopened a
/// long-checkpointless conversation would measure drift from *this session's*
/// first append rather than from the last checkpoint, and a log that never
/// reaches a terminal would keep deferring the refresh that exists precisely for
/// it. `0` means "replayed from genesis", which reads correctly in the
/// subtraction.
struct LoadedFold: Sendable {
    var state: FoldedState
    /// The last sequence folded into `state`.
    var lastSequence: Int64
    /// The checkpoint `state` resumed from; 0 if it replayed from genesis.
    var snapshotSequence: Int64
}

// MARK: - The read path

extension PersistenceStore {

    /// A conversation's folded state, using the newest usable checkpoint.
    ///
    /// **`fold(resuming:after:with:)` is the primitive and replay is its
    /// degenerate case** — the same single reduction path either way, which is the
    /// whole reason that signature exists. Rev 3 of the spec shipped the fast path
    /// as a *second*, untested path; P3 exists because of that, and this
    /// composition is what keeps there being only one thing to get wrong.
    ///
    /// Passing `upToSequence` as `after:` is load-bearing rather than
    /// bookkeeping: a gap straddling the checkpoint boundary is only detectable if
    /// the resumed fold knows where the snapshot stopped. Without it, a hole
    /// immediately after the checkpoint would silently close.
    ///
    /// A **snapshot read failure is swallowed** — deliberately, and it is the one
    /// place in this file that swallows anything. Truth is the log (tenet 2), so a
    /// damaged or unreadable checkpoint may cost time and must never cost
    /// availability: the conversation still loads, from genesis. An `events`
    /// failure, by contrast, propagates: that *is* the truth failing to load, and
    /// silently returning an empty conversation would be indistinguishable from a
    /// conversation that is genuinely empty.
    ///
    /// Provided as an extension, not a seventh protocol requirement: ADR-003 rule 4
    /// caps the seam at six verbs, and this is a *composition* of three of them.
    /// Policy above the seam, shared by every backend, overridable by none.
    func foldedState(of conversation: ConversationID) async throws -> FoldedState {
        try await loadedFold(of: conversation).state
    }

    /// The same load, additionally reporting **the sequence the fold stopped at**.
    ///
    /// The pair is what an in-memory cache of a conversation needs, and it is the
    /// same pair ``Snapshot`` persists (`payload` + `upToSequence`) — a fold is only
    /// resumable if you know where it got to. M5's store actor holds one per
    /// conversation: `lastSequence` is the `after:` its fold-forward passes when the
    /// next append returns a tail, and the `upTo:` its snapshot refresh checkpoints
    /// at (§9).
    ///
    /// It would have been easy to let the actor infer the sequence from the tail it
    /// just appended — `tail.first.sequence - 1` — and that inference is *correct*
    /// only because the store is the sole writer of contiguous sequences. Reading
    /// the number back from the load instead means the actor can **check** that
    /// assumption rather than depend on it, which is the difference between a false
    /// gap diagnostic that surfaces and one that does not.
    ///
    /// `foldedState(of:)` is expressed in terms of this rather than beside it: two
    /// compositions of the snapshot fast-path would be two things to get wrong, and
    /// rev 3 already shipped that mistake once (P3 exists because of it).
    func loadedFold(of conversation: ConversationID) async throws -> LoadedFold {
        if let snapshot = try? await latestSnapshot(for: conversation),
           let resumed = snapshot.foldedState {
            let suffix = try await events(in: conversation, from: snapshot.upToSequence + 1)
            return LoadedFold(
                state: fold(resuming: resumed, after: snapshot.upToSequence, with: suffix),
                lastSequence: suffix.last?.sequence ?? snapshot.upToSequence,
                snapshotSequence: snapshot.upToSequence
            )
        }
        let rows = try await events(in: conversation, from: 1)
        return LoadedFold(
            state: fold(rows, for: conversation),
            lastSequence: rows.last?.sequence ?? 0,
            snapshotSequence: 0
        )
    }

    /// Checkpoints `state` as of `sequence`, replacing any existing checkpoint.
    ///
    /// Throwing rather than best-effort *here*: §9's "best-effort" is a statement
    /// about the **caller's** policy (a missed refresh costs replay time, never
    /// correctness), and encoding that policy into the verb would deny M5 the
    /// ability to distinguish a checkpoint it chose to skip from one that failed.
    /// The store actor wraps this in the shrug; the verb reports what happened.
    func saveSnapshot(of state: FoldedState, upTo sequence: Int64) async throws {
        try await save(Snapshot(encoding: state, upTo: sequence))
    }
}

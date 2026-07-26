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
    /// §9 says a discard is logged. There is no logger below M5, and inventing one
    /// here would be the same mistake §8 avoided by putting "logged loudly" at
    /// normalization time: the obligation belongs to the layer that *has* a
    /// logger, which is the store actor.
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
        if let snapshot = try? await latestSnapshot(for: conversation),
           let resumed = snapshot.foldedState {
            let suffix = try await events(in: conversation, from: snapshot.upToSequence + 1)
            return fold(resuming: resumed, after: snapshot.upToSequence, with: suffix)
        }
        return fold(try await events(in: conversation, from: 1), for: conversation)
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

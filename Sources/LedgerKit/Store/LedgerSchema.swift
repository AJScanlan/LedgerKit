/// The two version numbers the store stamps, and what each one governs
/// (SPEC §9, ADR-001).
///
/// They are separate because they fail differently, and conflating them would
/// make one of the two failures impossible to express:
///
/// - ``payloadVersion`` rides **every event row** and is the *wire* version. Its
///   contract is "readers read all past versions, write current" — so a bump
///   never invalidates anything; it selects an upcaster (ADR-001's named
///   evolution idiom) so the reducer stays single-shape.
/// - ``reducerVersion`` rides **snapshots** and is the *derived-state* version.
///   Its contract is the opposite: discard on mismatch, no migration ever,
///   because a snapshot is a cache of a fold and a changed fold makes it a cache
///   of nothing. Costing a replay is the entire penalty.
///
/// A single "schema version" could only have had one of those two behaviours.
enum LedgerSchema {

    /// The `LedgerEvent.Payload` encoding version stamped on every event row.
    ///
    /// Bump **only** for a change in how payloads encode — a new field key, a
    /// changed scalar form, a retired tag. Adding a payload *kind* does not
    /// qualify: old readers already handle unknown kinds by quarantining them
    /// (§6.6 row 2), which is the designed degradation, and bumping would
    /// falsely imply old readers need an upcaster to cope.
    static let payloadVersion = 1

    /// The version of the fold whose output snapshots hold.
    ///
    /// Bump on **any** change to `FoldedState`'s shape or to the fold's
    /// semantics — including ones that look harmless, because the penalty for
    /// over-bumping is one replay and the penalty for under-bumping is resuming
    /// from a checkpoint that means something subtly different, which is exactly
    /// the divergence P3 exists to catch and the kind that would ship silently.
    ///
    /// 2: the M4-audit rename `QuarantineReason.unknownPayloadKind` →
    /// `undecodablePayload(kind:)` changed the synthesized snapshot encoding of
    /// diagnostics. Old checkpoints would discard on decode failure anyway;
    /// bumping makes the discard deterministic rather than incidental.
    static let reducerVersion = 2
}

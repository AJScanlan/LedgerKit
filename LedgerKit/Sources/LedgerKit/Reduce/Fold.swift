/// Reduces a conversation's log to its folded state (SPEC §6.3).
///
/// Pure and unisolated: no clocks, no I/O, no environment reads — I1's first
/// half. Timestamps ride the events, and the reducer never orders by them
/// (§6.1).
///
/// Note what this does **not** produce: `.interrupted` and `Recoverability`.
/// Both are finalization-time conclusions that belong to `classify` (I5, §8).
/// A fold that has stopped reading has not thereby learned that the process
/// died.
///
/// - Parameters:
///   - rows: The conversation's log in sequence order, each row either a decoded
///     event or an unreadable one (§6.6 rows 1–2).
///   - conversation: The stream these rows were loaded from. Required because
///     row 4 compares each envelope against it — an event cannot self-certify
///     which stream it belongs to.
func fold(_ rows: some Sequence<LoadedEvent>, for conversation: ConversationID) -> FoldedState {
    fold(resuming: .empty(conversation), after: 0, with: rows)
}

/// Resumes reduction from a snapshot (SPEC §9).
///
/// **This is the primitive**, and folding from genesis is its degenerate case —
/// deliberately, so there is exactly one reduction path. Rev 3 shipped the
/// snapshot fast-path as a second, untested path; P3 exists because of that, and
/// this signature is what stops it recurring.
///
/// - Parameters:
///   - state: The snapshot's folded state.
///   - sequence: The last sequence already folded into `state` (`Snapshot.upToSequence`);
///     `0` when starting from genesis. Needed so a gap straddling the snapshot
///     boundary is still detected.
///   - rows: The suffix after `sequence`, in sequence order.
func fold(
    resuming state: FoldedState,
    after sequence: Int64,
    with rows: some Sequence<LoadedEvent>
) -> FoldedState {
    var folder = Folder(resuming: state, after: sequence)
    for row in rows {
        folder.apply(row)
    }
    return folder.finish()
}

/// One row of a conversation's log, as the store handed it to the reducer.
///
/// The fold consumes these rather than bare `LedgerEvent`s because §6.6 rows 1
/// and 2 are *decode* failures: they cannot arise inside a fold over
/// already-decoded events, yet they must still reach `diagnostics`. Omitting an
/// unreadable row instead would turn it into a **sequence gap**, which is a
/// different and false claim — a gap says the fact is missing, an undecodable
/// row says the fact is present and unintelligible (SPEC §6.6).
///
/// The two cases also make ADR-001's envelope-first decode requirement
/// structural: identity is `Optional` in exactly the row-1 case, so a loader
/// that threw the envelope away along with an unrecognized payload has nowhere
/// to put the `EventID` it should have recovered.
public enum LoadedEvent: Sendable, Equatable {

    /// Why a row's contents could not be read.
    ///
    /// Deliberately narrower than ``QuarantineReason``: the loader can only
    /// report the two conditions it is in a position to observe, so it cannot
    /// claim a *semantic* quarantine (a duplicate genesis, say) that only the
    /// fold is entitled to decide (tenet 1).
    public enum DecodeFailure: Sendable, Equatable {
        /// Row 1 — nothing readable, not even identity.
        case envelope
        /// Row 2 — envelope read, payload unreadable: an unknown
        /// discriminator, *or* a known one whose body will not decode (the two
        /// conditions rev 7's widened row 2 names). Carries the tag where it
        /// was legible.
        case payload(kind: String?)
    }

    case decoded(LedgerEvent)

    /// A row whose key was readable but whose contents were not. `sequence`
    /// always exists — it *is* the table key (§9) — which is why it is a plain
    /// `Int64` here while `eventID` is optional.
    case undecodable(sequence: Int64, eventID: EventID?, failure: DecodeFailure)

    /// The row's position in the conversation's sequence run — the sole
    /// authoritative order (§6.1), and what gap detection walks.
    public var sequence: Int64 {
        switch self {
        case .decoded(let event): event.sequence
        case .undecodable(let sequence, _, _): sequence
        }
    }

    /// The event's identity where it survived; `nil` for a row-1 failure.
    public var eventID: EventID? {
        switch self {
        case .decoded(let event): event.id
        case .undecodable(_, let eventID, _): eventID
        }
    }
}

extension LoadedEvent.DecodeFailure {

    /// The quarantine this decode failure becomes. Kept here so the row-1/row-2
    /// mapping lives in one place rather than inside the fold's loop.
    var quarantineReason: QuarantineReason {
        switch self {
        case .envelope: .undecodableEnvelope
        case .payload(let kind): .undecodablePayload(kind: kind)
        }
    }
}

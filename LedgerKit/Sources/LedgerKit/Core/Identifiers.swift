import Foundation

/// The shared shape of LedgerKit's opaque identifiers.
///
/// This exists to avoid writing the same four conformances four times, **not**
/// as an extension point — the set of identifiers is closed and is wire format
/// forever (SPEC §6.1). Do not conform new types outside this file.
///
/// - Note: Deliberately **not** `Comparable`. `sequence` is the sole
///   authoritative order (SPEC §6.1); ordering by an identifier would smuggle
///   wall-clock into the reducer and violate I1. Omitting the conformance makes
///   `events.sorted()` fail to compile rather than silently sort by time bits.
public protocol LedgerIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The underlying value. Read-only: identifiers are opaque to callers.
    var uuid: UUID { get }

    init(_ uuid: UUID)
}

extension LedgerIdentifier {
    /// The bare UUID string — identifiers appear unadorned in log dumps.
    public var description: String { uuid.uuidString }

    /// Encodes as a single value so the JSON carries `"019F…"`, not
    /// `{"uuid":"019F…"}`. Spelled out rather than inherited from
    /// `RawRepresentable` because this shape is the wire format (SPEC §9) and
    /// must not drift with stdlib conformance changes.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(UUID.self))
    }
}

/// Identity of a single event in the ledger.
///
/// UUIDv7, so a raw log dump reads in creation order and SQLite inserts land at
/// the right edge of the index. The reducer never reads it for ordering.
public struct EventID: LedgerIdentifier {
    public let uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
}

/// Identity of a conversation — the event stream key.
///
/// Rides the event envelope (SPEC §6.1) so an event is self-describing; an
/// envelope disagreeing with the stream it loaded from quarantines (§6.6 row 4).
public struct ConversationID: LedgerIdentifier {
    public let uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
}

/// Identity of a node in the message tree.
///
/// Distinct from `GenerationID` on purpose: I7 binds them 1:1 in v0.1, so every
/// call site holds both and swapping them must not compile.
public struct MessageID: LedgerIdentifier {
    public let uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
}

/// Identity of one generation attempt.
///
/// The key for I3 (single termination), I4 (generation-scoped bounds), and I5
/// (interruption synthesis). Also the key of the store's live set (§7.4).
public struct GenerationID: LedgerIdentifier {
    public let uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
}

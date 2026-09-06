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
/// Distinct from `GenerationAttemptID` on purpose: I7 binds them 1:1 in v0.1, so every
/// call site holds both and swapping them must not compile.
public struct MessageID: LedgerIdentifier {
    public let uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
}

/// Identity of one generation attempt.
///
/// The key for I3 (single termination), I4 (generation-scoped bounds), and I5
/// (interruption synthesis). Also the key of the store's live set (§7.4).
///
/// ## Why "Attempt", when everything around it says "generation"
///
/// **The name is collision-driven, not concept-driven** (M9-PLAN D62), and the
/// distinction explains the vocabulary you will notice nearby. It was
/// `GenerationID` through M8. Foundation Models ships its own `GenerationID`,
/// and `@Generable` expands to code referring to it **unqualified** — so any
/// consumer file importing both modules failed to compile *inside a macro
/// expansion its author never wrote*:
///
/// ```
/// error: 'GenerationID' is ambiguous for type lookup in this context
/// ```
///
/// Since `@Generable` is the ordinary way to declare tool arguments, that landed
/// on real apps, not just on this repo's tests. Re-verified on Xcode 27 Beta 6
/// before the rename was taken.
///
/// **"Attempt" is I7's own word** rather than an evasion: a generation attempt is
/// 1:1 with a `MessageID` in v0.1 and would become N:1 under continuation-resume
/// (§12), which is precisely the concept this identifier keys.
///
/// ⚠️ **The vocabulary is deliberately layered, not uniform.** The *type* says
/// `GenerationAttempt` because Apple owns the shorter name; the **wire and the
/// events** say `generation` (`generationStarted`, `deltaAppended(generation:)`,
/// and the permanent `"generationID"` field key — ADR-001 R-2), because that is
/// the domain noun and it is fixed forever; and **`Message`** says
/// ``Message/attemptID``, because in a message's context "attempt" is
/// unambiguous and I7 says a message has exactly one. Renaming the wire key to
/// match the type would have been a permanent commitment bought with nothing:
/// `Registry/tags.json` is byte-identical across this rename, which is the proof
/// that a Swift type name reaches no encoding.
public struct GenerationAttemptID: LedgerIdentifier {
    public let uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
}

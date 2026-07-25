import Foundation

/// Mints LedgerKit's identifiers.
///
/// Both the clock and the randomness source are injected, so a fixture built
/// with a seeded `RNG` and a fake clock produces byte-identical identifiers on
/// every run. That is what makes M3's golden-log corpus snapshot-testable at
/// all (SPEC §10.2) — an identifier minted from ambient randomness would make
/// every fixture unreproducible.
///
/// - Note: There is deliberately no `EventID()`-style ambient initializer. The
///   identifier types do expose `init(_ uuid: UUID)` — decoding and fixtures
///   need it — but nothing in LedgerKit *mints* a value without a generator
///   someone had to hand it, so no code path can quietly inherit production
///   randomness. The store owns one generator and mints inside its append
///   transaction (SPEC §6.1).
public struct IDGenerator<RNG: RandomNumberGenerator & Sendable>: Sendable {

    private var uuidV7 = UUIDv7Generator()
    private var rng: RNG
    private let now: @Sendable () -> UInt64

    /// - Parameters:
    ///   - rng: Randomness source. Seed it for deterministic fixtures.
    ///   - now: Milliseconds since the Unix epoch.
    public init(rng: RNG, now: @escaping @Sendable () -> UInt64) {
        self.rng = rng
        self.now = now
    }

    // MARK: - Vending

    public mutating func eventID() -> EventID { EventID(mintV7()) }
    public mutating func conversationID() -> ConversationID { ConversationID(mintV7()) }
    public mutating func messageID() -> MessageID { MessageID(mintV7()) }
    public mutating func generationID() -> GenerationID { GenerationID(mintV7()) }

    // MARK: - Minting

    /// Time-sortable. Costs a clock read; embeds creation time to the millisecond.
    ///
    /// All four identifiers share this one path — ADR-002 §2 extends §6.1's
    /// `EventID`-only v7 requirement to every identifier for uniformity, so
    /// there is deliberately no second strategy to choose between.
    private mutating func mintV7() -> UUID {
        uuidV7.next(milliseconds: now(), using: &rng)
    }
}

extension IDGenerator where RNG == SystemRandomNumberGenerator {
    /// The production generator: system randomness, wall clock.
    public static func live() -> Self {
        Self(
            rng: SystemRandomNumberGenerator(),
            now: { UInt64(Date().timeIntervalSince1970 * 1000) }
        )
    }
}

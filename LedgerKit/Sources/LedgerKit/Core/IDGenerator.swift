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
///   only way to mint an identifier is through a generator someone had to hand
///   you, which means test code cannot accidentally inherit production
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

    // MARK: - Minting strategies

    /// Time-sortable. Costs a clock read; embeds creation time to the millisecond.
    private mutating func mintV7() -> UUID {
        uuidV7.next(milliseconds: now(), using: &rng)
    }

    /// 122 random bits from the injected source — deterministic under a seeded
    /// `RNG`, but carrying no time information. Built by hand rather than via
    /// `UUID()`, which would read ambient system randomness and break fixtures.
    private mutating func mintV4() -> UUID {
        let a = rng.next()
        let b = rng.next()

        return UUID(
            uuid: (
                UInt8(truncatingIfNeeded: a >> 56),
                UInt8(truncatingIfNeeded: a >> 48),
                UInt8(truncatingIfNeeded: a >> 40),
                UInt8(truncatingIfNeeded: a >> 32),
                UInt8(truncatingIfNeeded: a >> 24),
                UInt8(truncatingIfNeeded: a >> 16),
                // ver (0100) + 4 random bits.
                0x40 | UInt8(truncatingIfNeeded: a >> 8) & 0x0F,
                UInt8(truncatingIfNeeded: a),
                // var (10) + 6 random bits.
                0x80 | UInt8(truncatingIfNeeded: b >> 56) & 0x3F,
                UInt8(truncatingIfNeeded: b >> 48),
                UInt8(truncatingIfNeeded: b >> 40),
                UInt8(truncatingIfNeeded: b >> 32),
                UInt8(truncatingIfNeeded: b >> 24),
                UInt8(truncatingIfNeeded: b >> 16),
                UInt8(truncatingIfNeeded: b >> 8),
                UInt8(truncatingIfNeeded: b)
            )
        )
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

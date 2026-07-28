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
///   randomness. The `ConversationStore` actor owns one generator and mints as it
///   assembles a verb's records — *before* handing them to the seam, since the
///   transaction belongs to the backend and identity belongs above it (SPEC §6.1).
///   `sequence` is the one identifier minted the other way round, inside the write
///   transaction, because only the write lock can decide it (SPEC §9).
public struct IDGenerator<RandomSource: RandomNumberGenerator & Sendable>: Sendable {

    private var uuidV7 = UUIDv7Generator()
    private var randomSource: RandomSource
    private let now: @Sendable () -> UInt64

    /// - Parameters:
    ///   - randomSource: Randomness source. Seed it for deterministic fixtures.
    ///   - now: Milliseconds since the Unix epoch.
    public init(randomSource: RandomSource, now: @escaping @Sendable () -> UInt64) {
        self.randomSource = randomSource
        self.now = now
    }

    // MARK: - Vending

    /// `make`-prefixed because these are **mutating**: each call advances the
    /// v7 generator's monotonicity state, and a getter-shaped name would read
    /// as pure at exactly the call sites where it is not.
    public mutating func makeEventID() -> EventID { EventID(mintV7()) }
    public mutating func makeConversationID() -> ConversationID { ConversationID(mintV7()) }
    public mutating func makeMessageID() -> MessageID { MessageID(mintV7()) }
    public mutating func makeGenerationID() -> GenerationID { GenerationID(mintV7()) }

    // MARK: - Minting

    /// Time-sortable. Costs a clock read; embeds creation time to the millisecond.
    ///
    /// All four identifiers share this one path — ADR-002 §2 extends §6.1's
    /// `EventID`-only v7 requirement to every identifier for uniformity, so
    /// there is deliberately no second strategy to choose between.
    private mutating func mintV7() -> UUID {
        uuidV7.next(milliseconds: now(), using: &randomSource)
    }
}

extension IDGenerator where RandomSource == SystemRandomNumberGenerator {
    /// The production generator: system randomness, wall clock.
    ///
    /// The clock is clamped at zero: a wall clock set before 1970 would make
    /// the interval negative and the `UInt64` conversion trap — a crash on
    /// ambient state, which nothing in this package is allowed to do. The
    /// v7 generator's own monotonicity handles a merely *regressing* clock;
    /// this handles an absurd one.
    public static func live() -> Self {
        Self(
            randomSource: SystemRandomNumberGenerator(),
            now: { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }
        )
    }
}

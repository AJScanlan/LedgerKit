import Foundation

/// Mints UUID version 7 identifiers (RFC 9562 §5.7).
///
/// Foundation only mints v4, and `EventID` wants time-sortable identity, so this
/// is ours. Layout, most-significant bit first:
///
///     +-------------------------------------------------------------+
///     |                    unix_ts_ms (48 bits)                     |
///     +----------------------------+-------+------------------------+
///     |                            |  ver  |     rand_a (12)        |
///     +-----+----------------------+-------+------------------------+
///     | var |                 rand_b (62 bits)                      |
///     +-----+------------------------------------------------------+
///
/// The 48-bit big-endian timestamp sits in the most-significant position, so
/// bytewise comparison of two v7s equals chronological comparison.
///
/// - Important: Per SPEC §6.1, `EventID` is UUIDv7 for *identity* only. The
///   reducer never orders by it — `sequence` is the sole authoritative order.
///   The time bits exist for debugging, index locality, and future log-shipping.
///
/// Both the clock and the randomness source are injected rather than read
/// ambiently, so fixtures mint byte-identical IDs on every run (tenet 5).
///
/// This type is a value with mutable state; callers needing a shared generator
/// must supply their own isolation. The store mints IDs inside its append
/// transaction, so the `ConversationStore` actor already provides it.
struct UUIDv7Generator: Sendable {
    
    /// Largest value `rand_a` can hold — it is 12 bits, not 16.
    private static let counterCeiling: UInt16 = 0x0FFF

    /// The last millisecond this generator emitted for.
    private var lastMilliseconds: UInt64 = 0

    /// The 12-bit `rand_a` sub-millisecond counter.
    private var counter: UInt16 = 0

    init() {}

    /// Mints the next identifier.
    ///
    /// - Parameters:
    ///   - milliseconds: Milliseconds since the Unix epoch. Only the low 48
    ///     bits are used; anything above is truncated.
    ///   - rng: Source of `rand_b`.
    mutating func next(
        milliseconds: UInt64,
        using rng: inout some RandomNumberGenerator
    ) -> UUID {
        let (timestamp, counter) = advance(to: milliseconds, using: &rng)
        return assemble(timestamp: timestamp, counter: counter, using: &rng)
    }

    /// Decides the timestamp and `rand_a` counter for the next identifier,
    /// guaranteeing the result sorts strictly after the previous one.
    ///
    /// - Returns: The 48-bit timestamp to embed and the 12-bit counter value.
    private mutating func advance(
        to now: UInt64,
        using rng: inout some RandomNumberGenerator
    ) -> (timestamp: UInt64, counter: UInt16) {
        if now > lastMilliseconds {
            // New millisecond — restart the counter.
            lastMilliseconds = now
            counter = 0
        } else if counter == Self.counterCeiling {
            // rand_a exhausted. Borrow from the future: monotonicity is
            // preserved, at the cost of running slightly ahead of wall clock
            // until the real clock catches up.
            lastMilliseconds += 1
            counter = 0
        } else {
            // Same millisecond, or the clock stepped backwards. Both cases
            // ignore `now` and keep climbing against `lastMilliseconds`, so a
            // regression yields stale time bits rather than a backwards ID.
            counter += 1
        }

        return (lastMilliseconds, counter)
    }

    /// Packs the fields into the RFC 9562 byte layout.
    private func assemble(
        timestamp: UInt64,
        counter: UInt16,
        using rng: inout some RandomNumberGenerator
    ) -> UUID {
        let randB = rng.next()

        return UUID(
            uuid: (
                // unix_ts_ms — 48 bits, big-endian.
                UInt8(truncatingIfNeeded: timestamp >> 40),
                UInt8(truncatingIfNeeded: timestamp >> 32),
                UInt8(truncatingIfNeeded: timestamp >> 24),
                UInt8(truncatingIfNeeded: timestamp >> 16),
                UInt8(truncatingIfNeeded: timestamp >> 8),
                UInt8(truncatingIfNeeded: timestamp),
                // ver (0111) + high 4 bits of rand_a.
                0x70 | UInt8(truncatingIfNeeded: counter >> 8) & 0x0F,
                // low 8 bits of rand_a.
                UInt8(truncatingIfNeeded: counter),
                // var (10) + high 6 bits of rand_b.
                0x80 | UInt8(truncatingIfNeeded: randB >> 56) & 0x3F,
                UInt8(truncatingIfNeeded: randB >> 48),
                UInt8(truncatingIfNeeded: randB >> 40),
                UInt8(truncatingIfNeeded: randB >> 32),
                UInt8(truncatingIfNeeded: randB >> 24),
                UInt8(truncatingIfNeeded: randB >> 16),
                UInt8(truncatingIfNeeded: randB >> 8),
                UInt8(truncatingIfNeeded: randB)
            )
        )
    }
}

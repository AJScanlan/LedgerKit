import Foundation
import Testing

@testable import LedgerKit

/// Deterministic RNG so every fixture mints byte-identical IDs.
/// (SplitMix64 — small, well-distributed, trivially reproducible.)
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension UUID {
    /// The 16 bytes, most-significant first.
    fileprivate var bytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }

    /// The 48-bit `unix_ts_ms` field.
    fileprivate var v7Timestamp: UInt64 {
        bytes.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

@Suite("UUIDv7")
struct UUIDv7Tests {

    @Test("Sets the version and variant bits per RFC 9562")
    func versionAndVariantBits() {
        var rng = SplitMix64(seed: 1)
        var generator = UUIDv7Generator()

        for millisecond in UInt64(0)..<64 {
            let bytes = generator.next(milliseconds: millisecond, using: &rng).bytes
            #expect(bytes[6] >> 4 == 0b0111, "version nibble")
            #expect(bytes[8] >> 6 == 0b10, "variant bits")
        }
    }

    @Test("Embeds the supplied millisecond in the high 48 bits")
    func timestampRoundTrips() {
        var rng = SplitMix64(seed: 2)
        var generator = UUIDv7Generator()

        // 2026-07-18T00:00:00Z, and a value near the 48-bit ceiling.
        let milliseconds: [UInt64] = [1_784_332_800_000, (1 << 48) - 1]
        for millisecond in milliseconds {
            let id = generator.next(milliseconds: millisecond, using: &rng)
            #expect(id.v7Timestamp == millisecond)
        }
    }

    @Test("Bytewise order matches chronological order")
    func sortsChronologically() {
        var rng = SplitMix64(seed: 3)
        var generator = UUIDv7Generator()

        let ids = (UInt64(1)...500).map {
            generator.next(milliseconds: 1_784_332_800_000 + $0, using: &rng)
        }

        #expect(ids.sorted { $0.uuidString < $1.uuidString } == ids)
    }

    @Test("Stays strictly increasing within a single millisecond")
    func monotonicWithinAMillisecond() {
        var rng = SplitMix64(seed: 4)
        var generator = UUIDv7Generator()

        let ids = (0..<1_000).map { _ in
            generator.next(milliseconds: 1_784_332_800_000, using: &rng)
        }

        #expect(Set(ids).count == ids.count, "no duplicates")
        #expect(ids.sorted { $0.uuidString < $1.uuidString } == ids, "strictly increasing")
    }

    @Test("Stays strictly increasing past counter exhaustion")
    func survivesCounterExhaustion() {
        var rng = SplitMix64(seed: 6)
        var generator = UUIDv7Generator()

        // rand_a is 12 bits — 4096 values. Mint well past that in one millisecond.
        let ids = (0..<10_000).map { _ in
            generator.next(milliseconds: 1_784_332_800_000, using: &rng)
        }

        #expect(Set(ids).count == ids.count, "no duplicates")
        #expect(ids.sorted { $0.uuidString < $1.uuidString } == ids, "strictly increasing")
    }

    @Test("Never regresses when the clock steps backwards")
    func toleratesClockRegression() {
        var rng = SplitMix64(seed: 5)
        var generator = UUIDv7Generator()
        let base: UInt64 = 1_784_332_800_000

        // An NTP correction drags the clock back 5 seconds mid-run.
        let clock = [base, base + 1, base + 2, base - 5_000, base - 4_999, base + 3]
        let ids = clock.map { generator.next(milliseconds: $0, using: &rng) }

        #expect(ids.sorted { $0.uuidString < $1.uuidString } == ids)
    }
}

import Foundation

/// Wire encoding for the two value shapes the spec pins independently of any
/// `JSONEncoder` configuration (SPEC §6.1, ADR-001): durations and timestamps.
///
/// Both are hand-coded rather than left to encoder strategies so the wire
/// format lives in the types and cannot drift with store configuration —
/// the same reasoning as `LedgerIdentifier`'s explicit single-value coding.

/// The canonical JSON configuration for everything LedgerKit persists (ADR-001
/// D-1, settled at M4).
///
/// **Why this exists at all: round-trip tests cannot catch a *symmetric* coding
/// bug.** If the encoder and decoder are consistently wrong in the same way — two
/// same-typed fields transposed, say — every round-trip passes while the bytes on
/// disk are silently wrong, and those bytes are permanent (§9). The only
/// instrument that catches it is a fixture asserting *literal encoded bytes*, and
/// that requires bytes to be deterministic. Hence `sortedKeys`: not aesthetics,
/// but the precondition for the frozen corpus to mean anything.
///
/// `withoutEscapingSlashes` because `\/` is legal JSON that no reader needs and
/// every human reading a fixture trips over. Compact (no `prettyPrinted`) because
/// this is the *store's* form; the on-disk corpus pretty-prints its own files,
/// where readability is the point and whitespace is invisible to the value
/// comparison those tests actually make.
///
/// **Factories, not shared instances**, and the contrast with ``WireDate`` is
/// deliberate: that type caches because constructing an `ISO8601DateFormatter`
/// measured ~120 µs and a 10k-event cold open would have spent ~1.2 s on it. A
/// `JSONEncoder` has no formatter to build and is cheap enough that one per
/// call-site — a local, so never shared across isolation domains — buys safety
/// (no `nonisolated(unsafe)`, no assumption about Foundation's thread-safety) for
/// no measured cost. Reach for a cache here only with a measurement in hand.
enum WireJSON {

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

extension Duration {
    /// Ratified wire form: integer milliseconds. Integer-exact for both
    /// sub-second tool durations and Retry-After delta-seconds, and readable
    /// in golden-log fixtures (SPEC §10.2 — fixtures double as docs).
    var wireMilliseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }

    init(wireMilliseconds: Int64) {
        self = .milliseconds(wireMilliseconds)
    }
}

/// Timestamps encode as ISO 8601 with fractional seconds
/// (`2026-07-18T09:30:00.000Z`) — millisecond precision, which is ample for a
/// display/audit-only field (SPEC §6.1: the reducer never reads timestamps).
/// Decoding also accepts the fraction-less form.
enum WireDate {
    /// - Important: `ISO8601DateFormatter` **rounds** the fractional seconds to
    ///   the nearest millisecond. `Date.ISO8601FormatStyle` — the modern,
    ///   `Sendable` alternative — **truncates** instead, and substituting it
    ///   shifts roughly three quarters of all timestamps one millisecond
    ///   earlier (measured over 100k random dates). That is a silent wire-format
    ///   change of exactly the kind ADR-001 R-4 exists to prevent, and it also
    ///   breaks `canonical(_:)` below, whose stability depends on rounding. Do
    ///   not swap these two APIs.
    ///
    /// `nonisolated(unsafe)` rather than a fresh formatter per call: constructing
    /// an `ISO8601DateFormatter` costs ~120 µs, so a 10k-event cold open (§9)
    /// would spend ~1.2 s allocating formatters it immediately discards — 75×
    /// slower than reusing one, measured. The opt-out is sound because both
    /// instances are configured here and never mutated again, and Foundation's
    /// date formatters are documented thread-safe for formatting and parsing.
    /// Note this is not a `Sendable` conformance on a public type — tenet 6's
    /// actual prohibition — but a private cache inside an internal helper.
    nonisolated(unsafe) private static let fractional = formatter(fractionalSeconds: true)
    nonisolated(unsafe) private static let plain = formatter(fractionalSeconds: false)

    static func string(from date: Date) -> String {
        fractional.string(from: date)
    }

    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }

    /// Rounds `stamp` to the millisecond the wire format can actually carry.
    ///
    /// The store calls this when it *stamps* an event, never at encode time
    /// (ADR-001 R-5): the wire form holds milliseconds but `Date` is a `Double`
    /// of seconds, so a raw `Date()` does not survive its own encoding. Since
    /// `LedgerEvent.Record` is `Equatable` and P1/P3 compare in-memory events
    /// against re-decoded ones (SPEC §10.6), an unrounded stamp would fail those
    /// property tests on microseconds of clock jitter. Canonicalizing at birth
    /// keeps equality exact at every layer above.
    ///
    /// Round-to-nearest on the integer millisecond count, and deliberately *not*
    /// a round-trip through the wire string: `parse(format(x))` looks like it
    /// would be idempotent by construction and is not, because the formatter's
    /// output is a decimal the nearest `Double` sits slightly below about half
    /// the time — so re-formatting sheds another millisecond, and roughly half
    /// of all values never reach a fixed point at all. Integer rounding lands on
    /// the `Double` nearest `ms/1000`, which is precisely the value parsing that
    /// millisecond string returns, so the round-trip closes exactly. Verified by
    /// test over the system clock rather than argued from representation.
    static func canonical(_ stamp: Date) -> Date {
        let milliseconds = (stamp.timeIntervalSince1970 * 1000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

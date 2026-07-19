import Foundation

/// Wire encoding for the two value shapes the spec pins independently of any
/// `JSONEncoder` configuration (SPEC §6.1, ADR-001): durations and timestamps.
///
/// Both are hand-coded rather than left to encoder strategies so the wire
/// format lives in the types and cannot drift with store configuration —
/// the same reasoning as `LedgerIdentifier`'s explicit single-value coding.

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
    static func string(from date: Date) -> String {
        formatter(fractionalSeconds: true).string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter(fractionalSeconds: true).date(from: string)
            ?? formatter(fractionalSeconds: false).date(from: string)
    }

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

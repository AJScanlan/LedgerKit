import Foundation
@testable import LedgerKit

// The on-disk fixture corpus (SPEC §10.2, ADR-001's "version-frozen fixture
// corpus"). Its job is narrow and long-lived: prove that logs written by an
// older LedgerKit still decode and still reduce to the same thing.
//
// The schema mirrors the events table (§9) rather than inventing a container:
// `sequence` sits *outside* the blob, exactly as it does in the real key, so a
// fixture cannot express the blob/column disagreement the physical design makes
// unrepresentable. Gaps need no representation at all — a missing sequence
// number is a missing row.

/// One fixture log, as committed.
struct CorpusDocument: Codable, Equatable {

    /// One row of the events table.
    struct Row: Codable, Equatable {

        enum Content: Equatable {
            /// A decodable wire blob — everything this version can write.
            case event(LedgerEvent.Record)
            /// **Reserved for M4.** A row whose bytes the loader could not
            /// decode. Representable in the schema now so that adding it later
            /// is not a format change, but deliberately unreadable until the
            /// real two-stage loader exists: synthesising `LoadedEvent`s
            /// test-side would freeze fixtures against a reimplementation of the
            /// decode boundary, which is the drift ADR-003 rule 2 forbids.
            case raw(String)
        }

        var sequence: Int64
        var content: Content

        private enum CodingKeys: String, CodingKey {
            case sequence, event, raw
        }

        init(sequence: Int64, content: Content) {
            self.sequence = sequence
            self.content = content
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.sequence = try container.decode(Int64.self, forKey: .sequence)

            let event = try container.decodeIfPresent(LedgerEvent.Record.self, forKey: .event)
            let raw = try container.decodeIfPresent(String.self, forKey: .raw)

            switch (event, raw) {
            case (let event?, nil):
                self.content = .event(event)
            case (nil, let raw?):
                self.content = .raw(raw)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .event, in: container,
                    debugDescription: "a row carries exactly one of `event` or `raw` (sequence \(sequence))"
                )
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sequence, forKey: .sequence)
            switch content {
            case .event(let record): try container.encode(record, forKey: .event)
            case .raw(let raw): try container.encode(raw, forKey: .raw)
            }
        }
    }

    /// The stream these rows were loaded from — the other half of §6.6 row 4's
    /// check, and why a fixture can contain a foreign event at all.
    var conversationID: ConversationID
    var rows: [Row]

    /// The reducer's input, or `nil` if the document uses a form this version
    /// cannot load yet (a reserved `raw` row).
    func loadedEvents() throws -> [LoadedEvent] {
        try rows.map { row in
            switch row.content {
            case .event(let record):
                .decoded(LedgerEvent(record: record, sequence: row.sequence))
            case .raw:
                throw CorpusError.rawRowNotLoadableUntilM4(sequence: row.sequence)
            }
        }
    }
}

enum CorpusError: Error, CustomStringConvertible {
    case rawRowNotLoadableUntilM4(sequence: Int64)

    var description: String {
        switch self {
        case .rawRowNotLoadableUntilM4(let sequence):
            "row \(sequence) is a reserved `raw` row; the two-stage loader that reads it arrives at M4"
        }
    }
}

extension CorpusDocument {

    /// Built from an in-memory fixture. Fails for logs containing
    /// `LoadedEvent.undecodable` rows — those are *loader outcomes*, not wire
    /// bytes, so they have no honest on-disk form until M4 (see `raw` above).
    init?(_ log: Log) {
        var rows: [Row] = []
        for row in log.rows {
            guard case .decoded(let event) = row else { return nil }
            rows.append(Row(sequence: event.sequence, content: .event(event.record)))
        }
        self.conversationID = log.conversation
        self.rows = rows
    }
}

// MARK: - Locations and formatting

enum CorpusFiles {

    /// Regenerable: written by record mode from `Corpus.all`, and expected to
    /// track HEAD. A diff here means the reducer or the encoder changed, which
    /// is sometimes correct — review it, then re-record.
    static let dev = "dev"

    /// Hand-authored, **never** regenerated. These are bytes this version cannot
    /// produce: future payload kinds, degraded outcomes, old shapes. Round-trip
    /// checks do not apply, because the whole point is that our encoder would
    /// write something else.
    static let wire = "wire"

    /// Empty until `0.1.0`. Once populated, a diff under here is *always* a
    /// failure — that is the entire contract (SPEC §10.2, ADR-001).
    static let frozen = "frozen"

    /// Set `LEDGERKIT_RECORD=1` to rewrite `dev/` (and the dumps beside `wire/`)
    /// instead of comparing against them.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["LEDGERKIT_RECORD"] == "1"
    }

    /// Read path — the copied resource directory.
    static var bundled: URL? {
        Bundle.module.url(forResource: "Corpus", withExtension: nil)
    }

    /// Write path — the source tree. Dev-only, which is why it is the *only*
    /// thing `#filePath` is used for here.
    static var source: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
    }

    /// Stable bytes: sorted keys so field order can never drift, pretty-printed
    /// so a review diff is line-oriented, unescaped slashes so timestamps and
    /// any JSON-in-string stay legible.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    static func logFile(_ directory: String, _ name: String) -> String {
        "\(directory)/\(name).json"
    }

    static func dumpFile(_ directory: String, _ name: String) -> String {
        "\(directory)/\(name).txt"
    }

    /// Every fixture name in a corpus directory, sorted — so iteration order is
    /// not the file system's opinion.
    static func names(in directory: String) -> [String] {
        guard let root = bundled?.appendingPathComponent(directory),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }

        return entries
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    static func read(_ relativePath: String) throws -> Data {
        guard let bundled else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: bundled.appendingPathComponent(relativePath))
    }

    static func write(_ data: Data, to relativePath: String) throws {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}

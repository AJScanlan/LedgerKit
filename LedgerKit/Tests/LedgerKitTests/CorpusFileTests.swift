import Foundation
import Testing
@testable import LedgerKit

// The on-disk corpus runner (SPEC §10.2). Three directories, three contracts:
//
//   dev/     regenerable from `Corpus.all`; a diff means the encoder or the
//            reducer changed, which is sometimes correct — review, then re-record.
//   wire/    hand-authored bytes this version cannot write (future payload kinds,
//            degraded outcomes). Never regenerated; only their dumps are.
//   frozen/  empty until 0.1.0, and a diff is *always* a failure afterwards.
//
// Regenerate with:  LEDGERKIT_RECORD=1 swift test --package-path LedgerKit

@Suite("Corpus — on-disk fixtures")
struct CorpusFileTests {

    /// Fixtures with an honest on-disk form. `rich` and `hostile` are excluded
    /// by construction, not by choice: each contains `LoadedEvent.undecodable`
    /// rows, which are *loader outcomes* rather than wire bytes and have no
    /// representation until M4's two-stage loader can read the reserved `raw`
    /// form. Their coverage is in-memory, where it is unaffected.
    private var serializable: [(fixture: CorpusFixture, document: CorpusDocument)] {
        Corpus.all.compactMap { fixture in
            CorpusDocument(fixture.log).map { (fixture, $0) }
        }
    }

    // MARK: Recording

    @Test("record mode rewrites dev/ from the in-memory corpus", .enabled(if: CorpusFiles.isRecording))
    func recordDevCorpus() throws {
        for (fixture, document) in serializable {
            try CorpusFiles.write(
                CorpusFiles.encoder.encode(document),
                to: CorpusFiles.logFile(CorpusFiles.dev, fixture.name)
            )
            try CorpusFiles.write(
                Data(StateDump.render(fixture.log.folded()).utf8),
                to: CorpusFiles.dumpFile(CorpusFiles.dev, fixture.name)
            )
        }
    }

    @Test("record mode rewrites the dumps beside hand-authored wire logs", .enabled(if: CorpusFiles.isRecording))
    func recordWireDumps() throws {
        for name in CorpusFiles.names(in: CorpusFiles.wire) {
            let document = try JSONDecoder().decode(
                CorpusDocument.self,
                from: CorpusFiles.read(CorpusFiles.logFile(CorpusFiles.wire, name))
            )
            let state = fold(try document.loadedEvents(), for: document.conversationID)
            try CorpusFiles.write(
                Data(StateDump.render(state).utf8),
                to: CorpusFiles.dumpFile(CorpusFiles.wire, name)
            )
        }
    }

    // MARK: dev/ — the regenerable half

    @Test("dev logs on disk are byte-identical to what the encoder writes today", .enabled(if: !CorpusFiles.isRecording))
    func devLogsAreCurrent() throws {
        // Encoder stability, timestamp canonicalization and field ordering, all
        // in one comparison: any drift in how this version writes a log shows up
        // as a diff rather than as a subtly different file nobody reads.
        for (fixture, document) in serializable {
            let committed = try CorpusFiles.read(CorpusFiles.logFile(CorpusFiles.dev, fixture.name))
            let current = try CorpusFiles.encoder.encode(document)
            #expect(
                current == committed,
                "\(fixture.name).json is stale — review the change, then re-record"
            )
        }
    }

    @Test("dev fixtures reduce, from bytes, to exactly the recorded state", .enabled(if: !CorpusFiles.isRecording))
    func devFixturesReduceAsRecorded() throws {
        // Deliberately folds the *file*, not the in-memory fixture: the whole
        // point of an on-disk corpus is to exercise decode → fold as a
        // composition. Folding the fixture would test the same object twice.
        for name in CorpusFiles.names(in: CorpusFiles.dev) {
            let document = try JSONDecoder().decode(
                CorpusDocument.self,
                from: CorpusFiles.read(CorpusFiles.logFile(CorpusFiles.dev, name))
            )
            let state = fold(try document.loadedEvents(), for: document.conversationID)
            let expected = try String(decoding: CorpusFiles.read(CorpusFiles.dumpFile(CorpusFiles.dev, name)), as: UTF8.self)
            #expect(StateDump.render(state) == expected, "\(name) reduced differently than recorded")
        }
    }

    // MARK: wire/ — bytes this version cannot write

    @Test("hand-authored wire logs reduce, from bytes, to exactly the recorded state", .enabled(if: !CorpusFiles.isRecording))
    func wireFixturesReduceAsRecorded() throws {
        // The end of the tolerant-terminal story. `WireFormatTests` proves the
        // decoder degrades an unfamiliar outcome; `NonRuleTests` proves the fold
        // then treats it as a terminal. This proves the composition survives a
        // round trip through *bytes on disk written by a different version* —
        // which is the only form the forward-compatibility claim actually takes.
        let names = CorpusFiles.names(in: CorpusFiles.wire)
        #expect(!names.isEmpty, "the wire corpus is empty; the composition is untested from bytes")

        for name in names {
            let document = try JSONDecoder().decode(
                CorpusDocument.self,
                from: CorpusFiles.read(CorpusFiles.logFile(CorpusFiles.wire, name))
            )
            let state = fold(try document.loadedEvents(), for: document.conversationID)
            let expected = try String(decoding: CorpusFiles.read(CorpusFiles.dumpFile(CorpusFiles.wire, name)), as: UTF8.self)
            #expect(StateDump.render(state) == expected, "\(name) reduced differently than recorded")
        }
    }

    // MARK: frozen/ — the contract that outlives everything else

    @Test("frozen fixtures still decode and still reduce to what they recorded")
    func frozenFixturesAreIntact() throws {
        // Empty until `0.1.0` is tagged; the M9 procedure is in Corpus/README.md.
        // Deliberately *not* gated on record mode: nothing may ever rewrite a
        // frozen expectation, so there is no branch here that could.
        for name in CorpusFiles.names(in: CorpusFiles.frozen) {
            let document = try JSONDecoder().decode(
                CorpusDocument.self,
                from: CorpusFiles.read(CorpusFiles.logFile(CorpusFiles.frozen, name))
            )
            let state = fold(try document.loadedEvents(), for: document.conversationID)
            let expected = try String(decoding: CorpusFiles.read(CorpusFiles.dumpFile(CorpusFiles.frozen, name)), as: UTF8.self)
            #expect(StateDump.render(state) == expected, "FROZEN fixture \(name) changed meaning")
        }
    }

    // MARK: Schema properties

    @Test("every corpus row round-trips through the wire codec by value", .enabled(if: !CorpusFiles.isRecording))
    func rowsRoundTrip() throws {
        // Byte-identity is `devLogsAreCurrent`'s job and cannot hold for `wire/`,
        // whose files are deliberately shapes this encoder would not write.
        // Value-identity must hold everywhere — an asymmetric codec would lose
        // data on the first re-save.
        for directory in [CorpusFiles.dev, CorpusFiles.wire, CorpusFiles.frozen] {
            for name in CorpusFiles.names(in: directory) {
                let document = try JSONDecoder().decode(
                    CorpusDocument.self,
                    from: CorpusFiles.read(CorpusFiles.logFile(directory, name))
                )
                let reencoded = try JSONDecoder().decode(
                    CorpusDocument.self,
                    from: CorpusFiles.encoder.encode(document)
                )
                #expect(reencoded == document, "\(directory)/\(name) does not round-trip by value")
            }
        }
    }

    @Test("corpus timestamps are born canonical", .enabled(if: !CorpusFiles.isRecording))
    func timestampsAreCanonical() throws {
        // M4's store must stamp at wire precision (millisecond ISO 8601), not
        // canonicalize at encode: canonicalizing late gives every event two
        // identities depending on whether it has been to disk, which is exactly
        // the bug class P1 and P3 exist to catch. The corpus holds the line now
        // so the store inherits a fixture that already fails if it slips.
        for directory in [CorpusFiles.dev, CorpusFiles.wire, CorpusFiles.frozen] {
            for name in CorpusFiles.names(in: directory) {
                let document = try JSONDecoder().decode(
                    CorpusDocument.self,
                    from: CorpusFiles.read(CorpusFiles.logFile(directory, name))
                )
                for row in document.rows {
                    guard case .event(let record) = row.content else { continue }
                    #expect(
                        WireDate.canonical(record.timestamp) == record.timestamp,
                        "\(directory)/\(name) row \(row.sequence) carries sub-millisecond precision"
                    )
                }
            }
        }
    }

    @Test("the corpus covers every payload kind in the discriminator registry", .enabled(if: !CorpusFiles.isRecording))
    func corpusCoversTheWireSurface() throws {
        // The corpus exists to protect *encoding* evolution, so a payload kind
        // absent from it is a kind with no evolution safety net at all. ADR-001
        // calls the registry permanent; this is the check that a new tag arrives
        // with a fixture rather than a year later.
        let registry: Set<String> = [
            "conversationCreated", "userMessageAppended", "instructionsChanged",
            "generationStarted", "deltaAppended", "toolInvocationRecorded",
            "generationEnded", "messageEdited", "activePathChanged", "titleChanged",
        ]

        var covered: Set<String> = []
        for directory in [CorpusFiles.dev, CorpusFiles.wire, CorpusFiles.frozen] {
            for name in CorpusFiles.names(in: directory) {
                let json = try JSONSerialization.jsonObject(
                    with: CorpusFiles.read(CorpusFiles.logFile(directory, name))
                ) as? [String: Any]
                for row in json?["rows"] as? [[String: Any]] ?? [] {
                    if let payload = (row["event"] as? [String: Any])?["payload"] as? [String: Any],
                       let kind = payload["kind"] as? String {
                        covered.insert(kind)
                    }
                }
            }
        }

        #expect(
            registry.subtracting(covered).isEmpty,
            "payload kinds with no on-disk fixture: \(registry.subtracting(covered).sorted())"
        )
        #expect(
            covered.subtracting(registry).isEmpty,
            "corpus contains kinds outside the registry: \(covered.subtracting(registry).sorted())"
        )
    }
}

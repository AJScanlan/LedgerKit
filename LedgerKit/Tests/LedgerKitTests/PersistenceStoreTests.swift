import Foundation
import Testing
@testable import LedgerKit

// Phase 1 of M4: the GRDB conformance of the §9 seam. Every suite here runs
// against `.inMemory`, which is a *real* SQL engine with no I/O — the
// persistence counterpart of `ScriptedLanguageModel` (tenet 5), and the reason
// these tests are as fast as the pure ones.
//
// Fixtures come from `Log` (ReducerFixtures.swift) rather than being rebuilt
// here: the store suites replay exactly the logs the reducer suites fold, so a
// disagreement between the two layers has nowhere to hide.

@Suite("Persistence — append")
struct PersistenceAppendTests {

    @Test("appended records round-trip value-identical, and the read agrees with the write")
    func roundTrip() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        let log = Log.withCompletedTurn()

        let appended = try await store.append(log.records, to: log.conversation)
        let loaded = try await store.events(in: log.conversation, from: 1)

        // Two claims in one: the bytes survived (value identity through
        // encode → SQLite → decode), and `append`'s return value is the same
        // thing a subsequent read produces. M5's store actor relies on the
        // second — it folds the returned tail forward instead of re-reading,
        // which is only sound if the two are interchangeable (P1's shape).
        #expect(loaded == appended.map(LoadedEvent.decoded))
        #expect(appended.count == log.records.count)
    }

    @Test("sequence is contiguous from 1 across separate batches")
    func sequenceContiguity() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        let log = Log.withCompletedTurn()
        let records = log.records

        // Three appends, as three transactions — the shape a real conversation
        // has (a verb, then a flush, then a terminal), not one bulk insert.
        var appended: [LedgerEvent] = []
        appended += try await store.append(Array(records[0..<2]), to: log.conversation)
        appended += try await store.append(Array(records[2..<3]), to: log.conversation)
        appended += try await store.append(Array(records[3...]), to: log.conversation)

        #expect(appended.map(\.sequence) == Array(1...Int64(records.count)))
    }

    @Test("the backend assigns sequence — the caller cannot influence it")
    func sequenceIsTheBackends() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        let log = Log.opened()

        let appended = try await store.append(log.records, to: log.conversation)

        // `Record` has no sequence field to carry a suggestion, which is the
        // structural half of §6.1; this is the behavioural half. Deciding
        // "max + 1" anywhere but inside the write transaction is how an
        // append-only log grows duplicate keys.
        #expect(appended.map(\.sequence) == [1])
    }

    @Test("an empty batch is a no-op")
    func emptyBatch() async throws {
        let store = try SQLitePersistenceStore(.inMemory)

        let appended = try await store.append([], to: Fix.conversation)

        #expect(appended.isEmpty)
        #expect(try await store.events(in: Fix.conversation, from: 1).isEmpty)
        // No index row either: an empty batch must not conjure a conversation.
        #expect(try await store.conversationSummaries().isEmpty)
    }

    @Test("a foreign conversationID rejects the whole batch, recording nothing")
    func foreignRecordRejectsBatch() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        var log = Log.opened()
        log.append(.userMessageAppended(Fix.userA, content: "mine", parent: nil))
        log.append(.titleChanged("theirs"), from: Fix.foreign)

        await #expect(throws: SQLitePersistenceStore.StoreError.conversationMismatch(
            expected: Fix.conversation, found: Fix.foreign
        )) {
            try await store.append(log.records, to: Fix.conversation)
        }

        // The batch is the unit of meaning (§9), so a rejected batch leaves
        // *nothing* — not the two valid records that preceded the bad one, and
        // no consumed sequence numbers. This is what makes §11's two-channel
        // contract literally rather than approximately true.
        #expect(try await store.events(in: Fix.conversation, from: 1).isEmpty)
        #expect(try await store.conversationSummaries().isEmpty)
    }

    @Test("reads from a sequence return exactly the suffix")
    func suffixRead() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        let log = Log.withCompletedTurn()
        _ = try await store.append(log.records, to: log.conversation)

        let suffix = try await store.events(in: log.conversation, from: 3)

        // `withCompletedTurn` is genesis, user message, start, delta, terminal.
        // The snapshot fast-path (§9, Phase 3) is built on this read: resume
        // takes only what the checkpoint has not already folded.
        #expect(suffix.map(\.sequence) == [3, 4, 5])
        #expect(log.records.count == 5)
    }

    @Test("fixture records are born canonical, so append's ADR-001 R-5 assertion holds")
    func fixturesAreCanonical() {
        // Pinned rather than assumed. `append` asserts this contract in debug
        // instead of quietly repairing it, because canonicalizing at write time
        // would give every event two identities depending on whether it had been
        // to disk — the exact bug class P1/P3 exist to catch. If fixtures ever
        // stop honouring it, this fails with a legible reason rather than an
        // assertion trap deep inside a store call.
        #expect(Log.withCompletedTurn().timestampsAreCanonical)
    }
}

@Suite("Persistence — the file backend")
struct PersistenceFileBackendTests {

    @Test("a file-backed store persists across instances, and reopening re-migrates cleanly")
    func reopenReadsWhatWasWritten() async throws {
        // The one suite that exercises the *production* shape: `DatabasePool`,
        // WAL, the file-protection call, and — the real risk — running the
        // migrator against a database that already has the schema. Everything
        // else here uses `.inMemory`, which would never catch a migration that
        // is not idempotent.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledgerkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")

        let log = Log.withCompletedTurn()
        let written = try await {
            let store = try SQLitePersistenceStore(.sqlite(url: url))
            return try await store.append(log.records, to: log.conversation)
        }()

        // A second store over the same file — the cold-open path an app takes on
        // every launch, and the one the kill-mid-stream demo depends on (DoD-1).
        let reopened = try SQLitePersistenceStore(.sqlite(url: url))
        let loaded = try await reopened.events(in: log.conversation, from: 1)

        #expect(loaded == written.map(LoadedEvent.decoded))
        #expect(try await reopened.conversationSummaries().count == 1)
    }
}

@Suite("Persistence — the conversations index")
struct PersistenceIndexTests {

    @Test("genesis seeds the index row")
    func genesisSeedsRow() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        let log = Log.opened(title: "Valley folds 101")
        _ = try await store.append(log.records, to: log.conversation)

        let summaries = try await store.conversationSummaries()

        #expect(summaries.count == 1)
        #expect(summaries.first?.id == log.conversation)
        #expect(summaries.first?.title == "Valley folds 101")
        // `createdAt` is genesis's own stamp by definition — it *is* the moment
        // the conversation began.
        #expect(summaries.first?.createdAt == log.timestamp(at: 1))
        #expect(summaries.first?.lastEventAt == log.timestamp(at: 1))
    }

    @Test("titleChanged updates the row, and nil clears it")
    func titleTracked() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        var log = Log.opened(title: "first")
        log.append(.titleChanged("second"))
        log.append(.titleChanged(nil))
        _ = try await store.append(log.records, to: log.conversation)

        let summary = try await store.conversationSummaries().first
        // Last-write-wins, including the clear — symmetric with instructions
        // (§6.1), and the index must not treat nil as "no update".
        #expect(summary?.title == nil)
        #expect(summary?.lastEventAt == log.timestamp(at: 3))
    }

    @Test("delta flushes deliberately do not touch the index (§9 — no ~4 Hz churn)")
    func deltasDoNotTouchIndex() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        var log = Log.withUserMessage()
        log.append(.generationStarted(Fix.genA, Fix.assistantA, parent: Fix.userA, model: Fix.model))
        let beforeDeltas = log.lastSequence
        log.append(.deltaAppended(Fix.genA, text: "A valley "))
        log.append(.deltaAppended(Fix.genA, text: "fold"))

        let records = log.records
        _ = try await store.append(Array(records[0..<Int(beforeDeltas)]), to: log.conversation)
        let stampBeforeFlush = try await store.conversationSummaries().first?.lastEventAt
        // The flush: two deltas, appended as their own transaction, exactly as
        // the driver's coalescing policy will (§7.4).
        _ = try await store.append(Array(records[Int(beforeDeltas)...]), to: log.conversation)

        let stampAfterFlush = try await store.conversationSummaries().first?.lastEventAt

        // A streaming generation would otherwise rewrite this row — and wake
        // every observer of it — at flush cadence, to report something the list
        // does not display. `lastEventAt` means "last *meaningful* event".
        #expect(stampAfterFlush == stampBeforeFlush)
        #expect(stampAfterFlush == log.timestamp(at: beforeDeltas))
        // The deltas are still in the log, of course — only the projection
        // ignores them.
        #expect(try await store.events(in: log.conversation, from: 1).count == records.count)
    }

    @Test("a non-delta append after a flush moves the stamp again")
    func terminalMovesStamp() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        let log = Log.withCompletedTurn()
        _ = try await store.append(log.records, to: log.conversation)

        // The terminal is the natural quiescent point (§9's snapshot policy
        // hangs off it), so the list must see it.
        #expect(try await store.conversationSummaries().first?.lastEventAt
            == log.timestamp(at: log.lastSequence))
    }

    @Test("the list is ordered by last event, most recent first")
    func listOrdering() async throws {
        let store = try SQLitePersistenceStore(.inMemory)

        var older = Log(Fix.conversation)
        older.append(.conversationCreated(title: "older"))
        var newer = Log(Fix.foreign)
        newer.append(.conversationCreated(title: "newer"))
        newer.append(.titleChanged("newer, retitled"))

        _ = try await store.append(older.records, to: older.conversation)
        _ = try await store.append(newer.records, to: newer.conversation)

        // Timestamps are canonical ISO 8601 UTC, so the index's lexical ordering
        // *is* chronological — no collation, one table read (G9).
        #expect(try await store.conversationSummaries().map(\.id) == [newer.conversation, older.conversation])
    }
}

@Suite("Persistence — snapshots & deletion")
struct PersistenceSnapshotTests {

    private func snapshot(_ upTo: Int64, payload: String) -> Snapshot {
        Snapshot(
            conversationID: Fix.conversation,
            reducerVersion: LedgerSchema.reducerVersion,
            schemaVersion: LedgerSchema.payloadVersion,
            upToSequence: upTo,
            payload: Data(payload.utf8)
        )
    }

    @Test("no snapshot yet reads as nil, not as an error")
    func missingSnapshot() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        #expect(try await store.latestSnapshot(for: Fix.conversation) == nil)
    }

    @Test("a saved snapshot round-trips")
    func snapshotRoundTrip() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        let saved = snapshot(4, payload: "{}")

        try await store.save(saved)

        #expect(try await store.latestSnapshot(for: Fix.conversation) == saved)
    }

    @Test("saving replaces rather than accumulating")
    func snapshotReplaces() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        try await store.save(snapshot(4, payload: "{\"a\":1}"))
        try await store.save(snapshot(9, payload: "{\"b\":2}"))

        // An older checkpoint of the same log is never the useful one, and
        // keeping it would make "latest" a question the schema had to answer
        // rather than a fact it guarantees.
        let latest = try await store.latestSnapshot(for: Fix.conversation)
        #expect(latest?.upToSequence == 9)
        #expect(latest?.payload == Data("{\"b\":2}".utf8))
    }

    @Test("deletion removes events, snapshot and index row together")
    func deletionIsTotal() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        let log = Log.withCompletedTurn()
        _ = try await store.append(log.records, to: log.conversation)
        try await store.save(snapshot(log.lastSequence, payload: "{}"))

        try await store.deleteConversation(log.conversation)

        // All three tables, one transaction (§9). A residual snapshot or index
        // row would be a conversation that half-exists — visible in a list, or
        // resurrectable from a checkpoint, after the user deleted it.
        #expect(try await store.events(in: log.conversation, from: 1).isEmpty)
        #expect(try await store.latestSnapshot(for: log.conversation) == nil)
        #expect(try await store.conversationSummaries().isEmpty)
    }

    @Test("deletion is scoped to one conversation")
    func deletionIsScoped() async throws {
        let store = try SQLitePersistenceStore(.inMemory)
        var mine = Log(Fix.conversation)
        mine.append(.conversationCreated(title: "mine"))
        var theirs = Log(Fix.foreign)
        theirs.append(.conversationCreated(title: "theirs"))
        _ = try await store.append(mine.records, to: mine.conversation)
        _ = try await store.append(theirs.records, to: theirs.conversation)

        try await store.deleteConversation(mine.conversation)

        #expect(try await store.events(in: theirs.conversation, from: 1).count == 1)
        #expect(try await store.conversationSummaries().map(\.id) == [theirs.conversation])
    }
}

@Suite("Persistence — corpus equivalence")
struct PersistenceCorpusEquivalenceTests {

    @Test("every replayable corpus fixture reduces identically after a round trip through the store")
    func corpusSurvivesTheStore() async throws {
        // The join M4 exists to make: until now the corpus proved the *reducer*
        // right about logs held in memory, and Phase 1 proved the *store* right
        // about records it invented. This composes them — encode → SQLite →
        // two-stage decode → fold must land on the same `FoldedState` the
        // in-memory fixture folds to, for every fixture the store can express.
        var replayed = 0
        var skipped: [String] = []

        for fixture in Corpus.all {
            guard fixture.log.isStoreReplayable else {
                skipped.append(fixture.name)
                continue
            }
            let store = try SQLitePersistenceStore(.inMemory)
            _ = try await store.append(fixture.log.records, to: fixture.log.conversation)
            let loaded = try await store.events(in: fixture.log.conversation, from: 1)

            #expect(
                fold(loaded, for: fixture.log.conversation) == fixture.log.folded(),
                "\(fixture.name) reduced differently after a round trip through the store"
            )
            replayed += 1
        }

        // Non-vacuity, the M3 practice: a loop narrowed to nothing passes in
        // silence, and this is a sweep worth losing that way.
        #expect(replayed >= 7, "only \(replayed) fixtures were replayed")
        // The skips are the fixtures with a gap, a byte-built row, or a foreign
        // event — see `isStoreReplayable`. Named rather than counted so that a
        // fixture becoming unexpectedly unreplayable is visible in the failure.
        #expect(skipped.sorted() == ["gapSwallowedTerminal", "hostile", "rich"])
    }
}

@Suite("Persistence — two-stage decode")
struct TwoStageDecodeTests {

    // Bytes rather than a database: the decode rules are pure, so this is both
    // the sharper test and the cheaper one. Phase 2 exercises the same rules
    // from *disk*, through the on-disk corpus's reserved `raw` row form.

    private static let envelope = """
        "id":"01980E5A-0000-7000-8000-000000000101",\
        "conversationID":"01980E5A-0000-7000-8000-000000000001",\
        "timestamp":"2026-07-25T11:30:47.371Z"
        """

    private func load(_ json: String, sequence: Int64 = 7) -> LoadedEvent {
        SQLitePersistenceStore.load(
            sequence: sequence,
            json: Data(json.utf8),
            using: WireJSON.decoder()
        )
    }

    @Test("a well-formed row decodes")
    func wellFormed() {
        let row = load("""
            {\(Self.envelope),"payload":{"kind":"titleChanged","title":"ok"}}
            """)

        guard case .decoded(let event) = row else {
            Issue.record("expected a decoded row, got \(row)")
            return
        }
        #expect(event.sequence == 7)
        #expect(event.payload == .titleChanged("ok"))
    }

    @Test("an unknown payload kind keeps the event's identity (§6.6 row 2)")
    func unknownKindKeepsIdentity() {
        let row = load("""
            {\(Self.envelope),"payload":{"kind":"compactionRecorded","summary":"…"}}
            """)

        // This is the whole reason decode is two-stage. A single all-or-nothing
        // `Record` decode throws on the unknown kind and discards the envelope
        // with it — and row 2 is the *forward-compatibility* row, so it is
        // precisely the diagnostic someone reads when a newer LedgerKit wrote
        // the log. "Sequence 7 was unreadable" is a materially worse answer than
        // the same sentence naming the event.
        #expect(row == .undecodable(
            sequence: 7,
            eventID: EventID(uuid(0x101)),
            .payloadKind("compactionRecorded")
        ))
    }

    @Test("a corrupt envelope recovers no identity (§6.6 row 1)")
    func corruptEnvelopeHasNoIdentity() {
        for json in [
            #"{"id":"not-a-uuid","conversationID":"01980E5A-0000-7000-8000-000000000001","timestamp":"2026-07-25T11:30:47.371Z","payload":{"kind":"titleChanged"}}"#,
            #"{"conversationID":"01980E5A-0000-7000-8000-000000000001","timestamp":"2026-07-25T11:30:47.371Z","payload":{"kind":"titleChanged"}}"#,
            "not json at all",
        ] {
            // `undecodableEnvelope ⇒ eventID == nil` is a contract the fold's
            // diagnostic-identity check relies on, so the loader must never
            // report a *partially* recovered envelope as identified.
            #expect(load(json) == .undecodable(sequence: 7, eventID: nil, .envelope))
        }
    }

    @Test("an unparseable timestamp is an envelope failure, not an identified row")
    func corruptTimestampIsEnvelopeFailure() {
        let row = load("""
            {"id":"01980E5A-0000-7000-8000-000000000101",\
            "conversationID":"01980E5A-0000-7000-8000-000000000001",\
            "timestamp":"last Tuesday",\
            "payload":{"kind":"titleChanged","title":"ok"}}
            """)

        // Identity counts as recovered only if the *whole* envelope reads. An
        // event that claimed identity while lying about when it happened would
        // be worse than one that admits it is unreadable — timestamps are
        // display/audit data, and a wrong one is silently wrong.
        #expect(row == .undecodable(sequence: 7, eventID: nil, .envelope))
    }

    @Test("a decodable row is never reported as a gap")
    func rowsAreEmittedNotDropped() {
        // The §6.6 input corollary, at its narrowest: every row in, every row
        // out. Dropping an unreadable row would turn a row-1/2 condition into a
        // *gap* diagnostic — and a gap says the fact is missing, where an
        // undecodable row says the fact is present and unintelligible.
        let rows = [
            load(#"{"id":"bad"}"#, sequence: 1),
            load("{\(Self.envelope),\"payload\":{\"kind\":\"titleChanged\"}}", sequence: 2),
        ]
        #expect(rows.map(\.sequence) == [1, 2])
    }
}

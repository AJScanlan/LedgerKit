import Foundation
import GRDB

/// The GRDB conformance of ``PersistenceStore`` (SPEC §9, ADR-003 — wired at M4,
/// which is what ratifies that ADR).
///
/// **This type is where "bytes below, meaning above" is enforced.** SQLite stores
/// encoded JSON plus the columns needed for keys and the index, and never
/// interprets them — it cannot corrupt what it does not read. The one thing that
/// *does* happen here is decode, and it happens here for a precise reason: §6.6's
/// input corollary requires an unreadable row to be **emitted** as a
/// `LoadedEvent`, not dropped (which would fake a gap) and not thrown (which
/// would make one bad row lose a whole conversation, against I2). Only the layer
/// that touches bytes can tell the difference, so only this layer can make that
/// call. Everything above it — quarantine semantics, snapshot version policy —
/// stays out.
///
/// Internal on purpose: consumers name a backend with ``PersistenceConfiguration``
/// and never see this type, GRDB, or a `Database` handle (ADR-003 rules 1 and 3).
final class SQLitePersistenceStore: PersistenceStore {

    /// Errors that mean the *caller* got it wrong, as opposed to the data being
    /// damaged. Internal: the public error surface is `LedgerError`, designed at
    /// M5 against the real verbs, and inventing a public error here would commit
    /// to a shape before the callers that must live with it exist.
    enum StoreError: Error, Equatable {
        /// A record in the batch names a different conversation than the one
        /// being appended to. Thrown *before* anything is written, so the batch's
        /// all-or-nothing promise holds.
        case conversationMismatch(expected: ConversationID, found: ConversationID)
    }

    private let writer: any DatabaseWriter

    /// Opens (or creates) the database and brings the schema up to date.
    ///
    /// `DatabasePool` for a file, `DatabaseQueue` for in-memory, both behind
    /// `any DatabaseWriter` — which is why ADR-003 could call this "not an API
    /// decision." The pool gives WAL and concurrent reads, which M7's projection
    /// wants while a write is in flight; in-memory databases have no pool form,
    /// and want none, since a test has nothing to read concurrently.
    init(_ configuration: PersistenceConfiguration) throws {
        switch configuration.backend {
        case .inMemory:
            self.writer = try DatabaseQueue()
        case .sqlite(let url):
            self.writer = try DatabasePool(path: url.path)
            try Self.protectFiles(at: url)
        }
        try Self.migrator.migrate(writer)
    }

    // MARK: - Schema

    /// The schema. One migration today; `DatabaseMigrator` exists because *table*
    /// shape may evolve even though **data never migrates** — events are
    /// versioned-and-frozen (ADR-001) and snapshots are discard-on-mismatch (§9).
    ///
    /// `STRICT` tables throughout: SQLite's default type affinity would happily
    /// store a string in an integer column, and tenet 1 does not stop being true
    /// at the storage layer.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-ledger") { db in
            // `sequence` lives ONLY here, never in the blob (§6.1/§9), so a
            // blob/column disagreement about order is unrepresentable rather
            // than merely checked. `conversation_id` is the deliberate
            // exception — duplicated in both places, which is precisely what
            // §6.6 row 4 (cross-stream contamination) reads back to verify.
            //
            // `payload` is TEXT, not BLOB. JSON is text, and a log that
            // `sqlite3 ledger.db "SELECT payload FROM events"` prints readably
            // is worth a great deal in a project whose fixtures are
            // documentation — it also puts SQLite's json1 functions within
            // reach for ad-hoc triage. The database still never *interprets*
            // it, which is the property ADR-003 rule 2 actually asks for.
            //
            // `schema_version` is column-only (M4-PLAN D16): a version is
            // loader routing metadata, exactly like `sequence`, and putting it
            // in the blob too would add a permanent envelope key to every event
            // ever written in exchange for self-description that no transport
            // needs — log transport moves *rows*, not bare blobs.
            try db.execute(sql: """
                CREATE TABLE events (
                    conversation_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    schema_version INTEGER NOT NULL,
                    payload TEXT NOT NULL,
                    PRIMARY KEY (conversation_id, sequence)
                ) STRICT
                """)

            // The index projection (G9): the conversation list is one table read,
            // never N reductions. Rebuildable by scanning the log — same class as
            // snapshots, and deletable at any time.
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT NOT NULL PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    title TEXT,
                    last_event_at TEXT NOT NULL
                ) STRICT
                """)
            // Timestamps are canonical ISO 8601 UTC (ADR-001 R-4), so lexical
            // order *is* chronological order and this index serves the list's
            // only sort without a collation.
            try db.execute(sql: """
                CREATE INDEX conversations_by_last_event
                ON conversations(last_event_at DESC)
                """)

            // One row per conversation: `save` replaces rather than accumulates,
            // because an older checkpoint of the same log is never the useful
            // one. `payload` is BLOB here where events are TEXT — the seam types
            // it as `Data`, it is a disposable cache rather than audited truth,
            // and nobody reads a snapshot by eye.
            try db.execute(sql: """
                CREATE TABLE snapshots (
                    conversation_id TEXT NOT NULL PRIMARY KEY,
                    reducer_version INTEGER NOT NULL,
                    schema_version INTEGER NOT NULL,
                    up_to_sequence INTEGER NOT NULL,
                    payload BLOB NOT NULL
                ) STRICT
                """)
        }
        return migrator
    }

    /// Applies §9's minimum file protection to the database and its sidecars.
    ///
    /// Data protection is an iOS-family concept; on macOS the equivalent is
    /// FileVault, which is not ours to set. **Owned limitation:** `-wal` and
    /// `-shm` do not exist until the first write, so they are protected on the
    /// next open rather than this one, and the robust answer is protection on the
    /// *containing directory* — which belongs to the app, since the app chose the
    /// directory. §9's guidance that sensitive domains layer their own encryption
    /// stands, and this is a floor, not a guarantee.
    private static func protectFiles(at url: URL) throws {
        #if os(iOS) || os(visionOS) || os(watchOS)
        let manager = FileManager.default
        let sidecars = ["", "-wal", "-shm"].map { url.path + $0 }
        for path in sidecars where manager.fileExists(atPath: path) {
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        }
        #endif
    }

    // MARK: - Appending

    func append(
        _ records: [LedgerEvent.Record],
        to conversation: ConversationID
    ) async throws -> [LedgerEvent] {
        guard !records.isEmpty else { return [] }

        // Checked before opening the transaction: this is a caller bug, and
        // there is nothing to roll back if we never start.
        for record in records where record.conversationID != conversation {
            throw StoreError.conversationMismatch(
                expected: conversation,
                found: record.conversationID
            )
        }

        // Timestamps must arrive already canonical (ADR-001 R-5). Canonicalizing
        // *here* would be the tempting fix and the wrong one: it gives every
        // event two identities depending on whether it has been to disk, which
        // is the exact bug class P1/P3 exist to catch. So this asserts the
        // caller's contract in debug rather than quietly repairing it.
        assert(
            records.allSatisfy { WireDate.canonical($0.timestamp) == $0.timestamp },
            "records must be stamped at wire precision before append (ADR-001 R-5)"
        )

        let encoder = WireJSON.encoder()
        let blobs = try records.map { try encoder.encode($0) }

        return try await writer.write { db in
            // "max + 1" is safe here and *only* here: inside the write
            // transaction, holding SQLite's write lock. Computing it outside is
            // precisely how an append-only log grows duplicate keys.
            let lastSequence = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(sequence) FROM events WHERE conversation_id = ?",
                arguments: [conversation.sqlText]
            ) ?? 0

            var events: [LedgerEvent] = []
            events.reserveCapacity(records.count)

            for (offset, record) in records.enumerated() {
                let sequence = lastSequence + Int64(offset) + 1
                try db.execute(
                    sql: """
                        INSERT INTO events (conversation_id, sequence, schema_version, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        record.conversationID.sqlText,
                        sequence,
                        LedgerSchema.payloadVersion,
                        String(decoding: blobs[offset], as: UTF8.self),
                    ]
                )
                events.append(LedgerEvent(record: record, sequence: sequence))
            }

            try Self.updateIndex(db, for: records)
            return events
        }
    }

    /// Maintains the `conversations` row inside the append transaction (§9).
    ///
    /// **Delta flushes deliberately do not touch it.** A streaming generation
    /// would otherwise rewrite this row — and wake every value observer watching
    /// it — at flush cadence, roughly 4 Hz, to report information the list does
    /// not show. `last_event_at` therefore means "last *meaningful* event", which
    /// is what a conversation list sorts by anyway; live activity is the
    /// projection's overlay to render (§7.4), not the index's.
    ///
    /// The rule is derived from the payload kinds handed in, never from a
    /// caller-supplied flag: §9 states it in terms of kind, so a flag could only
    /// ever *disagree* with the payloads — an illegal state this signature cannot
    /// represent.
    private static func updateIndex(_ db: Database, for records: [LedgerEvent.Record]) throws {
        for record in records {
            guard record.payload.updatesIndex else { continue }
            switch record.payload {
            case .conversationCreated(let title):
                // Genesis seeds the row. `created_at` is this event's stamp by
                // definition — it is the moment the conversation began.
                try db.execute(
                    sql: """
                        INSERT INTO conversations (id, created_at, title, last_event_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            title = excluded.title,
                            last_event_at = excluded.last_event_at
                        """,
                    arguments: [
                        record.conversationID.sqlText,
                        WireDate.string(from: record.timestamp),
                        title,
                        WireDate.string(from: record.timestamp),
                    ]
                )
            case .titleChanged(let title):
                try db.execute(
                    sql: """
                        UPDATE conversations SET title = ?, last_event_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        title,
                        WireDate.string(from: record.timestamp),
                        record.conversationID.sqlText,
                    ]
                )
            default:
                try db.execute(
                    sql: "UPDATE conversations SET last_event_at = ? WHERE id = ?",
                    arguments: [
                        WireDate.string(from: record.timestamp),
                        record.conversationID.sqlText,
                    ]
                )
            }
        }
    }

    // MARK: - Reading

    func events(in conversation: ConversationID, from sequence: Int64) async throws -> [LoadedEvent] {
        try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT sequence, payload FROM events
                    WHERE conversation_id = ? AND sequence >= ?
                    ORDER BY sequence
                    """,
                arguments: [conversation.sqlText, sequence]
            )
            // Gaps are returned as-is: a hole is the reducer's to diagnose
            // (§6.1), and a backend that "helpfully" closed one would destroy
            // the only evidence that a partial restore happened.
            let decoder = WireJSON.decoder()
            return rows.map { row in
                let payload: String = row["payload"]
                return Self.load(
                    sequence: row["sequence"],
                    json: Data(payload.utf8),
                    using: decoder
                )
            }
        }
    }

    /// Two-stage decode: **envelope first, payload second** (ADR-001, §6.6
    /// "Diagnostic identity").
    ///
    /// The order is the whole point. A single all-or-nothing
    /// `Record.init(from:)` throws on an unrecognized payload kind and discards
    /// the envelope along with it — silently degrading every §6.6 row-2
    /// diagnostic to sequence-only. Row 2 is the *forward-compatibility* row, so
    /// it is exactly the diagnostic a developer reads when a newer LedgerKit
    /// wrote the log, and "sequence 4,102 was unreadable" is a materially worse
    /// answer than the same sentence naming the event.
    ///
    /// Identity counts as recovered only if the **whole** envelope reads —
    /// including the timestamp. That keeps `undecodableEnvelope ⇒ eventID == nil`
    /// true by construction, which is the invariant the fold's diagnostic-identity
    /// check relies on, rather than leaving a half-read envelope to decide for
    /// itself how much identity it has.
    /// Internal rather than private so its tests can hand it bytes directly.
    /// That is the sharper test *and* the cheaper one: the decode rules are pure,
    /// so exercising them through a database would add I/O and a GRDB dependency
    /// in the test target to verify something with no storage in it. The
    /// enclosing type is already internal, so this widens no surface.
    static func load(sequence: Int64, json: Data, using decoder: JSONDecoder) -> LoadedEvent {
        guard let envelope = try? decoder.decode(EnvelopeProbe.self, from: json) else {
            return .undecodable(sequence: sequence, eventID: nil, .envelope)
        }
        do {
            let record = try decoder.decode(LedgerEvent.Record.self, from: json)
            return .decoded(LedgerEvent(record: record, sequence: sequence))
        } catch {
            let tag = (try? decoder.decode(PayloadTagProbe.self, from: json))?.payload?.kind
            return .undecodable(sequence: sequence, eventID: envelope.id, .payloadKind(tag))
        }
    }

    /// The envelope alone — everything `Record` carries except the payload.
    ///
    /// Decodes the timestamp through ``WireDate`` rather than accepting any
    /// string, so a corrupt stamp is an envelope failure (row 1) instead of an
    /// event that claims identity while lying about when it happened.
    private struct EnvelopeProbe: Decodable {
        let id: EventID
        let conversationID: ConversationID
        let timestamp: Date

        private enum CodingKeys: String, CodingKey {
            case id, conversationID, timestamp
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(EventID.self, forKey: .id)
            self.conversationID = try container.decode(ConversationID.self, forKey: .conversationID)
            let raw = try container.decode(String.self, forKey: .timestamp)
            guard let timestamp = WireDate.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timestamp, in: container,
                    debugDescription: "not an ISO 8601 timestamp: \(raw)"
                )
            }
            self.timestamp = timestamp
        }
    }

    /// Recovers just the payload discriminator, so a row-2 diagnostic can name
    /// the tag it did not recognize. Everything optional: this runs only on rows
    /// already known to be damaged.
    private struct PayloadTagProbe: Decodable {
        struct Tag: Decodable {
            let kind: String?
        }

        let payload: Tag?
    }

    // MARK: - Snapshots

    func latestSnapshot(for conversation: ConversationID) async throws -> Snapshot? {
        try await writer.read { db in
            // Returned regardless of version: whether a snapshot is *usable* is
            // policy, and policy lives above the seam (§9). The version fields
            // ride outside `payload` precisely so that decision costs no decode.
            try Row.fetchOne(
                db,
                sql: """
                    SELECT reducer_version, schema_version, up_to_sequence, payload
                    FROM snapshots WHERE conversation_id = ?
                    """,
                arguments: [conversation.sqlText]
            )
            .map { row in
                Snapshot(
                    conversationID: conversation,
                    reducerVersion: row["reducer_version"],
                    schemaVersion: row["schema_version"],
                    upToSequence: row["up_to_sequence"],
                    payload: row["payload"]
                )
            }
        }
    }

    func save(_ snapshot: Snapshot) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO snapshots
                        (conversation_id, reducer_version, schema_version, up_to_sequence, payload)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(conversation_id) DO UPDATE SET
                        reducer_version = excluded.reducer_version,
                        schema_version = excluded.schema_version,
                        up_to_sequence = excluded.up_to_sequence,
                        payload = excluded.payload
                    """,
                arguments: [
                    snapshot.conversationID.sqlText,
                    snapshot.reducerVersion,
                    snapshot.schemaVersion,
                    snapshot.upToSequence,
                    snapshot.payload,
                ]
            )
        }
    }

    // MARK: - Deleting

    func deleteConversation(_ conversation: ConversationID) async throws {
        try await writer.write { db in
            // One transaction across all three tables (§9). Cancel-first
            // sequencing is the `ConversationStore`'s job (§6.5), not the
            // backend's — by the time this runs there is nothing left to append
            // to, which is also why deletion is out-of-band rather than an event.
            for table in ["events", "snapshots"] {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE conversation_id = ?",
                    arguments: [conversation.sqlText]
                )
            }
            try db.execute(
                sql: "DELETE FROM conversations WHERE id = ?",
                arguments: [conversation.sqlText]
            )
        }
    }

    // MARK: - Index

    func conversationSummaries() async throws -> [ConversationSummary] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, created_at, title, last_event_at
                    FROM conversations ORDER BY last_event_at DESC
                    """
            )
            .compactMap { row in
                // A row whose dates will not parse is a corrupted *projection*,
                // and a projection is rebuildable by scanning the log — so
                // skipping it degrades the list rather than failing the read.
                // The events table is the truth; nothing is lost that a rebuild
                // cannot restore.
                guard
                    let id = UUID(uuidString: row["id"]),
                    let createdAt = WireDate.date(from: row["created_at"]),
                    let lastEventAt = WireDate.date(from: row["last_event_at"])
                else { return nil }
                return ConversationSummary(
                    id: ConversationID(id),
                    createdAt: createdAt,
                    title: row["title"],
                    lastEventAt: lastEventAt
                )
            }
        }
    }
}

// MARK: - Column forms

extension LedgerIdentifier {

    /// The identifier's column form: the bare UUID string.
    ///
    /// **Deliberately identical to ADR-002's wire form**, so the
    /// `conversation_id` column and the same field inside the blob are the same
    /// bytes. That is what makes §6.6 row 4's duplication an honest read-side
    /// check rather than one the writer forged agreement into — and it means a
    /// human reading either place sees the same string.
    ///
    /// Spelled out rather than conforming the identifiers to GRDB's
    /// `DatabaseValueConvertible`: that conformance would be visible to anyone
    /// importing both modules, which is precisely the leak ADR-003 rule 1
    /// forbids.
    var sqlText: String { uuid.uuidString }
}

// MARK: - Index policy

extension LedgerEvent.Payload {

    /// Whether appending this payload should touch the `conversations` index
    /// (§9).
    ///
    /// Everything except `deltaAppended`. Stated as an exhaustive switch rather
    /// than `if case .deltaAppended` so that a future payload kind cannot be
    /// added without someone deciding which side of this line it falls on — the
    /// same reason §6.6's rendering is exhaustive.
    var updatesIndex: Bool {
        switch self {
        case .deltaAppended:
            false
        case .conversationCreated, .userMessageAppended, .instructionsChanged,
             .generationStarted, .toolInvocationRecorded, .generationEnded,
             .messageEdited, .activePathChanged, .titleChanged:
            true
        }
    }
}

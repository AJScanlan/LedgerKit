import Foundation

/// The persistence seam (SPEC §9, ADR-003).
///
/// LedgerKit's storage needs are three tables and five verbs; the backend —
/// GRDB, per ADR-003 — sits behind this file so its types never leak into
/// public API and the choice stays swappable (raw sqlite3 remains the §12
/// cut-line fallback). Nothing here is wired until M4; this file is the
/// *decision*, recorded as code.
///
/// Two design rules, both consequences of "the log is the truth":
///
/// - **Bytes below, meaning above.** The backend stores and returns encoded
///   blobs plus the columns it needs for keys and the index. Encoding,
///   decoding, quarantine, and snapshot-version policy all live above this
///   seam — the same boundary ADR-001's lossy-decode rule draws for
///   transport.
/// - **The seam is internal.** Consumers pick a backend via
///   `PersistenceConfiguration` (§11: `ConversationStore(persistence:
///   .sqlite(url: dbURL))`); the protocol itself is `internal`, callable only
///   by the `ConversationStore` actor (M5) and test doubles.

/// How a `ConversationStore` persists its ledger (SPEC §11).
public enum PersistenceConfiguration: Sendable {
    /// A single SQLite database file — the production shape (§9).
    case sqlite(url: URL)
    /// Ephemeral, for tests and previews — the persistence counterpart of
    /// `ScriptedLanguageModel` (tenet 5). Maps to an in-memory
    /// `DatabaseQueue` at M4.
    case inMemory
}

/// One row of the `conversations` index projection (SPEC §9, G9): the
/// conversation list is a table read, not N reductions. Derived, rebuildable
/// by scanning the log; maintained on non-delta appends only, so
/// `lastEventAt` reads "last *meaningful* event" — which is what a list
/// sorts by anyway.
public struct ConversationSummary: Sendable, Identifiable, Equatable {
    public var id: ConversationID
    public var createdAt: Date
    public var title: String?
    public var lastEventAt: Date

    public init(id: ConversationID, createdAt: Date, title: String? = nil, lastEventAt: Date) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.lastEventAt = lastEventAt
    }
}

/// A persisted `FoldedState` checkpoint (SPEC §9), opaque to the backend.
///
/// `payload` is the encoded fold — including accumulated diagnostics (§9, or
/// P3 fails) — produced and consumed above the seam. The version fields ride
/// alongside so the store can discard-on-mismatch *without* decoding: no
/// migrations, ever; a stale snapshot just costs a longer replay.
struct Snapshot: Sendable, Equatable {
    var conversationID: ConversationID
    var reducerVersion: Int
    var schemaVersion: Int
    /// The last sequence folded into `payload`; replay resumes after it.
    var upToSequence: Int64
    var payload: Data
}

/// The five verbs LedgerKit needs from a storage backend. Implemented by the
/// GRDB store at M4; conformances must be `Sendable` because the
/// `ConversationStore` actor calls across its isolation boundary.
///
/// Deliberately *not* here: value observation of the index (an M4/M7 concern
/// — GRDB's `ValueObservation` will feed the projection's
/// `conversationList`, surfaced as an `AsyncSequence` when the projection
/// needs it), and any transaction-shaping API beyond what these verbs
/// promise — callers get atomicity guarantees, never transaction handles.
protocol PersistenceStore: Sendable {

    /// Appends `records` to `conversation`'s log in **one transaction**, and
    /// returns the assembled envelopes (SPEC §9).
    ///
    /// All-or-nothing across the whole batch, because the batch *is* the unit
    /// of meaning: `send` is `userMessageAppended` + `generationStarted`, an
    /// edit is `messageEdited` + `activePathChanged`, a flush is N
    /// `deltaAppended`s (§6.5, §7.4). No crash strands half an operation, and
    /// a throw means **nothing was recorded** — no rows, no consumed sequence
    /// numbers, no index update. That is what makes §11's two-channel rule
    /// literally rather than approximately true: `try` guards *did it start*,
    /// and a verb that failed to start left the log untouched.
    ///
    /// **The backend assigns `sequence`**, inside that same transaction —
    /// contiguous from 1 per conversation, in array order (§6.1). It can
    /// happen nowhere else: deciding "max + 1" outside the write lock is
    /// precisely how an append-only log grows duplicate keys. `Record` omits
    /// `sequence` for that reason, so the returned events — same count, same
    /// order, now carrying theirs — are the caller's only way to learn what
    /// was written. The M5 store actor needs exactly that: it folds the new
    /// tail into its in-memory state instead of re-reading (the
    /// `persisted ++ tail` shape P1 tests), and `last?.sequence` drives the
    /// every-500-events snapshot floor (§9).
    ///
    /// **The index rides along.** Non-delta appends also update the
    /// conversation's `conversations` row in the same transaction — seeded by
    /// `conversationCreated`, tracking `titleChanged`, stamping
    /// `lastEventAt`; delta flushes deliberately don't touch it, or a
    /// streaming generation churns the table at ~4 Hz for zero information
    /// (§9). The backend derives this from the payload kinds it was handed
    /// rather than taking a flag or splitting off an `appendDeltas` verb:
    /// §9 states the rule in terms of payload kind, so a caller-supplied
    /// answer could only ever *disagree* with the payloads — an illegal state
    /// this signature simply cannot represent (tenet 1).
    ///
    /// - Parameters:
    ///   - records: May be empty — a no-op returning `[]`. Every record's
    ///     `conversationID` must equal `conversation`; a mismatch is a
    ///     programming error and rejects the whole batch. The column is
    ///     written from the record, never from the parameter, so §6.6 row 4's
    ///     duplication stays an honest read-side check rather than one the
    ///     writer forged agreement into.
    ///   - conversation: The single stream whose sequence run and index row
    ///     this transaction touches.
    func append(
        _ records: [LedgerEvent.Record],
        to conversation: ConversationID
    ) async throws -> [LedgerEvent]

    /// All events for a conversation with `sequence >= from`, in sequence
    /// order, envelopes assembled from blob + key column (SPEC §9). `from: 1`
    /// is a full replay; the snapshot fast-path reads the suffix after
    /// `Snapshot.upToSequence`. Sequence gaps are returned as-is — the
    /// reducer, not the backend, diagnoses them (§6.1).
    func events(in conversation: ConversationID, from sequence: Int64) async throws -> [LedgerEvent]

    /// The most recent snapshot for the conversation, regardless of version —
    /// version-match policy lives above the seam. `nil` if none.
    func latestSnapshot(for conversation: ConversationID) async throws -> Snapshot?

    /// Replaces the conversation's snapshot. Best-effort by policy (§9):
    /// callers treat failure as a missed optimization, never an error worth
    /// surfacing — truth is the log.
    func save(_ snapshot: Snapshot) async throws

    /// Removes the conversation's events, snapshots, and index row in one
    /// transaction (SPEC §9). Irreversible; cancel-first sequencing is the
    /// `ConversationStore`'s job (§6.5), not the backend's.
    func deleteConversation(_ conversation: ConversationID) async throws

    /// The index projection, ordered by `lastEventAt` descending — one table
    /// read (G9).
    func conversationSummaries() async throws -> [ConversationSummary]
}

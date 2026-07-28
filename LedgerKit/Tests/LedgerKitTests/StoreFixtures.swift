import Foundation
import Synchronization
import Testing
@testable import LedgerKit

// Shared harness for the `ConversationStore` suites (M5). Internal rather than
// file-private for the same reason `ReducerFixtures.swift` is: Phases 1–4 all
// build stores the same way, and a second copy would be a second thing to drift.
//
// The organizing idea is that **a store under injection mints exactly what a
// hand-written `Log` contains** — same identifier scheme, same timestamp scheme
// — so a verb test can assert "these verbs produced this fixture" instead of
// "roughly this shape". That is D27's whole purpose, and it is what lets the
// store suites and the reducer suites keep talking about the same logs.

/// Identifiers matching `Log`'s own scheme, so a store's output can be compared
/// against a hand-written fixture (D27).
///
/// A *scripted* source rather than a seeded `IDGenerator`: seeding buys
/// reproducibility, which is not the same thing as legibility. These are the
/// identifiers already spelled in `Fix` — `Fix.conversation`, `Fix.userA`,
/// `Fix.genA` — so an expected `Log` can be written by hand and read by eye.
/// A seeded generator is exercised separately, where the claim is that the real
/// one plugs in at all.
///
/// Every counter is a *starting point* because a verb test usually seeds a
/// fixture first: the store must then continue that log's numbering rather than
/// restart it and collide with identifiers already in the tree.
/// ``StoreUnderTest/continuing(_:over:messagesFrom:generationsFrom:)`` does the
/// arithmetic.
struct ScriptedIdentifiers: IdentifierSource {
    /// Mirrors `Log`'s `nextEventNumber`: pre-incremented, so the first event is
    /// `uuid(0x101)`.
    private var events: Int
    /// One before `Fix.conversation` / `Fix.userA` / `Fix.genA` respectively.
    private var conversations: Int
    private var messages: Int
    private var generations: Int

    init(
        eventsFrom events: Int = 0x100,
        conversationsFrom conversations: Int = 0,
        messagesFrom messages: Int = 0x0F,
        generationsFrom generations: Int = 0x2F
    ) {
        self.events = events
        self.conversations = conversations
        self.messages = messages
        self.generations = generations
    }

    mutating func makeEventID() -> EventID {
        events += 1
        return EventID(uuid(events))
    }

    mutating func makeConversationID() -> ConversationID {
        conversations += 1
        return ConversationID(uuid(conversations))
    }

    mutating func makeMessageID() -> MessageID {
        messages += 1
        return MessageID(uuid(messages))
    }

    mutating func makeGenerationID() -> GenerationID {
        generations += 1
        return GenerationID(uuid(generations))
    }
}

/// A clock advancing one second per read, from `Log.base` — the scheme `Log`
/// stamps its fixtures with (`base + sequence`).
///
/// One read per minted record, so the *n*th event lands on `base + n` and a
/// store-written log is timestamp-identical to the hand-written fixture. Whole
/// seconds also mean every stamp is already canonical, so a *failure* of the
/// canonicalization test is unambiguously the store's rather than the clock's.
final class SteppingClock: Sendable {
    private let base: Date
    private let reads = Mutex(0)

    init(from base: Date = Log.base) {
        self.base = base
    }

    var now: @Sendable () -> Date {
        { [self] in base.addingTimeInterval(Double(reads.withLock { $0 += 1; return $0 })) }
    }
}

/// Wraps a store and keeps every record handed to `append` **as written** —
/// before any encoding.
///
/// Reading rows back is not a substitute, and the difference is not academic:
/// the wire formatter *rounds* fractional seconds, so a stamp that was never
/// canonicalized comes back from SQLite canonical anyway. A test that only reads
/// from disk is therefore structurally blind to ADR-001 R-5's failure — an event
/// meaning one thing in memory and another once it has been to disk. This double
/// is the only place the in-memory half is observable.
final class RecordingStore: PersistenceStore {
    private let wrapped: any PersistenceStore
    private let captured = Mutex<[[LedgerEvent.Record]]>([])
    private let reads = Mutex(0)

    init(_ wrapped: any PersistenceStore) {
        self.wrapped = wrapped
    }

    /// One element per **successful transaction**, so "these two events commit
    /// together" is assertable rather than assumed. That grouping is the whole
    /// content of §6.5's start atomicity and §6.4's one-transaction edit: an
    /// edit that wrote its two events in two batches would look identical in a
    /// flattened list and be a crash away from a stranded half-operation.
    var appends: [[LedgerEvent.Record]] { captured.withLock { $0 } }

    /// Records from appends that **succeeded**, in write order — so a test
    /// asserting "the log is untouched" is not misled by an attempt.
    var written: [LedgerEvent.Record] { appends.flatMap { $0 } }

    /// Rows the *reducer* was handed, which is what the cold-open criterion is
    /// about: a separate `events(…)` call would only prove that *a* suffix read
    /// is cheap, not that the resume path's own read is.
    var rowsRead: Int { reads.withLock { $0 } }

    func append(_ records: [LedgerEvent.Record], to conversation: ConversationID) async throws -> [LedgerEvent] {
        let tail = try await wrapped.append(records, to: conversation)
        captured.withLock { $0.append(records) }
        return tail
    }

    func events(in conversation: ConversationID, from sequence: Int64) async throws -> [LoadedEvent] {
        let loaded = try await wrapped.events(in: conversation, from: sequence)
        reads.withLock { $0 += loaded.count }
        return loaded
    }

    func latestSnapshot(for conversation: ConversationID) async throws -> Snapshot? {
        try await wrapped.latestSnapshot(for: conversation)
    }

    func save(_ snapshot: Snapshot) async throws {
        try await wrapped.save(snapshot)
    }

    func deleteConversation(_ conversation: ConversationID) async throws {
        try await wrapped.deleteConversation(conversation)
    }

    func conversationSummaries() async throws -> [ConversationSummary] {
        try await wrapped.conversationSummaries()
    }
}

/// A store and the backing persistence it writes to, so a test can check both
/// what was written and what reached disk.
struct StoreUnderTest {
    let backing: any PersistenceStore
    let store: ConversationStore
    private let recorder: RecordingStore
    /// Retained so its closure stays alive for the store's lifetime.
    private let clock: SteppingClock

    /// Records the store has written, as handed to `append`.
    var written: [LedgerEvent.Record] { recorder.written }
    /// One element per transaction — see ``RecordingStore/appends``.
    var appends: [[LedgerEvent.Record]] { recorder.appends }
    /// Rows handed to the reducer — the cold-open criterion's measure.
    var rowsRead: Int { recorder.rowsRead }

    init(
        over backing: (any PersistenceStore)? = nil,
        identifiers: ScriptedIdentifiers = ScriptedIdentifiers(),
        clockFrom base: Date = Log.base,
        deltaFlush: DeltaFlushPolicy = .default
    ) throws {
        let recorder = RecordingStore(try backing ?? SQLitePersistenceStore(.inMemory))
        let clock = SteppingClock(from: base)
        self.recorder = recorder
        self.backing = recorder
        self.clock = clock
        self.store = ConversationStore(
            persistence: recorder,
            deltaFlush: deltaFlush,
            identifiers: identifiers,
            now: clock.now
        )
    }

    /// A store over a database already holding `seed`, with the identifier and
    /// clock streams **advanced past it**.
    ///
    /// This is the ordinary shape for a tree or generation verb test: the verbs
    /// that *create* a user message arrive at Phase 3, so anything testing
    /// `edit` or `switchBranch` has to start from a log somebody else wrote. By
    /// continuing the fixture's own numbering — event IDs, message IDs, one
    /// second per event from `Log.base` — the store's output stays comparable to
    /// a hand-written `Log`, and can be compared against a *corpus* fixture
    /// outright.
    ///
    /// `messagesFrom` / `generationsFrom` are explicit because only the caller
    /// knows which identifiers its seed already used: the defaults would have
    /// the store re-mint `Fix.userA` and quarantine under §6.6 row 6.
    static func continuing(
        _ seed: Log,
        over backing: (any PersistenceStore)? = nil,
        messagesFrom messages: Int = 0x0F,
        generationsFrom generations: Int = 0x2F,
        deltaFlush: DeltaFlushPolicy = .default
    ) async throws -> Self {
        let base = try backing ?? SQLitePersistenceStore(.inMemory)
        _ = try await base.append(seed.records, to: seed.conversation)
        return try Self(
            over: base,
            identifiers: ScriptedIdentifiers(
                eventsFrom: 0x100 + Int(seed.lastSequence),
                messagesFrom: messages,
                generationsFrom: generations
            ),
            clockFrom: Log.base.addingTimeInterval(Double(seed.lastSequence)),
            deltaFlush: deltaFlush
        )
    }

    /// A second store over the same database, with an empty cache — the "cold
    /// reopen" half of fold-forward ≡ re-read.
    func reopened() -> ConversationStore {
        ConversationStore(
            persistence: backing,
            identifiers: ScriptedIdentifiers(),
            now: SteppingClock().now
        )
    }

    /// Every row the store has written to this conversation.
    func rows(of conversation: ConversationID) async throws -> [LoadedEvent] {
        try await backing.events(in: conversation, from: 1)
    }
}

// MARK: - The healthy-log property

/// **The M5 standing property** (M5-PLAN §1): a log produced by store verbs
/// re-reduces from disk with **empty `diagnostics`**, and the store's own view of
/// it agrees with that re-reduction.
///
/// Two claims, deliberately together. The first is that the store can never
/// write an event the reducer would quarantine — once apps read `diagnostics` as
/// a corruption signal, a store that manufactures its own residue makes the
/// signal meaningless. The second is P1's discipline applied to the actor: it
/// folds its own appends forward instead of re-reading, which is only sound if
/// the two agree, and a divergence here is the worst available shape because
/// both halves look right alone.
///
/// Returns problems rather than recording issues so callers can attach their own
/// context — the `InvariantChecks.swift` idiom, and it matters more here, where
/// the sweeps of Phases 3–4 will run this over many verb sequences.
func healthyLogProblems(
    _ conversation: ConversationID,
    in store: ConversationStore,
    backedBy backing: any PersistenceStore
) async throws -> [String] {
    var problems: [String] = []

    let rows = try await backing.events(in: conversation, from: 1)
    let reread = fold(rows, for: conversation)

    if !reread.diagnostics.isEmpty {
        problems.append("store-written log quarantined: \(reread.reasons)")
    }

    let observed = try await store.conversation(conversation)
    let expected = classify(reread, mapping: .default)
    if observed != expected {
        problems.append("cached state disagrees with a re-read of the log")
    }

    return problems
}

// MARK: - Deterministic reentrancy

/// A one-shot rendezvous between a test and something suspended inside the
/// actor.
///
/// The concurrency version of the project's "exhaustive, not randomized" rule
/// (§10.6): a test that only *released* the subject would still have to guess
/// when it got there, which is a sleep, which is a flake. Both sides wait, so
/// whatever the test does next happens at a point it chose.
///
/// Deliberately **not** `Understudy.Cue`, which is the same idea one layer up:
/// `Cue.park()` is internal to that package — its script player is the only
/// thing meant to park on one — so neither a `PersistenceStore` double nor a
/// `GenerationDriving` double can use it. At M6 the arrangement inverts and
/// `Cue` is used as designed.
actor Latch {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, any Error>] = []

    /// Test side: suspends until the subject parks. Returns immediately if it
    /// already has.
    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    /// Test side: lets the subject go. Idempotent, and safe before arrival.
    func release() {
        guard !released else { return }
        released = true
        let waiting = releaseWaiters
        releaseWaiters = []
        for continuation in waiting { continuation.resume() }
    }

    /// Subject side: announce arrival, then park until released.
    ///
    /// **Throws `CancellationError` if cancelled while parked**, without which
    /// cancelling a driver stopped at a latch would deadlock the very chaos
    /// tests this type exists for — the store would wait forever for a
    /// generation that was told to stop. `Cue` carries the same path for the
    /// same reason.
    func park() async throws {
        arrived = true
        let arrivals = arrivalWaiters
        arrivalWaiters = []
        for continuation in arrivals { continuation.resume() }

        if released { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checked inside the actor, because cancellation can land
                // between the handler being installed and the continuation
                // being stored — the classic hole in this pattern.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.failWaiters() }
        }
    }

    private func failWaiters() {
        let waiting = releaseWaiters
        releaseWaiters = []
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
    }
}

/// Wraps a store and parks the **first** call to one chosen verb, so a test can
/// interleave two entries into the actor at a point it picked.
///
/// Parks *after* delegating, which is the whole trick: the parked caller is left
/// holding a result computed before whatever the test does next, which is
/// exactly the stale-value hazard an `await` inside an actor creates.
final class ParkingStore: PersistenceStore {

    enum Verb: Sendable {
        case events
        case append
    }

    private let wrapped: any PersistenceStore
    private let verb: Verb
    private let latch: Latch
    private let parked = Mutex(false)

    init(_ wrapped: any PersistenceStore, parkingFirst verb: Verb, at latch: Latch) {
        self.wrapped = wrapped
        self.verb = verb
        self.latch = latch
    }

    func append(_ records: [LedgerEvent.Record], to conversation: ConversationID) async throws -> [LedgerEvent] {
        let tail = try await wrapped.append(records, to: conversation)
        if verb == .append { await parkIfFirst() }
        return tail
    }

    func events(in conversation: ConversationID, from sequence: Int64) async throws -> [LoadedEvent] {
        let loaded = try await wrapped.events(in: conversation, from: sequence)
        if verb == .events { await parkIfFirst() }
        return loaded
    }

    func latestSnapshot(for conversation: ConversationID) async throws -> Snapshot? {
        try await wrapped.latestSnapshot(for: conversation)
    }

    func save(_ snapshot: Snapshot) async throws {
        try await wrapped.save(snapshot)
    }

    func deleteConversation(_ conversation: ConversationID) async throws {
        try await wrapped.deleteConversation(conversation)
    }

    func conversationSummaries() async throws -> [ConversationSummary] {
        try await wrapped.conversationSummaries()
    }

    private func parkIfFirst() async {
        let isFirst = parked.withLock { alreadyParked -> Bool in
            if alreadyParked { return false }
            alreadyParked = true
            return true
        }
        // A cancelled park just proceeds: this double exists to *interleave*
        // actor entries, not to model a cancellable operation, and swallowing
        // here keeps the persistence call itself faithful to the real one.
        if isFirst { try? await latch.park() }
    }
}

// MARK: - The driver double

/// A `GenerationDriving` conformance that plays a fixed script (M5-PLAN Phase 3).
///
/// **Store-level, not model-level, and that is the whole point of the seam.**
/// `Understudy.ScriptedLanguageModel` sits on the far side of a `GenerationDriver`
/// that does not exist until M6, and cannot execute on a macOS 26 machine at all.
/// This double conforms to the D21 protocol directly, so every store behaviour —
/// single-flight, start atomicity, the flush loop, cancellation — is testable
/// today with no Foundation Models anywhere.
///
/// Parking uses ``Latch`` rather than `Understudy.Cue`: `Cue.park()` is internal
/// to that package, since its script *player* is the only thing meant to park on
/// one. At M6 the arrangement inverts — the player parks, and the test uses
/// `Cue`'s public `reached()` / `signal()`, which is exactly what it was designed
/// for.
final class ScriptedDriver: GenerationDriving {

    enum Step: Sendable {
        case delta(String)
        case toolRecord(ToolRecord)
        /// Parks the generation mid-flight until the test releases it — a point
        /// the test *chose*, rather than a sleep it hoped for (D26).
        case pause(Latch)
    }

    let model: ModelDescriptor
    private let script: [Step]
    private let ending: Outcome
    private let requests = Mutex<[GenerationRequest]>([])

    init(
        _ script: [Step] = [],
        ending: Outcome = .completed(Fix.stopInfo),
        model: ModelDescriptor = Fix.model
    ) {
        self.script = script
        self.ending = ending
        self.model = model
    }

    /// One delta and a completion — the ordinary turn.
    convenience init(saying text: String, model: ModelDescriptor = Fix.model) {
        self.init([.delta(text)], model: model)
    }

    /// The rehydration material the store handed over, per call (§7.1).
    var received: [GenerationRequest] { requests.withLock { $0 } }

    func generate(_ request: GenerationRequest, streamingInto channel: GenerationChannel) async -> Outcome {
        requests.withLock { $0.append(request) }
        for step in script {
            // A well-behaved driver notices between steps, not only while
            // suspended (§7.5): winding down and returning `.cancelled` is its
            // whole obligation.
                if Task.isCancelled { return .cancelled }
            switch step {
            case .delta(let text): channel.emit(.delta(text))
            case .toolRecord(let record): channel.emit(.toolRecord(record))
            case .pause(let latch):
                // A cancelled park throws, which is how a stop reaches a driver
                // suspended mid-stream (§7.5). Winding down and returning
                // `.cancelled` is the driver's whole obligation.
                do { try await latch.park() } catch { return .cancelled }
            }
        }
        return ending
    }
}

/// Passes everything through until `tolerating` appends have succeeded, then
/// fails every subsequent one.
///
/// Reads keep working throughout, which is what makes it usable for the start
/// atomicity tests: the conversation must be loadable for a verb to get as far
/// as reserving its slot and *then* fail to append (D24).
final class FlakyStore: PersistenceStore {
    private let wrapped: any PersistenceStore
    private let remaining: Mutex<Int>

    init(_ wrapped: any PersistenceStore, tolerating appends: Int = 0) {
        self.wrapped = wrapped
        self.remaining = Mutex(appends)
    }

    func append(_ records: [LedgerEvent.Record], to conversation: ConversationID) async throws -> [LedgerEvent] {
        let allowed = remaining.withLock { left -> Bool in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
        guard allowed else { throw FailingStore.Failure() }
        return try await wrapped.append(records, to: conversation)
    }

    func events(in conversation: ConversationID, from sequence: Int64) async throws -> [LoadedEvent] {
        try await wrapped.events(in: conversation, from: sequence)
    }

    func latestSnapshot(for conversation: ConversationID) async throws -> Snapshot? {
        try await wrapped.latestSnapshot(for: conversation)
    }

    func save(_ snapshot: Snapshot) async throws {
        try await wrapped.save(snapshot)
    }

    func deleteConversation(_ conversation: ConversationID) async throws {
        try await wrapped.deleteConversation(conversation)
    }

    func conversationSummaries() async throws -> [ConversationSummary] {
        try await wrapped.conversationSummaries()
    }
}

/// Everything works except `save` — §9's "best-effort" refresh, put under the
/// only pressure that distinguishes it from a mandatory one.
final class SnapshotHostileStore: PersistenceStore {
    private let wrapped: any PersistenceStore

    init(_ wrapped: any PersistenceStore) {
        self.wrapped = wrapped
    }

    func append(_ records: [LedgerEvent.Record], to conversation: ConversationID) async throws -> [LedgerEvent] {
        try await wrapped.append(records, to: conversation)
    }

    func events(in conversation: ConversationID, from sequence: Int64) async throws -> [LoadedEvent] {
        try await wrapped.events(in: conversation, from: sequence)
    }

    func latestSnapshot(for conversation: ConversationID) async throws -> Snapshot? {
        try await wrapped.latestSnapshot(for: conversation)
    }

    func save(_ snapshot: Snapshot) async throws {
        throw FailingStore.Failure(reason: "no checkpoints today")
    }

    func deleteConversation(_ conversation: ConversationID) async throws {
        try await wrapped.deleteConversation(conversation)
    }

    func conversationSummaries() async throws -> [ConversationSummary] {
        try await wrapped.conversationSummaries()
    }
}

/// A store whose every verb fails — the two-channel contract's other half, where
/// the interesting assertion is that the log is untouched afterward.
final class FailingStore: PersistenceStore {

    struct Failure: Error, Equatable {
        var reason = "the disk is on fire"
    }

    func append(_ records: [LedgerEvent.Record], to conversation: ConversationID) async throws -> [LedgerEvent] {
        throw Failure()
    }

    func events(in conversation: ConversationID, from sequence: Int64) async throws -> [LoadedEvent] {
        throw Failure()
    }

    func latestSnapshot(for conversation: ConversationID) async throws -> Snapshot? {
        throw Failure()
    }

    func save(_ snapshot: Snapshot) async throws {
        throw Failure()
    }

    func deleteConversation(_ conversation: ConversationID) async throws {
        throw Failure()
    }

    func conversationSummaries() async throws -> [ConversationSummary] {
        throw Failure()
    }
}

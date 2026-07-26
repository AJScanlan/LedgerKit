import Foundation
import Synchronization
import Testing
@testable import LedgerKit

// M4 Phase 3: the §9 snapshot fast-path, and P3 — `resume(snapshot(prefix),
// suffix) == fold(fullLog)`, diagnostics included.
//
// M3 already swept P3 at every split of every fixture, but entirely in memory:
// the checkpoint was a live `FoldedState` handed straight back to
// `fold(resuming:)`. These suites add the two things that make it a *persistence*
// property — the **codec** (encode → decode) and the **store** (SQLite, plus the
// version policy that decides whether a checkpoint may be used at all).

@Suite("Snapshots — P3 through the codec")
struct SnapshotCodecTests {

    @Test("resume equals replay at every split, across the encode/decode boundary")
    func resumeEqualsReplayThroughTheCodec() throws {
        // Every fixture, not just the store-replayable ones: no `append` is
        // involved, so gaps and byte-built rows are fine here. That matters —
        // `rich` and `hostile` are the only fixtures with **diagnostics**, and
        // diagnostics surviving the codec is the specific thing §9 requires and P3
        // exists to enforce. Drop them from the snapshot payload and this fails on
        // any log with residue before the split point.
        var splits = 0
        var withResidue = 0

        for fixture in Corpus.all {
            let log = fixture.log
            let whole = log.folded()

            for split in 0...log.rows.count {
                let prefix = Array(log.rows.prefix(split))
                let checkpoint = fold(prefix, for: log.conversation)
                // The sequence of the last row folded — *not* the row count. A
                // gapped log's fifth row is not at sequence 5, and getting this
                // wrong is how a gap straddling the boundary silently closes.
                let after = prefix.last?.sequence ?? 0

                let snapshot = try Snapshot(encoding: checkpoint, upTo: max(after, 1))
                let restored = try #require(
                    snapshot.foldedState,
                    "\(fixture.name) split \(split): a checkpoint this build wrote must be usable"
                )
                #expect(restored == checkpoint, "\(fixture.name) split \(split) lost state in the codec")

                let resumed = fold(
                    resuming: restored,
                    after: after,
                    with: Array(log.rows.dropFirst(split))
                )
                #expect(resumed == whole, "\(fixture.name): resuming at split \(split) diverged from replay")

                if !checkpoint.diagnostics.isEmpty { withResidue += 1 }
                splits += 1
            }
        }

        // Non-vacuity, both dimensions: the sweep ran, and it reached checkpoints
        // that actually carried residue — without which the diagnostics claim
        // above would be untested and this suite would pass on a snapshot format
        // that dropped them.
        #expect(splits >= 80, "only \(splits) splits swept")
        #expect(withResidue >= 10, "only \(withResidue) checkpoints carried diagnostics")
    }

    @Test("an empty checkpoint is still a checkpoint")
    func emptyStateRoundTrips() throws {
        // The degenerate case, worth pinning because `hasGenesis` is the field a
        // "just encode the messages" implementation would drop — and a genesis-less
        // log resumed without it starts accepting events a replay quarantines
        // (`FoldedState.hasGenesis`).
        let state = FoldedState.empty(Fix.conversation)
        let restored = try #require(Snapshot(encoding: state, upTo: 1).foldedState)
        #expect(restored == state)
        #expect(restored.hasGenesis == false)
    }
}

@Suite("Snapshots — the discard policy")
struct SnapshotDiscardTests {

    private func snapshot(
        of state: FoldedState = Log.withCompletedTurn().folded(),
        upTo sequence: Int64 = 5
    ) throws -> Snapshot {
        try Snapshot(encoding: state, upTo: sequence)
    }

    @Test("a checkpoint this build wrote is usable")
    func currentIsUsable() throws {
        // The control. Without it, every test below could pass because *nothing*
        // is ever usable, which is a very quiet way to disable the fast path.
        #expect(try snapshot().foldedState != nil)
    }

    @Test("a reducer-version mismatch discards")
    func reducerVersionMismatch() throws {
        var stale = try snapshot()
        stale.reducerVersion = LedgerSchema.reducerVersion + 1
        // The designed case: a changed fold makes a checkpoint a cache of
        // something that no longer exists. Discard costs one replay; using it
        // would cost correctness, silently.
        #expect(stale.foldedState == nil)
    }

    @Test("a payload-schema mismatch discards")
    func schemaVersionMismatch() throws {
        var stale = try snapshot()
        stale.schemaVersion = LedgerSchema.payloadVersion + 1
        #expect(stale.foldedState == nil)
    }

    @Test("a truncated payload discards rather than throwing")
    func truncatedPayloadDiscards() throws {
        var damaged = try snapshot()
        damaged.payload = damaged.payload.prefix(damaged.payload.count / 2)
        // Bit rot takes the same branch as a version bump, and must not be fatal:
        // the log is the truth, so the worst a damaged cache may cost is the
        // replay it was avoiding.
        #expect(damaged.foldedState == nil)
    }

    @Test("a payload naming another conversation discards")
    func foreignPayloadDiscards() throws {
        var foreign = try snapshot(of: Log(Fix.foreign).folded())
        foreign.conversationID = Fix.conversation
        // The snapshot analogue of §6.6 row 4: the key and the contents disagree
        // about which stream this is, which is corrupt by the same argument that
        // makes cross-stream contamination malformed.
        #expect(foreign.foldedState == nil)
    }

    @Test("a checkpoint claiming to precede genesis discards")
    func impossibleSequenceDiscards() throws {
        // `upToSequence` 0 would make the resume read from sequence 1 — i.e. the
        // whole log — while *also* seeding it with a non-empty state, folding
        // every event twice. Deltas are the one non-idempotent payload kind (§6.6
        // ordering), so that silently doubles a message's text rather than
        // failing.
        #expect(try snapshot(upTo: 0).foldedState == nil)
    }
}

@Suite("Snapshots — P3 through the real store")
struct SnapshotStoreTests {

    @Test("resume equals replay at every split, through SQLite")
    func resumeEqualsReplayThroughTheStore() async throws {
        var splits = 0

        for fixture in Corpus.all where fixture.log.isStoreReplayable {
            let log = fixture.log
            let whole = log.folded()
            let store = try SQLitePersistenceStore(.inMemory)
            _ = try await store.append(log.records, to: log.conversation)

            // Split 0 runs first, while no checkpoint exists — that is the pure
            // replay path, and `save` replaces, so it cannot be reached again once
            // a snapshot has been written.
            for split in 0...log.rows.count {
                if split > 0 {
                    let prefix = Array(log.rows.prefix(split))
                    try await store.saveSnapshot(
                        of: fold(prefix, for: log.conversation),
                        upTo: prefix.last?.sequence ?? 1
                    )
                }
                #expect(
                    try await store.foldedState(of: log.conversation) == whole,
                    "\(fixture.name): resuming at split \(split) diverged from replay"
                )
                splits += 1
            }
        }

        #expect(splits >= 40, "only \(splits) splits swept through the store")
    }

    @Test("an unusable checkpoint falls back to replay rather than failing")
    func unusableCheckpointFallsBack() async throws {
        let log = Log.withCompletedTurn()
        let store = try SQLitePersistenceStore(.inMemory)
        _ = try await store.append(log.records, to: log.conversation)

        // A checkpoint from a future reducer — the shape an app meets after an
        // upgrade, on every conversation it has.
        var stale = try Snapshot(encoding: log.folded(), upTo: log.lastSequence)
        stale.reducerVersion = LedgerSchema.reducerVersion + 1
        try await store.save(stale)

        // Degraded, alive, and *correct*: the conversation loads by replaying.
        #expect(try await store.foldedState(of: log.conversation) == log.folded())
    }

    @Test("a conversation with no checkpoint loads by replay")
    func noCheckpointReplays() async throws {
        let log = Log.withCompletedTurn()
        let store = try SQLitePersistenceStore(.inMemory)
        _ = try await store.append(log.records, to: log.conversation)

        #expect(try await store.latestSnapshot(for: log.conversation) == nil)
        #expect(try await store.foldedState(of: log.conversation) == log.folded())
    }
}

@Suite("Snapshots — cold open")
struct ColdOpenTests {

    /// Wraps a store and counts the event rows actually handed to the reducer.
    ///
    /// A separate `events(…)` call would only prove that *a* suffix read is cheap.
    /// This proves the **resume path's own** read is, which is what the roadmap's
    /// exit criterion claims — the difference between measuring the thing and
    /// measuring something adjacent to it.
    private final class CountingStore: PersistenceStore {
        let wrapped: SQLitePersistenceStore
        private let rows = Mutex(0)

        init(_ wrapped: SQLitePersistenceStore) { self.wrapped = wrapped }

        var rowsRead: Int { rows.withLock { $0 } }

        func append(_ records: [LedgerEvent.Record], to conversation: ConversationID) async throws -> [LedgerEvent] {
            try await wrapped.append(records, to: conversation)
        }

        func events(in conversation: ConversationID, from sequence: Int64) async throws -> [LoadedEvent] {
            let loaded = try await wrapped.events(in: conversation, from: sequence)
            rows.withLock { $0 += loaded.count }
            return loaded
        }

        func latestSnapshot(for conversation: ConversationID) async throws -> Snapshot? {
            try await wrapped.latestSnapshot(for: conversation)
        }

        func save(_ snapshot: Snapshot) async throws { try await wrapped.save(snapshot) }
        func deleteConversation(_ conversation: ConversationID) async throws {
            try await wrapped.deleteConversation(conversation)
        }
        func conversationSummaries() async throws -> [ConversationSummary] {
            try await wrapped.conversationSummaries()
        }
    }

    /// A conversation of `generations` complete turns, ten events each.
    ///
    /// Identifier ranges are far above `Log`'s own event-ID counter so a dump of
    /// this log stays unambiguous by eye.
    /// The endpoint of a `longConversation(generations:deltas:)` — the assistant
    /// message the next turn hangs from.
    private func lastAssistant(of generations: Int) -> MessageID {
        MessageID(uuid(0x200_000 + generations - 1))
    }

    private func longConversation(generations: Int, deltas: Int) -> Log {
        var log = Log.opened(title: "a long conversation")
        var parent: MessageID?
        for turn in 0..<generations {
            let user = MessageID(uuid(0x100_000 + turn))
            let assistant = MessageID(uuid(0x200_000 + turn))
            let generation = GenerationID(uuid(0x300_000 + turn))
            log.append(.userMessageAppended(user, content: "q\(turn)", parent: parent))
            log.append(.generationStarted(generation, assistant, parent: user, model: Fix.model))
            for _ in 0..<deltas {
                log.append(.deltaAppended(generation, text: "tok "))
            }
            log.append(.generationEnded(generation, .completed(Fix.stopInfo)))
            parent = assistant
        }
        return log
    }

    @Test("a 10k-event conversation cold-opens by replaying one generation's suffix")
    func coldOpenReplaysOnlyTheSuffix() async throws {
        // §9's refresh policy checkpoints after each `generationEnded`, so the
        // newest checkpoint sits at the last terminal and the only thing left to
        // replay is whatever the process was doing when it died. That is the
        // scenario, built literally.
        let turns = 1_000
        let history = longConversation(generations: turns, deltas: 7)
        let lastAssistant = lastAssistant(of: turns)
        #expect(history.records.count >= 10_000, "the point is a *large* log")

        let store = try SQLitePersistenceStore(.inMemory)
        let counting = CountingStore(store)
        _ = try await counting.append(history.records, to: history.conversation)
        try await counting.saveSnapshot(of: history.folded(), upTo: history.lastSequence)

        // Then the app was killed mid-generation: a user message, a start, one
        // delta, and no terminal. Parented to the last assistant so it is a
        // legitimate continuation of the thread — a bare `nil` parent would
        // quarantine under I6 and cascade, and the test would be measuring three
        // diagnostics instead of the recovery shape it claims to measure.
        var tail = history
        let user = MessageID(uuid(0x400_001))
        let assistant = MessageID(uuid(0x400_002))
        let generation = GenerationID(uuid(0x400_003))
        tail.append(.userMessageAppended(user, content: "one more", parent: lastAssistant))
        tail.append(.generationStarted(generation, assistant, parent: user, model: Fix.model))
        tail.append(.deltaAppended(generation, text: "half an ans"))
        let unterminated = Array(tail.records.dropFirst(history.records.count))
        _ = try await counting.append(unterminated, to: tail.conversation)

        let started = ContinuousClock.now
        let resumed = try await counting.foldedState(of: tail.conversation)
        let elapsed = ContinuousClock.now - started

        // Correctness first: cheapness that changed the answer would be worthless.
        #expect(resumed == tail.folded())
        // And it is the *recovery* shape, not merely an equal one — this is DoD-1's
        // mechanism reached through a snapshot resume: the interrupted generation
        // is `.open` with its partial intact, which `classify` turns into
        // `.interrupted` (I5). Reconstructing the generation→message routing map
        // from the checkpoint is the part that could silently fail here, and it
        // would show up as this delta quarantining under row 9 instead.
        #expect(resumed.messages[assistant]?.state == .open(partial: "half an ans"))
        #expect(resumed.diagnostics.isEmpty)
        // The exit criterion, as a *row count* — deterministic, unlike wall time.
        #expect(counting.rowsRead == unterminated.count)
        #expect(counting.rowsRead <= 10, "replayed \(counting.rowsRead) rows — more than one generation's worth")
        // Recorded, never asserted: wall time is the machine's opinion, and a
        // timing assertion is a flake waiting for a busy CI box.
        print("cold open: \(history.records.count + unterminated.count) events, \(counting.rowsRead) rows replayed, \(elapsed)")
    }

    @Test("without a checkpoint the same conversation replays in full")
    func withoutCheckpointTheWholeLogIsRead() async throws {
        // The other half of the comparison, and what makes the number above mean
        // something: the saving is real, not an artifact of a short log. Smaller
        // than 10k on purpose — proving "reads everything" needs no particular
        // size, and appending is what costs time here, not resuming.
        let history = longConversation(generations: 100, deltas: 7)
        let counting = CountingStore(try SQLitePersistenceStore(.inMemory))
        _ = try await counting.append(history.records, to: history.conversation)

        _ = try await counting.foldedState(of: history.conversation)

        #expect(counting.rowsRead == history.records.count)
    }
}

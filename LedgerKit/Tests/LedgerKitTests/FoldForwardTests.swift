import Foundation
import Testing
@testable import LedgerKit

// M4 Phase 4: **P1 — fold/tail equivalence** (SPEC §10.6).
//
//   reduce(persisted ++ unflushedTail, mapping) == reduce(logAfterFlush, mapping)
//
// This is the property the M5 store actor will live by. `append` returns the
// assembled tail (§9) precisely so the actor can fold *that* onto the state it
// already holds instead of re-reading the log after every flush — the
// `persisted ++ tail` shape. P1 is what makes the shortcut legal, and it is green
// before M5 starts rather than after.
//
// **Why it is not the same test as P3**, even though both split a log: P3 puts a
// *checkpoint* through a boundary (the codec, the snapshots table) and resumes.
// P1 puts the **tail** through the boundary — or rather, does not: its whole
// question is whether the in-memory values `append` handed back are
// interchangeable with the bytes a re-read decodes. Only a real store can answer
// that, because in memory the two are the same array.
//
// So the failure modes here are the store's, not the reducer's: a sequence
// assigned wrongly in a *second* transaction, a timestamp that does not survive
// its own encoding (ADR-001 R-5 — the reason canonicalization happens at birth),
// an encoder that loses a field in one direction only. Every one of those would
// leave the M5 actor's in-memory state quietly disagreeing with its own database.
//
// Splits are exhaustive per D18 — no seeds, no flake, fixtures are ≤ 22 rows.

@Suite("P1 — fold/tail equivalence through the store")
struct FoldForwardTests {

    /// Every fixture the store can replay, at every flush boundary.
    ///
    /// Scoped by `Log.isStoreReplayable` rather than by a list of names, for the
    /// three structural reasons that accessor documents: `append` cannot reproduce
    /// a sequence gap, cannot express a row whose bytes do not decode, and rejects
    /// a foreign event outright. A fixture excluded here is excluded because the
    /// *write* path cannot express it, not because P1 is weaker than claimed.
    @Test("folding the appended tail forward equals re-reading the log")
    func foldForwardEqualsReread() async throws {
        var splits = 0

        for fixture in Corpus.all where fixture.log.isStoreReplayable {
            let log = fixture.log
            let whole = log.folded()

            for split in 0...log.records.count {
                // A fresh store per split: `append` accumulates, so reusing one
                // would make every later split a longer log rather than a
                // different flush point.
                let store = try SQLitePersistenceStore(.inMemory)
                let context = "\(fixture.name) flushed at \(split)"

                // What was already on disk when this process started, and the
                // state the actor holds having loaded it.
                let persisted = try await store.append(Array(log.records.prefix(split)), to: log.conversation)
                let persistedRows = try await store.events(in: log.conversation, from: 1)
                let checkpoint = fold(persistedRows, for: log.conversation)

                // The flush.
                let tail = try await store.append(Array(log.records.dropFirst(split)), to: log.conversation)

                // P1's left side: the actor's shortcut — fold the values `append`
                // returned onto the state it already had. `after:` is the last
                // sequence already folded, exactly as on the snapshot resume path;
                // passing the row *count* would be a different number the moment a
                // log has a gap.
                let foldedForward = fold(
                    resuming: checkpoint,
                    after: persistedRows.last?.sequence ?? 0,
                    with: tail.map(LoadedEvent.decoded)
                )

                // P1's right side: what the log says after the flush.
                let reread = try await store.events(in: log.conversation, from: 1)
                let replayed = fold(reread, for: log.conversation)

                #expect(foldedForward == replayed, "\(context): fold-forward diverged from replay")
                // And both agree with the in-memory fixture, which is what ties
                // this layer to the reducer suites: the store cannot be
                // self-consistently wrong.
                #expect(replayed == whole, "\(context): the store's own replay diverged from the fixture")

                // The sub-property the shortcut rests on, asserted per split
                // rather than once per fixture: what the appends *returned* is
                // exactly what a read returns. Value identity, so it also covers
                // timestamps surviving encode → decode (R-5).
                #expect(
                    (persisted + tail).map(LoadedEvent.decoded) == reread,
                    "\(context): append's return value is not what the log reads back"
                )

                splits += 1
            }
        }

        // Non-vacuity: `isStoreReplayable` narrowing to nothing would leave this
        // suite passing while testing no log at all.
        #expect(splits >= 40, "only \(splits) flush boundaries swept")
    }

    @Test("the classified reduction agrees too, at every flush boundary")
    func classifiedFoldForwardEqualsReread() async throws {
        // §10.6 states P1 over `reduce`, not `fold`, and the difference is not
        // cosmetic: `classify` is where `.open ⇒ .interrupted` happens (I5). A
        // tail folded forward across a flush that landed mid-generation must
        // finalize the same way as a full replay — otherwise the M5 actor's
        // shortcut could turn a live generation into a phantom crash.
        var interruptedSeen = 0

        for fixture in Corpus.all where fixture.log.isStoreReplayable {
            let log = fixture.log

            for split in 0...log.records.count {
                let store = try SQLitePersistenceStore(.inMemory)
                let context = "\(fixture.name) flushed at \(split)"

                let persisted = try await store.append(Array(log.records.prefix(split)), to: log.conversation)
                let checkpoint = fold(persisted.map(LoadedEvent.decoded), for: log.conversation)
                let tail = try await store.append(Array(log.records.dropFirst(split)), to: log.conversation)

                let foldedForward = fold(
                    resuming: checkpoint,
                    after: persisted.last?.sequence ?? 0,
                    with: tail.map(LoadedEvent.decoded)
                )
                let reread = try await store.events(in: log.conversation, from: 1)

                let shortcut = classify(foldedForward, mapping: .default)
                let replayed = Conversation(reducing: reread, loadedFrom: log.conversation)
                #expect(shortcut == replayed, "\(context): classification diverged")

                // The structural predicates too — a state that compares equal to
                // an equally broken one would still pass the line above.
                let problems = invariantProblems(in: shortcut, foldedFrom: foldedForward)
                #expect(problems.isEmpty, "\(context): \(problems)")

                for id in foldedForward.messages.keys.sorted(by: { "\($0)" < "\($1)" }) {
                    if case .interrupted = shortcut.messages[id]?.state { interruptedSeen += 1 }
                }
            }
        }

        // Non-vacuity in the dimension that matters here: some boundary really did
        // leave a generation open, so the `.open ⇒ .interrupted` path above was
        // exercised rather than merely available.
        #expect(interruptedSeen > 0, "no flush boundary left a generation interrupted")
    }

    @Test("the tail folds forward one flush at a time, not just once")
    func repeatedFlushesAccumulate() async throws {
        // The shape a streaming generation actually has: many small appends, each
        // folded onto the last (§7.4's ~4 Hz flush cadence). P1's two-part split
        // proves one boundary; this proves the composition, which is the case
        // where a stale `after:` or a mis-seeded routing map compounds instead of
        // cancelling out.
        //
        // `deltaAppended` is the payload that makes this interesting — it is one of
        // the two non-idempotent kinds (§6.6 ordering), so a boundary handled twice
        // shows up as doubled text rather than as an error.
        let log = Corpus.toolsAndMetadata.log
        let store = try SQLitePersistenceStore(.inMemory)

        var state = FoldedState.empty(log.conversation)
        var lastSequence: Int64 = 0
        for record in log.records {
            let flushed = try await store.append([record], to: log.conversation)
            state = fold(resuming: state, after: lastSequence, with: flushed.map(LoadedEvent.decoded))
            lastSequence = flushed.last?.sequence ?? lastSequence
        }

        #expect(state == log.folded())
        #expect(lastSequence == Int64(log.records.count))
    }
}

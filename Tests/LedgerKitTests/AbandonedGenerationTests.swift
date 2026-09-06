import Foundation
import Testing
@testable import LedgerKit

// M8 Phase 1: **the read side cannot stick** (D50; M7 boundary audit F1, plus F6
// found while reviewing the M8 plan).
//
// Two layers disagree about liveness on purpose — the store knows what *this
// process* is running, the log knows what *happened* — and every bug in this file
// is the same shape: a moment where the two disagree and nothing reconciles them.
// §7.4's overlay is the reconciliation, and it is only as good as the live set it
// is handed.
//
// Three windows, one remedy each, and they are genuinely distinct:
//
//   1. **Abandonment** (F1, D50.1/D50.2) — rev 8's "couldn't record" path. The
//      store throws with no terminal, releases the slot, and — until D50 — told
//      nobody. The generation reduces `.interrupted` forever (I5), which is
//      exactly what the prune used to *keep*, so an attached projection showed
//      `.streaming` for a dead generation until its view was torn down.
//   2. **The wind-down window** (F6, D50.3) — a generation that finished
//      *normally*. Between the terminal's append and `drive`'s `defer { release }`
//      the log says complete and the live set says running, and the attach path
//      never pruned.
//
// The pair below is also the clearest statement of §7.4's recovery granularity
// this suite has: `failedFlushShrinksToTheDurablePrefix` and
// `failedTerminalKeepsEverythingThatReachedDisk` run the *same* script through the
// *same* policy and differ only in which append fails — so the difference in what
// survives is the flush policy, made visible.

@Suite("M8 — an abandoned generation cannot stick", .timeLimit(.minutes(1)))
@MainActor
struct AbandonedGenerationTests {

    /// The script both failure tests use: one flush that lands, then a tail that
    /// is still buffered when the failure arrives.
    ///
    /// `"A valley "` is 9 characters and the policy flushes at 8, so it reaches
    /// disk on its own; `"fold"` is 4 and does not. The pause is what makes the
    /// *shown* partial observable before anything fails — a test that asserted the
    /// shrink without first seeing the longer value would be asserting nothing.
    private static func script(pausingAt latch: Latch) -> [ScriptedDriver.Step] {
        [.delta("A valley "), .delta("fold"), .pause(latch)]
    }

    private static let flushingAtEight = DeltaFlushPolicy.flushing(
        every: .seconds(3600),
        orAfterCharacters: 8
    )

    /// **F1, the wind-down flush door.** The durable prefix is all that survives,
    /// and the shown text visibly *shrinks* to it.
    ///
    /// That shrink is the assertion rather than something tolerated (D50's owned
    /// consequence): the unflushed tail was never durable, so claiming it survived
    /// would lie about what a relaunch shows. This is §7.4's recovery granularity
    /// happening while the process is still alive to watch it.
    @Test("a failed flush converges on .interrupted, shrinking to the durable prefix")
    func failedFlushShrinksToTheDurablePrefix() async throws {
        // Budget: genesis, send, the "A valley " flush. The wind-down flush is the
        // fourth append and fails.
        let fixture = try StoreUnderTest(
            over: FlakyStore(try SQLitePersistenceStore(.inMemory), tolerating: 3),
            deltaFlush: Self.flushingAtEight
        )
        let convo = try await fixture.store.createConversation(title: "Origami")
        let projection = try await ConversationProjection(of: convo.id, in: fixture.store)

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "Explain valley folds",
                in: convo.id,
                using: ScriptedDriver(Self.script(pausingAt: paused))
            )
        }
        await paused.waitForArrival()

        // What the screen shows mid-flight: everything the driver emitted, of which
        // only "A valley " has reached disk.
        try await waitFor(projection, toReach: .streaming(partial: "A valley fold"))

        await paused.release()
        _ = try? await running.value

        // The generation was abandoned: no terminal was written, so the fold says
        // `.open` and classification says `.interrupted` (I5) — carrying only what
        // was durable.
        try await waitFor(projection, toReach: .interrupted(partial: "A valley "))
        #expect(projection.live.isEmpty, "an abandoned generation must not stay in the live set")
        // **The store side of the same claim**, and it needs its own assertion:
        // a shown partial is only ever *read* through `liveSet(of:)`, which is
        // gated on the slot — so a leaked entry is unreachable rather than wrong,
        // and dropping the clear left the whole suite green. `shownPartials`
        // describes running generations; nothing is running, so it must be empty.
        await #expect(fixture.store.generationsWithShownPartials.isEmpty,
                      "the abandon path must release the partial it was holding")
    }

    /// **F1, the terminal door.** Same script, same policy, one append later —
    /// and the partial is *whole*, because everything reached disk before the
    /// terminal failed.
    ///
    /// Read against the test above, this is the flush policy stated as a
    /// difference rather than described: identical inputs, and what survives is
    /// exactly what had been written.
    @Test("a failed terminal converges on .interrupted, keeping everything that reached disk")
    func failedTerminalKeepsEverythingThatReachedDisk() async throws {
        // One more append of budget than above: the wind-down flush lands, and the
        // terminal is the fifth append and fails.
        let fixture = try StoreUnderTest(
            over: FlakyStore(try SQLitePersistenceStore(.inMemory), tolerating: 4),
            deltaFlush: Self.flushingAtEight
        )
        let convo = try await fixture.store.createConversation(title: "Origami")
        let projection = try await ConversationProjection(of: convo.id, in: fixture.store)

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "Explain valley folds",
                in: convo.id,
                using: ScriptedDriver(Self.script(pausingAt: paused))
            )
        }
        await paused.waitForArrival()
        try await waitFor(projection, toReach: .streaming(partial: "A valley fold"))

        await paused.release()
        _ = try? await running.value

        try await waitFor(projection, toReach: .interrupted(partial: "A valley fold"))
        #expect(projection.live.isEmpty, "an abandoned generation must not stay in the live set")
        // **The store side of the same claim**, and it needs its own assertion:
        // a shown partial is only ever *read* through `liveSet(of:)`, which is
        // gated on the slot — so a leaked entry is unreachable rather than wrong,
        // and dropping the clear left the whole suite green. `shownPartials`
        // describes running generations; nothing is running, so it must be empty.
        await #expect(fixture.store.generationsWithShownPartials.isEmpty,
                      "the abandon path must release the partial it was holding")
    }

    /// **F6/D50.3 — attaching in the wind-down window.**
    ///
    /// Nothing failed here. The generation completed, its terminal is committed,
    /// and the only reason the live set still names it is that `drive`'s
    /// `defer { release }` has not run yet. A projection attaching at that instant
    /// reads a `.complete` message and a running live set, and the overlay flips
    /// state **unconditionally** by design (`Overlay.swift` — declining to flip
    /// would hide a store bug rather than report it). So without a prune on the
    /// attach path the screen shows `.streaming` over a finished message.
    ///
    /// **And it does not heal.** The terminal's own `.changed` was published
    /// before this projection subscribed, and `release` publishes nothing, so no
    /// further notification is coming — the screen stays wrong until some
    /// unrelated write touches the conversation.
    @Test("attaching between a terminal's append and its release shows the completed message")
    func attachingDuringWindDownShowsTheTerminal() async throws {
        let parked = Latch()
        let fixture = try StoreUnderTest(
            over: ParkingStore(
                try SQLitePersistenceStore(.inMemory),
                parkingFirst: .snapshotSave,
                at: parked
            )
        )
        let convo = try await fixture.store.createConversation(title: "Origami")

        let running = Task {
            try await fixture.store.send(
                "Explain valley folds",
                in: convo.id,
                using: ScriptedDriver(saying: "A valley fold.")
            )
        }
        // The park sits inside the terminal's append — after the commit, before
        // the slot is released.
        await parked.waitForArrival()

        // Attaching *now* is the whole test. Both reads happen inside the window.
        let projection = try await ConversationProjection(of: convo.id, in: fixture.store)

        let shown = try #require(projection.conversation.activeMessages.last)
        #expect(
            shown.state == .complete(MessageContent(text: "A valley fold.")),
            "the log says this generation ended; a live set that has not caught up must not overrule it"
        )
        #expect(projection.live.isEmpty, "the prune must retire a generation the log has already ended")

        await parked.release()
        _ = try? await running.value
    }

    /// The regression the two failure tests could otherwise hide: a projection
    /// attached *after* the abandonment must agree with one that lived through it.
    ///
    /// Before D50 these two disagreed permanently — a fresh attach read the log and
    /// said `.interrupted`, while the attached one still said `.streaming` — which
    /// is the sharpest possible statement of the bug: **two views of one store,
    /// both derived, showing different states of the same message.**
    @Test("a projection that lived through the abandonment agrees with a fresh one")
    func attachedAndFreshProjectionsAgree() async throws {
        let fixture = try StoreUnderTest(
            over: FlakyStore(try SQLitePersistenceStore(.inMemory), tolerating: 3),
            deltaFlush: Self.flushingAtEight
        )
        let convo = try await fixture.store.createConversation(title: "Origami")
        let attached = try await ConversationProjection(of: convo.id, in: fixture.store)

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "Explain valley folds",
                in: convo.id,
                using: ScriptedDriver(Self.script(pausingAt: paused))
            )
        }
        await paused.waitForArrival()
        try await waitFor(attached, toReach: .streaming(partial: "A valley fold"))
        await paused.release()
        _ = try? await running.value

        try await waitFor(attached, toReach: .interrupted(partial: "A valley "))

        let fresh = try await ConversationProjection(of: convo.id, in: fixture.store)
        #expect(
            fresh.conversation == attached.conversation,
            "two derived views of one store must not disagree about the same message"
        )

        // And the abandoned log is *healthy* — nothing about it is malformed, which
        // is why recovery needs no repair (§6.5's healthy-log property). An
        // interrupted generation is a well-formed log; that is the whole design.
        let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")
    }
}

/// Spins until the conversation's last active message reaches `state`.
///
/// ⚠️ **The condition is the assertion's actual precondition, not a proxy for it**
/// — the async-test rule M7 learned three times in one milestone. `live.isEmpty`
/// would be true both before the projection processed anything *and* after the
/// generation finished; `activeMessages.count` goes true when a message is
/// *created*. Only the state itself distinguishes them.
@MainActor
private func waitFor(
    _ projection: ConversationProjection,
    toReach state: MessageState
) async throws {
    try await spin(until: { @MainActor in
        projection.conversation.activeMessages.last?.state == state
    })
}

import Foundation
import Testing
@testable import LedgerKit

// M7 Phase 3: **recovery, asserted as the overlay vanishing.**
//
// This file exists to make one sentence executable — the roadmap's M7 exit
// criterion, "recovery = overlay vanishing, no recovery pass" — and §6.3's
// three-name table read right-to-left:
//
//     folded .open  →  classified .interrupted  →  overlaid .streaming
//                   ←  ←  ←  the crash
//
// A live store shows `.streaming`. Kill the process and nothing *runs*: the live
// set is vacuously empty at next launch, the overlay is the identity, and the
// fold's honest "no terminal exists" surfaces as `.interrupted`. The thing worth
// noticing in the tests below is what is **absent** — there is no repair call, no
// recovery routine, no dirty flag being cleared, because there is nothing to
// repair. G4 is a consequence of the data model rather than a feature on top of it.
//
// **Tier 1, deliberately, though the plan filed this under Phase 3's tier-2 half.**
// A crash is modelled by dropping a projection and reopening a store over the same
// database, and neither needs a real session — so this runs on any Mac, where it is
// worth strictly more. The 27-gated pipeline that *does* need one is in
// `DriverPipelineTests`.

@Suite("M7 — recovery is the overlay vanishing", .timeLimit(.minutes(1)))
@MainActor
struct RecoveryTests {

    /// **DoD-1's automated sibling** (the GIF is the same flow with a hand on the
    /// camera).
    ///
    /// Streams mid-generation, tears the projection down without letting the
    /// generation finish, reopens over the same database with a cold cache, and
    /// asserts the same message now reads `.interrupted`.
    ///
    /// The **delta between the two views is exactly the unflushed tail** — §7.4's
    /// documented recovery granularity, asserted rather than described. That is the
    /// whole honest claim of the design: what a crash costs is bounded by the flush
    /// policy and nothing else.
    @Test("a killed generation reads .interrupted with the flushed partial, and nothing repairs it")
    func killMidStreamRecoversAsInterrupted() async throws {
        // A policy that flushes the first chunk and then never again on its own, so
        // "what reached disk" and "what was on screen" are *different* and known.
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .seconds(3600), orAfterCharacters: 8))
        let convo = try await fixture.store.createConversation(title: "Origami")

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "Explain valley folds",
                in: convo.id,
                using: ScriptedDriver([
                    // The buffer **resets after every flush**, so the bound applies to
                    // each accumulation independently — not to the generation. 14 ≥ 8
                    // flushes and clears; 6 and then 7 never reach 8, so they stay.
                    // (Got this wrong first time by reading the bound as cumulative,
                    // which is why the split is spelled out rather than assumed.)
                    .delta("A valley fold "),   // 14 chars → flushes
                    .delta("brings"),           // 6  → buffered
                    .delta("!"),                // 7  → still buffered
                    .pause(paused),
                ])
            )
        }
        await paused.waitForArrival()

        // What the *screen* showed: everything the driver emitted.
        let live = try await ConversationProjection(of: convo.id, in: fixture.store)
        try await spin(until: { @MainActor in
            live.live.values.contains("A valley fold brings!")
        })
        let onScreen = try #require(live.conversation.activeMessages.last)
        #expect(onScreen.state == .streaming(partial: "A valley fold brings!"))

        // **The kill.** The projection goes away and a *new* store opens over the same
        // database with an empty fold cache — the honest cold open (D29's shape), not a
        // re-read through a warm actor that never actually forgot anything. The
        // generation task is abandoned without a terminal, exactly as process death
        // leaves it.
        let relaunched = fixture.reopened()
        let recovered = try await ConversationProjection(of: convo.id, in: relaunched)

        let afterCrash = try #require(recovered.conversation.activeMessages.last)
        // The three-name table, right-to-left. Note what is *not* here: no repair
        // call, no `recover()`, no flag. The overlay is the identity because the live
        // set of a store that never started a generation is empty, and `.interrupted`
        // was already what the fold said.
        #expect(afterCrash.state == .interrupted(partial: "A valley fold "))
        #expect(recovered.live.isEmpty, "a relaunched store has nothing in flight")
        #expect(afterCrash.id == onScreen.id, "recovery must surface the same message, not a new one")

        // §7.4's recovery granularity, stated as arithmetic: the difference between
        // the two views is precisely the tail the flush policy had not yet written.
        // `visibleText` is the module's own "what the user saw" accessor (§7.1) —
        // reused rather than re-declared, since the alternative is a second private
        // copy of the same five-case switch.
        #expect(onScreen.visibleText == afterCrash.visibleText + "brings!")

        // And the log a crash left behind is *healthy* — no diagnostics. An
        // interrupted generation is a well-formed log, which is why recovery needs no
        // repair (§6.5's healthy-log property).
        let problems = try await healthyLogProblems(convo.id, in: relaunched, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")

        await paused.release()
        _ = try? await running.value
    }

    /// The same recovery, seen through **P2's degenerate case** (§10.6): an empty
    /// live set makes the overlay the identity, so the projection *equals* the
    /// classified fold. Asserted as value equality, which is stronger than the
    /// predicate returning no problems.
    @Test("after a crash the projection is exactly the classified fold")
    func recoveredProjectionEqualsTheFold() async throws {
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .seconds(3600), orAfterCharacters: 4))
        let convo = try await fixture.store.createConversation()

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "q",
                in: convo.id,
                using: ScriptedDriver([.delta("half an "), .delta("answer"), .pause(paused)])
            )
        }
        await paused.waitForArrival()

        let relaunched = fixture.reopened()
        let recovered = try await ConversationProjection(of: convo.id, in: relaunched)

        #expect(recovered.conversation == recovered.classified, "with nothing live the overlay is the identity")
        let problems = projectionProblems(
            in: recovered.conversation,
            overlaying: recovered.classified,
            foldedFrom: recovered.folded,
            live: recovered.live
        )
        #expect(problems.isEmpty, "\(problems)")

        // Non-vacuity: the fixture really did leave an interrupted generation behind,
        // so the identity above is being applied to the state this test is about.
        let interrupted = recovered.conversation.activeMessages.contains {
            if case .interrupted = $0.state { true } else { false }
        }
        #expect(interrupted, "the crash left nothing interrupted, so this proved nothing")

        await paused.release()
        _ = try? await running.value
    }

    /// **DoD-1's second half: the interrupted partial survives as its own branch**,
    /// reachable through the branch switcher, and Regenerate works over it.
    ///
    /// This is the part §6.4 says falls out of the model rather than being a feature —
    /// a regeneration is a *sibling*, so the crashed attempt is still there.
    @Test("the interrupted partial survives as a sibling, and regenerate works over it")
    func interruptedPartialSurvivesRegeneration() async throws {
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .seconds(3600), orAfterCharacters: 4))
        let convo = try await fixture.store.createConversation()

        let paused = Latch()
        let crashed = Task {
            try await fixture.store.send(
                "Explain valley folds",
                in: convo.id,
                using: ScriptedDriver([.delta("A valley "), .pause(paused)])
            )
        }
        await paused.waitForArrival()

        // **Continue the identifier stream**, because this store is about to write.
        // Restarting it re-mints the identifiers the first store used, and the
        // regeneration quarantines instead of landing — see `reopened`'s note.
        let relaunched = fixture.reopened(eventsFrom: 0x110, messagesFrom: 0x1F, generationsFrom: 0x3F)
        let projection = try await ConversationProjection(of: convo.id, in: relaunched)
        let interrupted = try #require(projection.conversation.activeMessages.last)
        #expect(interrupted.state == .interrupted(partial: "A valley "))

        // Regenerate — the affordance §8 gives an `.interrupted` message (G4).
        _ = try await relaunched.regenerate(
            interrupted.id,
            in: convo.id,
            using: ScriptedDriver(saying: "A valley fold.")
        )
        try await spin(until: { @MainActor in
            projection.conversation.activeMessages.last?.state == .complete(MessageContent(text: "A valley fold."))
        })

        // The new response is on the path…
        #expect(projection.conversation.activeMessages.last?.state == .complete(MessageContent(text: "A valley fold.")))
        // …and the crashed attempt is a *sibling* of it, still holding its partial.
        let siblings = projection.conversation.messages.siblings(of: interrupted.id)
        #expect(siblings.count == 1, "the regeneration should be the interrupted message's sibling")
        #expect(projection.conversation.messages[interrupted.id]?.state == .interrupted(partial: "A valley "),
                "the partial must survive regeneration, not be replaced by it")

        await paused.release()
        _ = try? await crashed.value
    }
}

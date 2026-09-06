import Foundation
import Testing
@testable import LedgerKit

// M7 Phase 2: the store→projection feed and the two `@Observable` types.
//
// **Tier 1 throughout.** Everything here runs on any Mac with no Foundation Models
// anywhere, because the generation side is `ScriptedDriver` — the store-level double
// M5 wrote for exactly this. The 27-gated pipeline is Phase 3's.
//
// Two conventions worth knowing before reading:
//
//  - **Cadence `.zero` is what tests inject**, and it is also the default (D48), so
//    these tests exercise the shipping configuration rather than a special one. A
//    delta therefore reaches `conversation` before the next `await` completes, and
//    nothing here sleeps.
//  - **`spin(until:)` rather than sleeps.** The feed is an `AsyncStream` consumed by
//    a task the projection owns, so "has the projection seen it yet" is a real
//    question with a real answer — polled with cancellation checks, because a bare
//    `Task.yield()` spin defeats `.timeLimit` (measured at M6 Phase 0).

/// Waits until the projection's last active message reaches a state satisfying
/// `predicate`.
///
/// ⚠️ **Exists because the obvious spin conditions are all proxies, and every one of
/// them produced a flake.** `activeMessages.count == 2` goes true when the assistant
/// message is *created* — long before it is `.failed`. `live.isEmpty` is true both
/// after a generation finishes *and* before the projection has processed anything at
/// all. `live.count == 1` is true after the **first** delta, not the last. Each of
/// those passed in a filtered run every time and failed under the parallel suite,
/// which is the only place the windows are wide enough to lose.
///
/// The rule this encodes: **spin on the assertion's actual precondition.** If the
/// test is about a state, wait for that state — never for something that merely
/// tends to precede it.
@MainActor
private func waitForLastMessage(
    of projection: ConversationProjection,
    toReach predicate: @escaping @MainActor (MessageState) -> Bool
) async throws {
    try await spin(until: { @MainActor in
        projection.conversation.activeMessages.last.map { predicate($0.state) } ?? false
    })
}

/// A store, a projection over it, and the conversation they share.
@MainActor
private func attach(
    mapping: RecoverabilityMapping = .default,
    displayCadence: Duration = .zero
) async throws -> (fixture: StoreUnderTest, id: ConversationID, projection: ConversationProjection) {
    let fixture = try StoreUnderTest()
    let convo = try await fixture.store.createConversation(title: "Origami")
    let projection = try await ConversationProjection(
        of: convo.id,
        in: fixture.store,
        mapping: mapping,
        displayCadence: displayCadence
    )
    return (fixture, convo.id, projection)
}

@Suite("Projection — the conversation view", .timeLimit(.minutes(1)))
@MainActor
struct ConversationProjectionTests {

    /// **Clause 1, live.** The whole point of the delta path: what the screen shows
    /// is the exact concatenation of everything the driver emitted, not the subset
    /// that reached disk.
    @Test("streaming renders .streaming with the exact text, ahead of the flush")
    func streamingShowsTheExactText() async throws {
        // A flush policy that will not fire on its own — a huge character bound and
        // a very long interval — so any text on screen got there *without* a disk
        // write. That is §7.4's two cadences, isolated.
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .seconds(3600), orAfterCharacters: 1_000_000))
        let convo = try await fixture.store.createConversation()
        let projection = try await ConversationProjection(of: convo.id, in: fixture.store)

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "q",
                in: convo.id,
                using: ScriptedDriver([.delta("A valley "), .delta("fold "), .delta("brings"), .pause(paused)])
            )
        }
        await paused.waitForArrival()
        // **Spin on the text, not on `live.count`.** The driver reaching its pause
        // means it *emitted* three deltas; it does not mean the store's consume loop
        // and the projection's feed have drained them. `live.count == 1` goes true
        // after the *first* delta, so asserting the full text on that condition is a
        // race — one that passes in a filtered run and fails under the parallel
        // suite, which is how it was found.
        try await spin(until: { @MainActor in projection.live.values.contains("A valley fold brings") })

        let assistant = try #require(projection.conversation.activeMessages.last)
        #expect(assistant.state == .streaming(partial: "A valley fold brings"))

        // And the log has none of it yet, which is what makes the assertion above a
        // statement about *cadence* rather than about reduction.
        let flushed = fixture.written.contains { if case .deltaAppended = $0.payload { true } else { false } }
        #expect(!flushed, "no delta should have reached disk under this policy")

        await paused.release()
        _ = try await running.value
    }

    /// **Clause 3, by construction.** On a terminal the projection re-pulls, the
    /// message is no longer `.interrupted`, and the live entry is pruned — so the
    /// overlay has nothing left to overlay. No "generation ended" notification is
    /// needed for this, which is why the feed does not have one.
    @Test("a terminal flips the message to .complete and drops the live entry")
    func terminalDropsTheLiveEntry() async throws {
        let (fixture, id, projection) = try await attach()

        _ = try await fixture.store.send("q", in: id, using: ScriptedDriver(saying: "Dublin"))
        try await waitForLastMessage(of: projection, toReach: { $0 == .complete(MessageContent(text: "Dublin")) })

        let assistant = try #require(projection.conversation.activeMessages.last)
        #expect(assistant.state == .complete(MessageContent(text: "Dublin")))
        #expect(projection.live.isEmpty, "a finished generation must not stay live")
    }

    /// A projection created **while a generation streams** must show the whole
    /// partial, not the flushed prefix. Without `store.liveSet(of:)` it would render
    /// `.interrupted` for something still running — and P2 would not flag it, because
    /// an empty live set is self-consistent. Only a person would notice.
    @Test("attaching mid-generation shows the live partial, not .interrupted")
    func attachingMidGenerationSeesTheLiveText() async throws {
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .seconds(3600), orAfterCharacters: 1_000_000))
        let convo = try await fixture.store.createConversation()

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "q",
                in: convo.id,
                using: ScriptedDriver([.delta("half an ans"), .pause(paused)])
            )
        }
        await paused.waitForArrival()
        // The driver has emitted; wait for the *store* to have consumed it, or the
        // live set this test is about would legitimately still be empty.
        try await spin(until: { await fixture.store.liveSet(of: convo.id).values.contains("half an ans") })

        // Attach only now, with the generation already in flight and nothing flushed.
        let projection = try await ConversationProjection(of: convo.id, in: fixture.store)

        let assistant = try #require(projection.conversation.activeMessages.last)
        #expect(assistant.state == .streaming(partial: "half an ans"))

        await paused.release()
        _ = try await running.value
    }

    /// **A generation that has produced no text yet is still `.streaming`** — the
    /// regression test for the flash M7 Phase 3's tier-2 pipeline test found.
    ///
    /// A projection populating its live set from `.delta` notifications alone has
    /// nothing to go on between the start append and the first delta, so it rendered
    /// `.interrupted` — the one state whose entire job is to mean *this is not
    /// running* — for a generation that was actively running. Against a real model
    /// that window is however long the provider takes to say its first word, so
    /// every single generation began with a visible flash of the crash state.
    ///
    /// The fix is that a re-pull takes the **store's** live set rather than only
    /// pruning the accumulated one. What it renders is `.streaming(partial: "")`,
    /// which is §6.2's deliberate refusal to have a `.pending` state distinct from
    /// an empty `.streaming` — the case that spec sentence was written for, finally
    /// reachable.
    @Test("a started generation with no text yet is .streaming, never .interrupted")
    func startedButSilentGenerationIsStreaming() async throws {
        let (fixture, id, projection) = try await attach()

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "q",
                in: id,
                using: ScriptedDriver([.pause(paused), .delta("eventually")])
            )
        }
        await paused.waitForArrival()
        try await waitForLastMessage(of: projection, toReach: { $0 == .streaming(partial: "") })

        #expect(projection.conversation.activeMessages.last?.state == .streaming(partial: ""),
                "a running generation must never render as the crash state")

        await paused.release()
        _ = try await running.value
    }

    /// §6.5 makes mid-stream edits and switches legal — single-flight gates
    /// generation *starts*, not ledger writes. From up here that legality becomes
    /// visible for the first time: the tree changes under a running generation and
    /// the stream keeps going.
    @Test("a mid-stream edit re-pulls without disturbing the stream")
    func midStreamEditRepullsWithoutLosingTheStream() async throws {
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .seconds(3600), orAfterCharacters: 1_000_000))
        let convo = try await fixture.store.createConversation()
        let projection = try await ConversationProjection(of: convo.id, in: fixture.store)

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "first question",
                in: convo.id,
                using: ScriptedDriver([.delta("streaming along"), .pause(paused)])
            )
        }
        await paused.waitForArrival()
        try await spin(until: { @MainActor in projection.live.count == 1 })

        let user = try #require(projection.conversation.activeMessages.first)
        let replacement = try await fixture.store.edit(user.id, content: "second question", in: convo.id)
        try await spin(until: { @MainActor in projection.conversation.messages[replacement] != nil })

        // The edit landed *and* the stream is still live. A re-pull that clobbered the
        // live set would show the assistant as `.interrupted` here.
        #expect(projection.conversation.messages[replacement]?.state == .complete(MessageContent(text: "second question")))
        #expect(projection.live.count == 1, "the edit must not disturb the live set")

        await paused.release()
        _ = try await running.value
    }

    /// **Handoff 3: the mapping rides the projection.** `Recoverability` is never
    /// persisted, so an app's override is applied at classification time — and
    /// `store.conversation(_:)` deliberately keeps §8's default table, which is what
    /// makes this a difference two readers of the same log can legitimately have.
    @Test("a mapping override changes the affordance projection-side only")
    func mappingOverrideRidesTheProjection() async throws {
        var mapping = RecoverabilityMapping.default
        // §8's default for a guardrail violation is `terminal`; this app disagrees.
        mapping.guardrailViolation = .retryable(after: .seconds(5))

        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        let projection = try await ConversationProjection(of: convo.id, in: fixture.store, mapping: mapping)

        _ = try await fixture.store.send(
            "q",
            in: convo.id,
            using: ScriptedDriver([.delta("partial")], ending: .failed(.guardrailViolation))
        )
        try await waitForLastMessage(of: projection, toReach: { if case .failed = $0 { true } else { false } })

        guard case .failed(_, _, let recoverability) = projection.conversation.activeMessages.last?.state else {
            Issue.record("expected a failed message")
            return
        }
        #expect(recoverability == .retryable(after: .seconds(5)), "the projection's mapping must win here")

        // The store, reading the same log, still reports §8's default — same events,
        // two mappings, and neither is wrong.
        let read = try await fixture.store.conversation(convo.id)
        guard case .failed(_, _, let byDefault) = read.activeMessages.last?.state else {
            Issue.record("expected a failed message from the store too")
            return
        }
        #expect(byDefault == .terminal)
    }

    /// **P2 against fully real inputs** — the predicate's first contact with a live
    /// store on the live side. Everything before this fed it constructed live sets.
    ///
    /// ⚠️ **Clause 1 is tautological here, so this test carries its own oracle.**
    /// The predicate asserts `shown == live[generation]`, and the overlay *builds*
    /// `shown` from `live[generation]` — so against a live store the two agree by
    /// construction **even when the live set is wrong**. Measured, not reasoned:
    /// mutating the projection to accumulate suffixes (D47's hazard) left this test
    /// green and was caught only by `streamingShowsTheExactText`, which compares
    /// against the script.
    ///
    /// §10.6's wording is the stronger one — the partial equals *the concatenated
    /// deltas*, which is a claim about the **log**, not about the live set. So the
    /// assertion below compares the shown text against what the script emitted,
    /// which is the only independent source in the room. What the predicate still
    /// buys here is clauses 2 and 3 and the not-more-than-state checks, against
    /// inputs nobody constructed.
    @Test("P2 holds against a live store mid-generation")
    func p2AgainstALiveStore() async throws {
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .milliseconds(1), orAfterCharacters: 1))
        let convo = try await fixture.store.createConversation()
        let projection = try await ConversationProjection(of: convo.id, in: fixture.store)

        let paused = Latch()
        let running = Task {
            try await fixture.store.send(
                "q",
                in: convo.id,
                using: ScriptedDriver([.delta("some "), .delta("text "), .pause(paused), .delta("more")])
            )
        }
        await paused.waitForArrival()
        try await spin(until: { @MainActor in projection.live.values.contains("some text ") })

        // **The independent oracle**: what the script emitted, which no layer under
        // test computed. This is the assertion that fails if the live set is wrong,
        // and the reason it is here rather than left to the predicate.
        #expect(projection.conversation.activeMessages.last?.state == .streaming(partial: "some text "))

        // A flush policy that fires on *every* delta, so the fold holds some of the
        // text and the live set holds all of it — the state where a suffix-accumulating
        // projection would double-count (D47's hazard, now unrepresentable).
        let problems = projectionProblems(
            in: projection.conversation,
            overlaying: projection.classified,
            foldedFrom: projection.folded,
            live: projection.live
        )
        #expect(problems.isEmpty, "\(problems)")

        await paused.release()
        _ = try await running.value

        try await spin(until: { @MainActor in projection.live.isEmpty })
        let settled = projectionProblems(
            in: projection.conversation,
            overlaying: projection.classified,
            foldedFrom: projection.folded,
            live: projection.live
        )
        #expect(settled.isEmpty, "\(settled)")
    }

    /// Deletion is irreversible and out-of-band (§9), so the projection says so
    /// rather than leaving the app to infer it from a thrown read.
    @Test("deletion is surfaced, and the last view is kept")
    func deletionIsSurfaced() async throws {
        let (fixture, id, projection) = try await attach()
        _ = try await fixture.store.send("q", in: id, using: ScriptedDriver(saying: "Dublin"))
        try await waitForLastMessage(of: projection, toReach: { $0 == .complete(MessageContent(text: "Dublin")) })
        let lastView = projection.conversation

        try await fixture.store.deleteConversation(id)
        try await spin(until: { @MainActor in projection.isDeleted })

        #expect(projection.conversation == lastView, "the last view is frozen, not blanked")
    }

    /// Attaching to something that was never created fails at construction, which is
    /// what lets `conversation` be non-optional everywhere else.
    @Test("attaching to an unknown conversation throws")
    func attachingToUnknownThrows() async throws {
        let fixture = try StoreUnderTest()
        await #expect(throws: LedgerError.unknownConversation(Fix.foreign)) {
            _ = try await ConversationProjection(of: Fix.foreign, in: fixture.store)
        }
    }

    /// **D48's measurement, not its intuition.** The knob's whole justification is
    /// that it reduces overlay work; this is the number that says whether it does.
    @Test("a non-zero cadence coalesces overlay applications; .zero does not")
    func displayCadenceCoalesces() async throws {
        let deltas: [ScriptedDriver.Step] = (0..<8).map { .delta("chunk\($0) ") }

        let immediate = try await attach(displayCadence: .zero)
        let text = "chunk0 chunk1 chunk2 chunk3 chunk4 chunk5 chunk6 chunk7 "
        _ = try await immediate.fixture.store.send("q", in: immediate.id, using: ScriptedDriver(deltas))
        try await waitForLastMessage(of: immediate.projection, toReach: { $0 == .complete(MessageContent(text: text)) })

        let coalesced = try await attach(displayCadence: .milliseconds(200))
        _ = try await coalesced.fixture.store.send("q", in: coalesced.id, using: ScriptedDriver(deltas))
        try await waitForLastMessage(of: coalesced.projection, toReach: { $0 == .complete(MessageContent(text: text)) })

        // Both settle on the same text — the knob trades latency for work, never
        // content.
        #expect(immediate.projection.conversation.activeMessages.last?.state == .complete(MessageContent(text: text)))
        #expect(coalesced.projection.conversation.activeMessages.last?.state == .complete(MessageContent(text: text)))

        // And the coalesced one did strictly less work. Asserted as an inequality
        // rather than a count, because the exact number depends on how many deltas
        // land inside one 200 ms window — which is scheduling, not contract.
        #expect(
            coalesced.projection.overlayApplications < immediate.projection.overlayApplications,
            "coalesced \(coalesced.projection.overlayApplications) vs immediate \(immediate.projection.overlayApplications)"
        )
    }
}

@Suite("Projection — the store feed", .timeLimit(.minutes(1)))
struct StoreFeedTests {

    /// The feed's **ordering contract**, pinned directly rather than through a
    /// projection — because the one reorder that would not self-heal is invisible
    /// from up there.
    ///
    /// A `.changed` arriving late is harmless: its handling is "re-read the latest",
    /// which is idempotent, so lateness costs a redundant read and nothing else. What
    /// is *not* harmless is a **`.delta` arriving after its generation's terminal
    /// `.changed`**: the projection would have pruned the live entry, the delta would
    /// put it back, and the overlay would sit on `.streaming` forever with no further
    /// notification to correct it. Nothing downstream can recover from that, so the
    /// order is the guarantee.
    ///
    /// Today it holds by construction — every notification is one synchronous
    /// `yield` into one stream, in program order — which is precisely why this is
    /// asserted here, at the only layer where the order is observable.
    @Test("a generation's deltas all precede its terminal, and the start precedes them")
    func feedOrderingIsCausal() async throws {
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .seconds(3600), orAfterCharacters: 1_000_000))
        let convo = try await fixture.store.createConversation()

        let notifications = await fixture.store.notifications()
        let collector = Task {
            var seen: [StoreNotification] = []
            for await notification in notifications { seen.append(notification) }
            return seen
        }

        _ = try await fixture.store.send(
            "q",
            in: convo.id,
            using: ScriptedDriver([.delta("one "), .delta("two "), .delta("three")])
        )
        try await fixture.store.setTitle("done", in: convo.id)
        await fixture.store.finishNotifications()

        let seen = await collector.value
        let kinds = seen.map { notification -> String in
            switch notification {
            case .delta: "delta"
            case .changed: "changed"
            case .deleted: "deleted"
            }
        }

        // `send` is one transaction (user message + start) so it is a single
        // `.changed`; then the deltas; then the pre-terminal flush (silent — a delta
        // append sends nothing) and the terminal (`.changed`); then the retitle.
        #expect(kinds == ["changed", "delta", "delta", "delta", "changed", "changed"], "\(kinds)")

        // The property that cannot self-heal, stated as itself: no delta follows the
        // terminal that ended its generation.
        let lastDelta = kinds.lastIndex(of: "delta")
        let terminal = kinds.indices.filter { kinds[$0] == "changed" }.dropFirst().first
        #expect(lastDelta != nil && terminal != nil && lastDelta! < terminal!)
    }
}

@Suite("Projection — the conversation list", .timeLimit(.minutes(1)))
@MainActor
struct ConversationListProjectionTests {

    @Test("the list tracks creation, retitling and deletion, newest first")
    func listTracksTheIndex() async throws {
        let fixture = try StoreUnderTest()
        let list = try await ConversationListProjection(in: fixture.store)
        #expect(list.conversations.isEmpty)

        let older = try await fixture.store.createConversation(title: "older")
        try await spin(until: { @MainActor in list.conversations.count == 1 })
        let newer = try await fixture.store.createConversation(title: "newer")
        try await spin(until: { @MainActor in list.conversations.count == 2 })

        // `lastEventAt` descending — the order the index returns and a list wants.
        #expect(list.conversations.map(\.id) == [newer.id, older.id])

        try await fixture.store.setTitle("renamed", in: older.id)
        try await spin(until: { @MainActor in list.conversations.contains { $0.title == "renamed" } })
        // Retitling `older` makes it the most recent *meaningful* event, so it moves.
        #expect(list.conversations.map(\.id) == [older.id, newer.id])

        try await fixture.store.deleteConversation(newer.id)
        try await spin(until: { @MainActor in list.conversations.count == 1 })
        #expect(list.conversations.map(\.id) == [older.id])
    }

    /// **§9's no-churn rule, observed from above.** The index is maintained on
    /// non-delta appends only, so a streaming generation must move nothing here —
    /// asserted as a *refresh count*, because asserting on order alone would pass
    /// even if the list reloaded five hundred rows at flush cadence and happened to
    /// get the same answer.
    @Test("delta flushes do not churn the list")
    func deltaFlushesDoNotChurnTheList() async throws {
        // Flush on every single delta: the loudest possible disk cadence.
        let fixture = try StoreUnderTest(deltaFlush: .flushing(every: .nanoseconds(1), orAfterCharacters: 1))
        let convo = try await fixture.store.createConversation(title: "streaming")
        let list = try await ConversationListProjection(in: fixture.store)
        try await spin(until: { @MainActor in list.conversations.count == 1 })

        let before = list.refreshes
        _ = try await fixture.store.send(
            "q",
            in: convo.id,
            using: ScriptedDriver((0..<10).map { .delta("chunk\($0) ") })
        )
        try await spin(until: { @MainActor in list.refreshes > before })

        // Ten delta flushes happened; the list refreshed only for the non-delta
        // events among them — the user message, the start, and the terminal.
        let flushes = fixture.appends.filter { batch in
            batch.allSatisfy { if case .deltaAppended = $0.payload { true } else { false } }
        }.count
        #expect(flushes >= 5, "expected the flush policy to fire repeatedly, got \(flushes)")
        // Bounded on **both** sides: the upper bound is the no-churn claim, and the
        // lower bound is what stops it passing by never refreshing at all.
        let refreshed = list.refreshes - before
        #expect(refreshed >= 1, "the list never refreshed, so its upper bound proves nothing")
        #expect(refreshed <= 3, "the list refreshed \(refreshed) times across \(flushes) delta flushes")
    }
}

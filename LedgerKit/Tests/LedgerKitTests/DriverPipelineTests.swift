import Foundation
import FoundationModels
import Testing
import Understudy
@testable import LedgerKit

// M6 Phase 3: **the whole pipeline, asserted as one thing.**
//
//     script fragments → ScriptedLanguageModel → framework accumulation
//         → ResponseStream snapshots → GenerationDriver's differ
//         → GenerationChannel → ConversationStore's flush loop
//         → SQLite → the reducer
//
// Every layer has been right about this on its own since M2; this is the first
// suite in which they have to be right about it *together*. Tier 2 throughout,
// executed on the iOS 27 simulator.
//
// ## Why these logs are deterministic despite a nondeterministic stream
//
// Phase 2 measured the framework coalescing fragments on its own cadence, so the
// number of deltas a driver emits **varies between runs**. That would normally
// rule out asserting a log byte-for-byte. It does not, because of a mechanism
// the spec already has for another reason: §7.4's flush policy means the *store*
// decides how many `deltaAppended` rows exist, not the provider. A policy that
// never comes due writes exactly one — the mandatory pre-terminal flush — so the
// framework's cadence is erased before it reaches disk, and the log is stable.
//
// That is worth stating plainly because it is not a trick: it is the same
// property that makes the ledger's granularity a durability decision rather than
// a provider artifact.

@Suite("Session — the driver pipeline", .enabled(if: foundationModelsAvailable), .timeLimit(.minutes(1)))
struct DriverPipelineTests {

    /// Coalesces everything into the single pre-terminal flush (§7.4).
    private static let oneRow: DeltaFlushPolicy = .flushing(every: .seconds(3600), orAfterCharacters: .max)
    /// The opposite extreme: every delta the driver emits becomes a row.
    private static let everyDelta: DeltaFlushPolicy = .flushing(every: .zero, orAfterCharacters: 1)

    private var descriptor: ModelDescriptor { ModelDescriptor(provider: "understudy", model: "scripted") }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func driver(_ script: Script) -> GenerationDriver {
        GenerationDriver(model: ScriptedLanguageModel(script: script), descriptor: descriptor)
    }

    /// The assistant text a conversation ended up with.
    private func answer(in conversation: Conversation) -> String? {
        conversation.activeMessages.last?.state.partialOrComplete
    }

    // MARK: - The round trip (M6's "real stream captured & reduced")

    /// **The milestone's exit criterion.** Scripted fragments go in as provider
    /// deltas; what comes out of the far end — a SQLite log, reduced — is the
    /// same text.
    ///
    /// Asserted as **text**, not as fragment boundaries, which is Phase 2's
    /// correction to §7.3: the framework coalesces on its own cadence and §7.4's
    /// flush policy reshapes boundaries again, so where the seams fall is a
    /// durability decision rather than a property of the stream. The
    /// concatenation is what the ledger promises, and it is what survives.
    @Test("scripted fragments arrive in the ledger as the text the script said")
    func roundTrip() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let fragments = ["A valley fold ", "brings the paper ", "down."]
        let fixture = try StoreUnderTest(deltaFlush: Self.oneRow)
        let convo = try await fixture.store.createConversation()

        let outcome = try await fixture.store.send("Explain valley folds", in: convo.id, using: driver(Script(fragments.map { .emit($0) })))

        guard case .completed = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(answer(in: try await fixture.store.conversation(convo.id)) == fragments.joined())

        // And the log the reducer sees agrees with the store's own view — the
        // healthy-log property, now over a log the *real* pipeline produced.
        let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")
    }

    /// The same claim at the opposite flush extreme, which is what makes it a
    /// property rather than a coincidence of one policy: however many rows the
    /// store chose to write, they concatenate to the script.
    @Test("the text survives at any flush cadence")
    func roundTripAtEveryCadence() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let fragments = ["one ", "two ", "three"]

        for policy in [Self.oneRow, Self.everyDelta] {
            let fixture = try StoreUnderTest(deltaFlush: policy)
            let convo = try await fixture.store.createConversation()
            _ = try await fixture.store.send("go", in: convo.id, using: driver(Script(fragments.map { .emit($0) })))

            #expect(answer(in: try await fixture.store.conversation(convo.id)) == fragments.joined())
        }
    }

    /// **Byte-stable, which the stream alone is not.** With identifiers and the
    /// clock injected and the flush policy pinning row count, a real generation
    /// produces exactly the log a hand-written fixture spells — so this asserts
    /// the pipeline against `Log`, the same fixture vocabulary the reducer and
    /// store suites use.
    ///
    /// **No corpus file is added, deliberately** (the plan left this open). The
    /// corpus exists to sweep logs through truncation, interior-gap and P3
    /// coverage, and none of those sweeps can tell where a log came from — the
    /// shape here is `withCompletedTurn`'s, already swept. What is new is the
    /// *provenance*, and provenance is exactly what a corpus fixture drops.
    @Test("a real generation writes the log a hand-written fixture spells")
    func logIsByteStable() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let fixture = try StoreUnderTest(deltaFlush: Self.oneRow)
        let convo = try await fixture.store.createConversation()

        _ = try await fixture.store.send("Explain valley folds", in: convo.id, using: driver("A valley fold"))

        var expected = Log.opened()
        expected.append(.userMessageAppended(message: firstUser, content: "Explain valley folds", parent: nil))
        expected.append(.generationStarted(
            generation: Fix.genA, message: firstAssistant, parent: firstUser, model: descriptor
        ))
        expected.append(.deltaAppended(generation: Fix.genA, text: "A valley fold"))

        // The terminal carries usage the framework computed, so it is compared
        // structurally rather than against a literal — everything *before* it is
        // byte-for-byte.
        #expect(fixture.written.dropLast() == expected.records)
        guard case .generationEnded(_, .completed) = fixture.written.last?.payload else {
            Issue.record("expected a completed terminal, got \(String(describing: fixture.written.last?.payload))")
            return
        }
    }

    // MARK: - Cancellation chaos, with a real session in the loop (§10.4)

    /// **`Cue` used as designed, which is what M5 could not do.** Its `park()` is
    /// internal to `Understudy`, so the store-level double used a `Latch`; here
    /// the *player* parks and the test drives `reached()` / `signal()` from the
    /// outside — the arrangement the type was built for.
    ///
    /// Both stop mechanisms (§7.5), because they must reach the same place: the
    /// store's canonical `cancelGeneration`, and cancelling the `Task` awaiting
    /// the verb.
    @Test("cancelling at a parked point records exactly one .cancelled terminal", arguments: [true, false])
    func cancellationAtAParkedPoint(viaStore: Bool) async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let cue = Cue()
        let fixture = try StoreUnderTest(deltaFlush: Self.everyDelta)
        let convo = try await fixture.store.createConversation()
        let script: Script = ["half an ans", .wait(until: cue), "wer"]

        let running = Task { [store = fixture.store] in
            try await store.send("q", in: convo.id, using: driver(script))
        }
        // The generation is provably mid-flight and stopped — no sleep, no guess.
        await cue.reached()

        if viaStore {
            await fixture.store.cancelGeneration(in: convo.id)
        } else {
            running.cancel()
        }
        await cue.signal()

        #expect(try await running.value == .cancelled)

        let rows = try await fixture.rows(of: convo.id)
        let terminals = rows.compactMap { row -> Outcome? in
            guard case .decoded(let event) = row, case .generationEnded(_, let outcome) = event.payload
            else { return nil }
            return outcome
        }
        #expect(terminals == [.cancelled], "exactly one terminal, and it is the one that happened (I3)")

        // §7.5's partial retention, as the property rather than a fixed string:
        // whatever reached disk is a **prefix** of what the script would have
        // said. Phase 2 measured that the framework may not have vended a
        // snapshot at all by the time a stop lands, so the honest assertion is
        // the prefix, not a count.
        let partial = answer(in: try await fixture.store.conversation(convo.id)) ?? ""
        #expect("half an answer".hasPrefix(partial), "partial was \(partial.debugDescription)")

        let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")
    }

    /// A stop *before* anything streams — the earliest point the pipeline has —
    /// still records a terminal rather than leaving the generation open.
    @Test("cancelling before the first fragment still records .cancelled")
    func cancellationBeforeAnyText() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let cue = Cue()
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()

        let running = Task { [store = fixture.store] in
            try await store.send("q", in: convo.id, using: driver([.wait(until: cue), "never seen"]))
        }
        await cue.reached()
        await fixture.store.cancelGeneration(in: convo.id)
        await cue.signal()

        #expect(try await running.value == .cancelled)
        #expect(answer(in: try await fixture.store.conversation(convo.id)) == "")

        let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")
    }

    // MARK: - Failure, through the whole stack

    /// §7.2's straddle at pipeline scale: the provider fails, and the *verb* does
    /// not throw — the failure lands in the ledger, classified, where a UI can
    /// render an affordance for it.
    @Test("a provider failure becomes a recorded, classified outcome")
    func providerFailureIsRecorded() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()

        let outcome = try await fixture.store.send(
            "q", in: convo.id, using: driver([.fail(URLError(.notConnectedToInternet))])
        )

        #expect(outcome == .failed(.transport(.connectivity)))

        // The whole point of §7.2: the app reads an affordance off the message,
        // not off a thrown error it never saw.
        let message = try #require(try await fixture.store.conversation(convo.id).activeMessages.last)
        #expect(message.state == .failed(
            partial: "", error: .transport(.connectivity), recoverability: .retryable(after: nil)
        ))
    }

    // MARK: - Tool records, all the way to the ledger (§7.6)

    /// **The last unexercised obligation in §7.** The framework runs the tool
    /// inside the session, the driver observes the exchange in
    /// `transcriptEntries`, the store writes a `toolInvocationRecorded` event,
    /// and the reducer projects it onto the assistant message — four layers, one
    /// invocation.
    ///
    /// Also pins §7.4's ordering rule from the outside: a tool record forces the
    /// delta buffer out ahead of itself, so the log can never claim the tool ran
    /// before text that preceded it.
    @Test("a tool invocation reaches the assistant message as an audit record")
    func toolRecordsReachTheLedger() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let fixture = try StoreUnderTest(deltaFlush: Self.everyDelta)
        let convo = try await fixture.store.createConversation()
        let driver = GenerationDriver(
            model: ScriptedLanguageModel(
                scripts: [
                    [.callTool("StubTool", arguments: #"{"value":"valley"}"#)],
                    ["The fold is a valley fold."],
                ],
                capabilities: LanguageModelCapabilities([.toolCalling])
            ),
            descriptor: descriptor,
            tools: [StubTool()]
        )

        _ = try await fixture.store.send("which fold?", in: convo.id, using: driver)

        let message = try #require(try await fixture.store.conversation(convo.id).activeMessages.last)
        #expect(message.toolRecords.map(\.name) == ["StubTool"])
        #expect(message.toolRecords.first?.status == .succeeded)
        #expect(message.state == .complete(MessageContent(text: "The fold is a valley fold.")))

        let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")
    }

    // MARK: - §11's sketch, against the real driver

    /// **DoD-2's groundwork.** The any-Mac sketch runs against a store double;
    /// this is the same shape against the real thing, so the one line a provider
    /// swap changes is the one line this test constructs.
    @Test("the §11 sketch runs end-to-end against a real session")
    func sketchRunsAgainstTheRealDriver() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        try await fixture.store.setInstructions("You are an origami tutor.", in: convo.id)

        // The provider-swap line, and nothing else in this test knows which
        // provider it is.
        let driver = driver("A valley fold is a fold toward you.")

        _ = try await fixture.store.send("Explain valley folds", in: convo.id, using: driver)
        let user = try #require(try await fixture.store.conversation(convo.id).activeMessages.first)
        let replacement = try await fixture.store.edit(user.id, content: "Explain mountain folds", in: convo.id)
        _ = try await fixture.store.respond(to: replacement, in: convo.id, using: driver)
        let assistant = try #require(try await fixture.store.conversation(convo.id).activeMessages.last)
        _ = try await fixture.store.regenerate(assistant.id, in: convo.id, using: driver)
        try await fixture.store.switchBranch(to: replacement, in: convo.id)

        let problems = try await healthyLogProblems(convo.id, in: fixture.store, backedBy: fixture.backing)
        #expect(problems.isEmpty, "\(problems)")
    }
}

// MARK: -

private extension MessageState {

    /// The text a message is showing, whatever state it is in — the read side of
    /// §7.1's "what the user saw".
    var partialOrComplete: String {
        switch self {
        case .complete(let content): content.text
        case .streaming(let partial): partial
        case .interrupted(let partial): partial
        case .cancelled(let partial): partial
        case .failed(let partial, _, _): partial
        }
    }
}

import Foundation
import FoundationModels
import Testing
import Understudy
@testable import LedgerKit

// M6 Phase 2: the one production `GenerationDriving` conformance, driven through
// a **real `LanguageModelSession`** by a scripted provider.
//
// Tier 2 throughout — `LanguageModel` is 27-only — so these skip on the macOS 26
// host and execute on the iOS 27 simulator (M6-PLAN D36). The pipeline under
// test is the whole of §7.3's round trip minus the store:
//
//     script fragments → ScriptedLanguageModel → framework accumulation
//         → ResponseStream snapshots → the differ → GenerationSignal.delta
//
// **This is also the first `Understudy` import** (D37), pulled forward from
// Phase 3 for the unavoidable reason that a driver cannot be tested without a
// model, and a throwaway one written here would be the internal imitation M3's
// D11 retired.

/// Collects what a driver emitted, since `GenerationChannel` is write-only by
/// design — the store owns the reading half.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
private func collect(
    from driver: GenerationDriver,
    _ request: GenerationRequest
) async -> (signals: [GenerationSignal], outcome: Outcome) {
    let (stream, channel) = GenerationChannel.makeStream()
    async let collected = { () async -> [GenerationSignal] in
        var received: [GenerationSignal] = []
        for await signal in stream { received.append(signal) }
        return received
    }()

    let outcome = await driver.generate(request, streamingInto: channel)
    channel.finish()
    return (await collected, outcome)
}

/// The text a run of deltas reconstructs — what the store would have written.
private func text(of signals: [GenerationSignal]) -> String {
    signals.reduce(into: "") { accumulated, signal in
        if case .delta(let text) = signal { accumulated += text }
    }
}

@Suite("Session — GenerationDriver", .enabled(if: foundationModelsAvailable), .timeLimit(.minutes(1)))
struct GenerationDriverTests {

    /// A request whose active path ends in a user message — the shape every
    /// store verb produces (§6.5's eligibility).
    ///
    /// Built by *reducing a log* rather than by hand, because `Message` cannot be
    /// hand-built (M4 Phase 0) and should not be: reducing exercises the real
    /// semantics, and a request assembled any other way would be asserting
    /// against a fiction.
    private func request(instructions: String? = nil) -> GenerationRequest {
        let log = Log.withUserMessage()
        return GenerationRequest(
            conversation: log.conversation,
            instructions: instructions,
            context: log.reduced().activeMessages
        )
    }

    private var descriptor: ModelDescriptor {
        ModelDescriptor(provider: "understudy", model: "scripted")
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func driver(
        _ script: Script,
        toolRecording: ToolRecordingPolicy = .metadataOnly
    ) -> GenerationDriver {
        GenerationDriver(
            model: ScriptedLanguageModel(script: script),
            descriptor: descriptor,
            toolRecording: toolRecording
        )
    }

    // MARK: - The happy path

    /// **§7.3's round trip, end to end — with one correction the substrate
    /// forced.**
    ///
    /// The script emits *deltas*, the framework accumulates them into cumulative
    /// snapshots, and the driver subtracts them back. §7.3 (and M5 handoff 3)
    /// state the recovered result as "exactly the fragments the script emitted",
    /// and that is **not** what happens: the framework's snapshot cadence is its
    /// own, so three fragments emitted back-to-back arrive as one snapshot and
    /// therefore one delta. Pacing the script produces more.
    ///
    /// What survives exactly is the **text**, which is the property the ledger
    /// actually needs — message content is the concatenation of `deltaAppended`
    /// rows, and where the boundaries fall is a durability detail the flush
    /// policy already reshapes (§7.4). Asserting fragment boundaries would pin
    /// the framework's buffering, which is not LedgerKit's to pin. Recorded for
    /// rev 9.
    @Test("scripted text survives accumulation and diffing unchanged")
    func fragmentsRoundTrip() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let fragments = ["A valley fold ", "brings the paper ", "down."]

        let result = await collect(from: driver(Script(fragments.map { .emit($0) })), request())

        #expect(text(of: result.signals) == fragments.joined())
        guard case .completed = result.outcome else {
            Issue.record("expected completion, got \(result.outcome)")
            return
        }
    }

    /// The descriptor is the app's, verbatim: nothing in the framework carries
    /// model identity (OQ8), so the store copies what it is given.
    @Test("the requested descriptor is the one supplied at init")
    func descriptorIsAppSupplied() async {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        #expect(driver("hello").model == descriptor)
    }

    /// §7.7's mapping, 1:1 and total.
    ///
    /// ⚠️ **The output side is asserted loosely on purpose.** The framework does
    /// not pass a provider's usage through untouched — it *augments* it, adding
    /// its own per-fragment output accounting on top of what the provider
    /// reported (measured: a script reporting 8 output tokens arrives as 9).
    /// The input side comes through verbatim, so that is where an exact
    /// assertion belongs. Asserting the scripted output number would be
    /// asserting the framework's internal accounting, which is not LedgerKit's
    /// to pin.
    @Test("reported usage lands in StopInfo, in the right slots")
    func usageIsCaptured() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let script: Script = [.reportUsage(input: 12, output: 8, cached: 3, reasoning: 2), "answer"]

        let result = await collect(from: driver(script), request())

        guard case .completed(let stop) = result.outcome else {
            Issue.record("expected completion, got \(result.outcome)")
            return
        }
        let usage = try #require(stop.usage)
        #expect(usage.inputTokens == 12)
        #expect(usage.cachedInputTokens == 3)
        #expect((usage.outputTokens ?? 0) >= 8, "the framework adds to what a provider reports")
        #expect(usage.reasoningTokens != nil)

        // §7.8: nil on-device, and never an error. The channel's metadata does
        // not reach `Usage.metadata` here, so both stay nil — which is exactly
        // what rev 8 says to expect, and why neither is treated as a gap.
        #expect(stop.resolvedModelID == nil)
        #expect(stop.stopReason == nil)
    }

    // MARK: - Rehydration (§7.1)

    /// The transcript the driver seeds is what the *model* sees, so asserting on
    /// the spy's recorded request is asserting on §7.1 itself.
    @Test("instructions and prior turns are materialized; the last user message becomes the prompt")
    func rehydrationSeedsTheSession() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let model = ScriptedLanguageModel(script: "ok")
        let driver = GenerationDriver(model: model, descriptor: descriptor)

        _ = await collect(from: driver, request(instructions: "You are an origami tutor."))

        let seen = try #require(model.requests.first)
        let entries = Array(seen.transcript)

        // Instructions **exact**, and first.
        guard case .instructions(let instructions) = entries.first else {
            Issue.record("expected the instructions entry first, got \(entries.first as Any)")
            return
        }
        #expect(instructions.segments.contains { segment in
            if case .text(let text) = segment { text.content == "You are an origami tutor." } else { false }
        })

        // **Exactly one prompt entry**, carrying the trailing user message.
        //
        // The framework appends the prompt to the transcript before handing it
        // to the executor, so what the provider receives is history *plus* the
        // current turn. That is what makes the count the interesting assertion:
        // one means the driver seeded history and let the framework add the
        // prompt; two would mean it had put the parent in both places and shown
        // the model its own question twice.
        let prompts = entries.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { segment in
                if case .text(let text) = segment { text.content } else { nil }
            }.joined()
        }
        #expect(prompts == ["Explain valley folds"])
    }

    /// §7.1's fidelity classes: what the user saw is what the model sees,
    /// **including partials**.
    @Test("a partial on the path contributes its text")
    func partialsAreRehydrated() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        var log = Log.withUserMessage()
        // An assistant turn that streamed and was interrupted, then a new user
        // message under it — the shape a crash-and-continue produces.
        let generation = Fix.genA
        let assistant = Fix.assistantA
        _ = log.append(.generationStarted(
            generation: generation, message: assistant, parent: Fix.userA, model: Fix.model
        ))
        _ = log.append(.deltaAppended(generation: generation, text: "half an ans"))
        let followUp = Fix.userB
        _ = log.append(.userMessageAppended(message: followUp, content: "carry on", parent: assistant))

        let model = ScriptedLanguageModel(script: "ok")
        let driver = GenerationDriver(model: model, descriptor: descriptor)
        _ = await collect(
            from: driver,
            GenerationRequest(conversation: log.conversation, instructions: nil, context: log.reduced().activeMessages)
        )

        let entries = Array(try #require(model.requests.first).transcript)
        let responses = entries.compactMap { entry -> String? in
            guard case .response(let response) = entry else { return nil }
            return response.segments.compactMap { segment in
                if case .text(let text) = segment { text.content } else { nil }
            }.joined()
        }
        #expect(responses == ["half an ans"], "the interrupted partial must reach the model")
    }

    /// The seam's contract, violated: a request that ends in an assistant
    /// message has nothing to prompt with. The v0.1 store cannot produce it,
    /// which is exactly why it is a *driver* diagnostic rather than a provider
    /// condition.
    @Test("a request with no trailing user message fails loudly")
    func requestWithoutAPromptFails() async {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let log = Log.withCompletedTurn()   // ends with the assistant's answer
        let request = GenerationRequest(
            conversation: log.conversation,
            instructions: nil,
            context: log.reduced().activeMessages
        )

        let result = await collect(from: driver("unreachable"), request)

        #expect(result.outcome == .failed(DriverDiagnostic.requestWithoutPrompt.error))
        #expect(result.signals.isEmpty, "nothing may be emitted for a request that never ran")
    }

    // MARK: - §7.3's fail-loud path

    /// **OQ4's residue, answered — and the answer is that a consumer never sees
    /// it.**
    ///
    /// `replaceTextSegment` is legal provider behaviour, so §7.3 has a fail-loud
    /// path for the non-prefix snapshot it could produce. M6 Phase 1.5 gave
    /// `Understudy` a `.revise` step specifically so that path could be driven
    /// end to end — and then it could not be. Across six probe runs at three
    /// pacings (none, 60 ms, 600 ms between the append and the revision), **the
    /// consumer never observed the pre-revision text**: every snapshot already
    /// carried the revised value.
    ///
    /// So the accumulated sequence stayed prefix-stable *even though the provider
    /// revised*, and the driver completed normally with the final text. That is
    /// this test's assertion, because asserting the fail-loud path here would be
    /// asserting a behaviour the substrate cannot produce.
    ///
    /// **What this does and does not settle.** The differ's refusal is proved
    /// exhaustively at tier 1 (`SnapshotDiffTests`), so the *logic* is covered;
    /// what is unproven is the driver's wiring of that verdict to a terminal,
    /// and it is unproven because nothing here can reach it. §7.3's path
    /// therefore stays as insurance — which is what rev 7 called it — and a real
    /// provider on device (Phase 4) is the only thing that could change the
    /// answer.
    @Test("a provider revision is invisible to the consumer, so the stream stays prefix-stable")
    func revisionIsNotObservable() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let script: Script = [
            .emit("The answer is 41", segmentID: "answer"),
            .wait(.milliseconds(60)),
            .revise("The answer is 42", segmentID: "answer"),
        ]

        let result = await collect(from: driver(script), request())

        #expect(text(of: result.signals) == "The answer is 42")
        guard case .completed = result.outcome else {
            Issue.record("expected completion — the revision was never observable, got \(result.outcome)")
            return
        }
    }

    // MARK: - The outcome boundary (§7.2)

    /// Every failure after the store's start append is an `Outcome`, never a
    /// throw — which is what makes §8's reauth bubble reachable through
    /// observation.
    @Test("a provider error becomes a failed outcome, normalized")
    func providerErrorsAreOutcomes() async {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let script: Script = [.fail(URLError(.timedOut))]

        let result = await collect(from: driver(script), request())

        #expect(result.outcome == .failed(.transport(.timeout)))
    }

    /// A zero-token failure: the request never produced a fragment, so the
    /// message is `.failed(partial: "")` store-side — an empty failed bubble
    /// showing *how to recover* is the feature, not an artifact.
    @Test("a request-time failure emits nothing and still returns a terminal")
    func zeroTokenFailure() async {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let result = await collect(from: driver([.fail(URLError(.notConnectedToInternet))]), request())

        #expect(result.signals.isEmpty)
        #expect(result.outcome == .failed(.transport(.connectivity)))
    }

    // MARK: - Cancellation (§7.5)

    /// Parked at a point the *test* chose, then cancelled — `Cue` used as
    /// designed, which is what M5 could not do (its `park()` is internal to
    /// `Understudy`, so the store-level double used a `Latch` instead).
    @Test("cancellation returns .cancelled and keeps what was already emitted")
    func cancellationReturnsAndRetains() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let cue = Cue()
        let script: Script = ["half an ans", .wait(until: cue), "wer"]
        let driver = GenerationDriver(model: ScriptedLanguageModel(script: script), descriptor: descriptor)

        let (stream, channel) = GenerationChannel.makeStream()
        async let collected = { () async -> [GenerationSignal] in
            var received: [GenerationSignal] = []
            for await signal in stream { received.append(signal) }
            return received
        }()

        let running = Task { await driver.generate(request(), streamingInto: channel) }
        await cue.reached()
        running.cancel()

        let outcome = await running.value
        channel.finish()

        // **The bug this test found.** `ResponseStream` ends *silently* when its
        // consumer is cancelled — no throw, no snapshots — so the first draft of
        // the driver fell out of its loop and returned `.completed`, recording a
        // *successful* terminal for a generation the user stopped. §7.5 exists to
        // keep cancelled, failed and interrupted distinct; that would have
        // collapsed the first into the happiest of the three.
        #expect(outcome == .cancelled)

        // §7.5's partial retention, asserted as the property rather than as a
        // fixed string: whatever reached the channel is a **prefix** of what the
        // script would have said. Often that is empty here — the framework had
        // not vended its first snapshot when the stop arrived — and that is
        // correct rather than lossy, since the store records what it received and
        // the message reads `.cancelled(partial: "")`.
        let emitted = text(of: await collected)
        #expect("half an answer".hasPrefix(emitted), "emitted \(emitted.debugDescription)")
    }
}

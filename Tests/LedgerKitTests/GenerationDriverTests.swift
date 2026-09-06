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

    /// **§7.3's round trip, end to end.**
    ///
    /// The script emits *deltas*, the framework accumulates them into cumulative
    /// snapshots, and the driver subtracts them back. What survives exactly is
    /// the **text** — not the fragment boundaries, which the framework's own
    /// snapshot cadence decides: three fragments emitted back-to-back arrive as
    /// one snapshot and therefore one delta, and only pacing the script produces
    /// more.
    ///
    /// Text is the property the ledger actually needs — message content is the
    /// concatenation of `deltaAppended` rows, and where the boundaries fall is a
    /// durability detail §7.4's flush policy already reshapes. Asserting
    /// fragment boundaries would pin the framework's buffering, which is not
    /// LedgerKit's to pin.
    ///
    /// (Rev 9 amended §7.3 to state the property this way; earlier revisions
    /// promised fragment-level recovery, which was true of the test double and
    /// false of the framework it stands for. Paraphrased rather than quoted, so
    /// the retired-phrase sweep does not re-report a site that is already fixed
    /// — M6-PLAN Phase 0's finding.)
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

    // MARK: - Tool records (§7.6)

    /// A model that will ask for `StubTool`, then answer once it has run.
    ///
    /// **Two scripts, because a tool call ends the model's turn**: the framework
    /// executes the tool, appends its output to the transcript, and asks the
    /// model again. And `capabilities` must declare `.toolCalling` — the
    /// framework checks, and refuses with "the selected model does not support
    /// tool calling" otherwise. `ScriptedLanguageModel` declares nothing by
    /// default, deliberately ("a double should not promise capabilities it has no
    /// way to honour"), so this is the first place that default has bitten.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func toolUsingDriver(_ policy: ToolRecordingPolicy) -> GenerationDriver {
        GenerationDriver(
            model: ScriptedLanguageModel(
                scripts: [
                    [.callTool("StubTool", arguments: #"{"value":"valley"}"#)],
                    ["The fold is a valley fold."],
                ],
                capabilities: LanguageModelCapabilities([.toolCalling])
            ),
            descriptor: descriptor,
            tools: [StubTool()],
            toolRecording: policy
        )
    }

    /// **Record, don't orchestrate** (§7.6). The framework runs the tool inside
    /// the session; the driver only watches `transcriptEntries` go by and emits
    /// one record per *completed* invocation.
    @Test("a completed tool invocation crosses the seam as one record")
    func toolInvocationsAreRecorded() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let result = await collect(from: toolUsingDriver(.metadataOnly), request())

        let records = result.signals.compactMap { signal -> ToolRecord? in
            if case .toolRecord(let record) = signal { record } else { nil }
        }
        #expect(records.count == 1, "one record per invocation, not one per snapshot")
        let record = try #require(records.first)
        #expect(record.name == "StubTool")
        #expect(record.status == .succeeded)
        // Measured by the driver from its own observation — the framework
        // reports no timing — so it exists but is deliberately not asserted to a
        // value.
        #expect(record.duration != nil)

        // The default policy keeps the *content* out of the ledger (§7.6's
        // privacy rationale): tool results routinely carry fetched data, and the
        // ledger outlives the session.
        #expect(record.argumentsJSON == nil)
        #expect(record.resultJSON == nil)

        // And the generation still ends normally, with the answer the model gave
        // after the tool ran.
        #expect(text(of: result.signals) == "The fold is a valley fold.")
    }

    /// `.full` is opt-in precisely because these two fields are the ones that
    /// carry fetched content into a durable log.
    @Test("full recording adds arguments and result; off records nothing")
    func toolRecordingPolicyIsHonoured() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        let full = await collect(from: toolUsingDriver(.full), request())
        let recorded = try #require(full.signals.compactMap { signal -> ToolRecord? in
            if case .toolRecord(let record) = signal { record } else { nil }
        }.first)
        #expect(recorded.argumentsJSON?.contains("valley") == true)
        #expect(recorded.resultJSON == "valley", "the stub tool echoes its argument")

        let off = await collect(from: toolUsingDriver(.off), request())
        #expect(!off.signals.contains { if case .toolRecord = $0 { true } else { false } })
        // The tool still *ran* — `.off` changes the ledger, never the generation.
        #expect(text(of: off.signals) == "The fold is a valley fold.")
    }

    /// **A2, and the audit's characterisation of it needs correcting** (M7 Phase 0,
    /// measured).
    ///
    /// The audit called this a data-fidelity bug on the grounds that
    /// `argumentsJSON` held `String(describing:)` of a `GeneratedContent` — "a debug
    /// description". The first half is literally right: `GeneratedContent` conforms
    /// to `CustomDebugStringConvertible` and **not** `CustomStringConvertible`, so
    /// `String(describing:)` resolves to `debugDescription`. The implied half —
    /// that the field therefore held something unparseable — is **false**. Apple's
    /// debug rendering emits JSON, so a test asserting the value merely parses
    /// passes against the bug. That is why this test asserts something else.
    ///
    /// **The real defect is byte instability, and it is the I1 hazard arriving
    /// through Apple's API.** `debugDescription` renders an object's keys in
    /// *dictionary order*, so the same tool arguments recorded twice produce
    /// different bytes — measured directly: three processes, three orderings
    /// (`{"arr":…,"s":…}`, `{"b":…,"s":…}`, `{"n":…,"s":…}`). Swift's hasher seed
    /// varies per process, which is exactly the leak `Reduce/` is forbidden from
    /// and which nothing stopped at this layer. In an append-only audit log that is
    /// worse than unparseable text: it is a record that silently disagrees with
    /// itself across launches. `jsonString` preserves declaration order and was
    /// stable across the same three runs.
    ///
    /// Driven through ``ToolObservation`` directly rather than a scripted session:
    /// order needs several keys, `Transcript.ToolCall`/`ToolCalls` are publicly
    /// constructible (OQ2's closure), and the choice under test is this type's.
    @Test("argumentsJSON preserves declaration order, so a record cannot disagree with itself")
    func argumentsAreOrderStableJSON() throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        // Four keys, because two could agree by luck and one cannot disagree at all.
        let arguments = GeneratedContent(properties: [
            "alpha": "1", "beta": "2", "gamma": "3", "delta": "4",
        ])
        var observation = ToolObservation(policy: .full)
        let entries: [Transcript.Entry] = [
            .toolCalls(Transcript.ToolCalls([
                Transcript.ToolCall(id: "call-1", toolName: "StubTool", arguments: arguments),
            ])),
            .toolOutput(Transcript.ToolOutput(
                id: "call-1",
                toolName: "StubTool",
                segments: [.text(Transcript.TextSegment(content: "ok"))]
            )),
        ]

        let json = try #require(observation.records(in: entries[...]).first?.argumentsJSON)

        // Keys in the order they appear, which is the property that must be
        // deterministic. Scanned rather than parsed because `JSONSerialization`
        // discards order — and asserting Apple's exact spacing would pin a
        // formatting choice that is not LedgerKit's to pin.
        let keys = json.matches(of: /"([a-z]+)":/).map { String($0.1) }
        #expect(keys == ["alpha", "beta", "gamma", "delta"])
    }

    /// A model that asks for a tool which **throws**.
    ///
    /// One script, not two: the tool's throw ends the generation, so the model is
    /// never asked again (which is itself the reason §7.6's success path cannot
    /// observe a failure — an output entry only exists when there was an output).
    ///
    /// - Parameter afterText: Text the model emits *before* calling the tool.
    ///   Not decoration — it decides whether the driver ever sees the call, which
    ///   is measured by the two tests below.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func failingToolDriver(
        _ policy: ToolRecordingPolicy,
        afterText text: String? = nil
    ) -> GenerationDriver {
        let call = Script.Step.callTool("FailingTool", arguments: #"{"value":"valley"}"#)
        return GenerationDriver(
            model: ScriptedLanguageModel(
                scripts: [Script(text.map { [.emit($0), call] } ?? [call])],
                capabilities: LanguageModelCapabilities([.toolCalling])
            ),
            descriptor: descriptor,
            tools: [FailingTool()],
            toolRecording: policy
        )
    }

    /// **A1 — §8's "two facts, two events", asserted as two events** (M7 Phase 0).
    ///
    /// The claim §8 makes and M6 did not implement: unwrapping a `ToolCallError`
    /// loses nothing *because* the tool's identity has its own channel. It did not
    /// — `ToolObservation` emitted only on `toolOutput`, which exists only when the
    /// tool produced one, so `ToolRecord.Status.failed` was wire surface no code
    /// could reach and a failed invocation left no trace at all.
    ///
    /// Both facts are asserted here on purpose. Either alone is satisfiable by a
    /// wrong implementation: recording the tool without unwrapping gives the user
    /// an opaque terminal, and unwrapping without recording loses which tool failed.
    @Test("a failed tool invocation is recorded, and the terminal carries the unwrapped error")
    func failedToolInvocationIsRecorded() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let result = await collect(from: failingToolDriver(.metadataOnly, afterText: "thinking… "), request())

        let records = result.signals.compactMap { signal -> ToolRecord? in
            if case .toolRecord(let record) = signal { record } else { nil }
        }
        #expect(records.count == 1, "one record for the one invocation that failed")
        let record = try #require(records.first)
        #expect(record.name == "FailingTool")
        #expect(record.status == .failed)
        // `.metadataOnly` — no payloads. And `resultJSON` is nil under *every*
        // policy: the tool threw instead of producing a result.
        #expect(record.argumentsJSON == nil)
        #expect(record.resultJSON == nil)

        // **Attributed**, because the preceding text produced a snapshot whose
        // `transcriptEntries` carried the `toolCalls` entry — see the sibling test
        // for the case where it does not. Not asserted to a value (it is a real
        // measurement), but asserted to be **canonical**: ADR-001 R-5 governs this
        // field, and a `ContinuousClock` measurement arrives at nanosecond
        // precision where the wire form is integer milliseconds.
        let duration = try #require(record.duration)
        #expect(duration == Duration(wireMilliseconds: duration.wireMilliseconds),
                "a duration that does not survive its own encoding means one thing in the store's cache and another on disk")

        // Fact two: the terminal is classified on what the tool threw, not on the
        // wrapper. `transport(.timeout)` classifies `retryable`, which is the
        // affordance §8 says a timed-out tool call must give the user.
        #expect(result.outcome == .failed(.transport(.timeout)))

        // The same attribution carries the arguments under `.full` — the only way
        // a *failed* record can ever hold a payload, so without this the field
        // would be unreachable on this path and nothing would notice.
        let full = await collect(from: failingToolDriver(.full, afterText: "thinking… "), request())
        let recorded = try #require(full.signals.compactMap { signal -> ToolRecord? in
            if case .toolRecord(let record) = signal { record } else { nil }
        }.first)
        let json = try #require(recorded.argumentsJSON)
        #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] == ["value": "valley"])
    }

    /// **The record lands even when nothing about the call was observed** — A1's
    /// actual claim, and the shape a real failure most often takes.
    ///
    /// Measured (M7 Phase 0): when the tool call is the model's **first** action,
    /// the driver receives *no snapshot at all* before the throw, so it never sees
    /// a `toolCalls` entry and has nothing to attribute a duration or arguments to.
    /// The framework reports the failure as a thrown error and the call itself is
    /// never surfaced as data.
    ///
    /// So the identity comes from the error's own `tool`, and the timing is `nil` —
    /// "not reported", the rule everywhere else in this package. The alternative
    /// would be recording no event at all, which is the bug A1 fixes, or inventing
    /// a duration, which would be read as fact for the life of the log.
    @Test("an unobserved failed call still reaches the ledger, without a fabricated duration")
    func unobservedFailedCallIsStillRecorded() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        // `.full` deliberately: even the policy that wants payloads gets none,
        // because there was nothing to capture them from.
        let result = await collect(from: failingToolDriver(.full), request())

        let records = result.signals.compactMap { signal -> ToolRecord? in
            if case .toolRecord(let record) = signal { record } else { nil }
        }
        let record = try #require(records.first, "a failed invocation must leave a trace even unobserved")
        #expect(record.name == "FailingTool", "the error names the tool, which is enough")
        #expect(record.status == .failed)
        #expect(record.duration == nil)
        #expect(record.argumentsJSON == nil)
        #expect(result.outcome == .failed(.transport(.timeout)))
    }

    /// **A4's reachable half** (M7 Phase 0).
    ///
    /// A provider throwing a `CancellationError` it wrapped itself, while the task
    /// is **not** cancelled, is a failure — not a user's stop. The check A4 added
    /// keys on `Task.isCancelled` rather than on the error's type for exactly this
    /// reason: the error says nothing reliable about who wanted the stop.
    ///
    /// ⚠️ **Honest limit, recorded rather than glossed** (§7.3's precedent for
    /// unreachable-but-retained paths): the *cancelled* side of that check may be
    /// unreachable end-to-end, because a cancelled `ResponseStream` ends silently
    /// before any error escapes — which is the measurement that put the
    /// post-loop `Task.isCancelled` check in `stream` in the first place. So the
    /// check is defence in depth against a provider that behaves differently, and
    /// what is testable is that it does not fire when it should not.
    @Test("a wrapped CancellationError from an uncancelled task is a failure, not a stop")
    func spuriousCancellationIsNotAStop() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let wrapped = LanguageModelSession.ToolCallError(tool: StubTool(), underlyingError: CancellationError())

        let result = await collect(from: driver([.fail(wrapped)]), request())

        #expect(result.outcome != .cancelled, "nobody cancelled this; recording a stop would be a lie")
        // Unwrapped to a bare `CancellationError`, which belongs to no Apple
        // family and no `URLError` bucket, so it lands on §8's floor. The case is
        // the contract; the wording is not (ADR-001).
        guard case .failed(.unrecognized) = result.outcome else {
            Issue.record("expected the floor, got \(result.outcome)")
            return
        }
        // And it is still a tool failure, so the record lands too — A1 and A4
        // compose rather than competing.
        let records = result.signals.compactMap { signal -> ToolRecord? in
            if case .toolRecord(let record) = signal { record } else { nil }
        }
        #expect(records.map(\.status) == [.failed])
        #expect(records.first?.name == "StubTool")
        // Unattributable: no `toolCalls` entry was ever observed, since this error
        // is injected rather than produced by a real invocation. Nil is "not
        // reported", which is the rule everywhere else in this package.
        #expect(records.first?.duration == nil)
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


import Foundation
import FoundationModels

/// Runs generations against a real `LanguageModelSession` — **the one OS-coupled
/// type in LedgerKit** (SPEC §7).
///
/// ```swift
/// let driver = GenerationDriver(model: SystemLanguageModel.default)
/// let outcome = try await store.send("Explain valley folds", in: convo.id, using: driver)
/// ```
///
/// Everything beta-fragile lives here and nowhere else, which is the whole point
/// of §7's shape: `Core/`, `Reduce/` and `Store/` are pure Swift that verifies on
/// any Mac, and this file is the corner that re-opens each beta.
///
/// ## What it owns, and what it does not
///
/// §7.9's table, from this side: the driver rehydrates a session (§7.1), diffs
/// snapshots into deltas (§7.3), normalizes thrown errors (§8), gates on
/// `isResponding` (§7.2), and observes tool invocations (§7.6). It **never**
/// writes: the store owns every append, the flush cadence, the live set, and the
/// terminal. A driver produces signals and one `Outcome`.
///
/// ## Sessions are cattle (D33)
///
/// Every generation materializes a **fresh** session from the request. §7.1's
/// ownership rule says discard-and-rebuild is always legal, and correctness never
/// depends on reuse — so v0.1 takes the shape that cannot be wrong, and sidesteps
/// cache invalidation entirely. There is no cache to leave stale when a
/// conversation is deleted, and §7.8's cardinality rule ("never one session
/// shared across conversations") is satisfied because a session is never shared
/// at all. A per-conversation reuse cache is a KV-cache optimization the spec
/// explicitly declines to depend on; if it ever lands it must carry its own
/// validity rule.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public actor GenerationDriver: GenerationDriving {

    /// The **requested** descriptor (§7.8), copied by the store onto
    /// `generationStarted`.
    ///
    /// `nonisolated let` because it is fixed at init and the store reads it
    /// synchronously — a descriptor that could change between the store reading
    /// it and the generation running would put a lie in the ledger.
    public nonisolated let model: ModelDescriptor

    private let language: any LanguageModel
    private let tools: [any Tool]
    private let toolRecording: ToolRecordingPolicy
    /// Read only at normalization time, where §8 permits it — converting a
    /// `Retry-After` instant into a duration is a clock read that is legal here
    /// and forbidden in the reducer (I1).
    private let now: @Sendable () -> Date

    /// The general form: any model, and the descriptor **you** supply.
    ///
    /// OQ8 closed by reading the SDK: `LanguageModel` is two requirements wide —
    /// `capabilities` and an opaque `executorConfiguration` — with no
    /// model-identity key anywhere in the framework. There is nothing to derive
    /// a descriptor *from*, so asking is not a fallback; it is the only correct
    /// design (§7.8).
    ///
    /// - Parameters:
    ///   - model: The provider. On-device, Private Cloud Compute, a Claude
    ///     package, a Chat Completions server — LedgerKit contains zero
    ///     conditional code for any of them.
    ///   - descriptor: Provider/model/version as *configured*. Rides
    ///     `generationStarted`, so a branch comparison can say which model
    ///     produced which sibling.
    ///   - tools: Registered with the session. The framework executes them;
    ///     this driver only observes (§7.6).
    ///   - toolRecording: How much of each invocation reaches the ledger.
    public init(
        model: any LanguageModel,
        descriptor: ModelDescriptor,
        tools: [any Tool] = [],
        toolRecording: ToolRecordingPolicy = .metadataOnly
    ) {
        self.language = model
        self.model = descriptor
        self.tools = tools
        self.toolRecording = toolRecording
        self.now = { Date() }
    }

    /// The on-device convenience, and the **one** case where LedgerKit may
    /// supply the descriptor itself.
    ///
    /// Not a hole in OQ8's reasoning: identity is underivable from the
    /// *protocol*, but `SystemLanguageModel` is a concrete type whose provider
    /// and model are exactly what the type name says. `version` stays nil —
    /// which build of the on-device model answered is genuinely unknown, and
    /// nil means "not reported" where a guess would be a fabrication in an
    /// append-only log.
    ///
    /// This is what keeps §11's sketch line true (`GenerationDriver(model:
    /// SystemLanguageModel.default, toolRecording: .metadataOnly)`) while still
    /// forcing an explicit descriptor everywhere identity is unknowable.
    public init(
        model: SystemLanguageModel,
        descriptor: ModelDescriptor = ModelDescriptor(provider: "apple", model: "system"),
        tools: [any Tool] = [],
        toolRecording: ToolRecordingPolicy = .metadataOnly
    ) {
        self.init(
            model: model as any LanguageModel,
            descriptor: descriptor,
            tools: tools,
            toolRecording: toolRecording
        )
    }

    /// Test seam: an injectable clock, for the one place the driver reads one.
    init(
        model: any LanguageModel,
        descriptor: ModelDescriptor,
        tools: [any Tool] = [],
        toolRecording: ToolRecordingPolicy = .metadataOnly,
        now: @escaping @Sendable () -> Date
    ) {
        self.language = model
        self.model = descriptor
        self.tools = tools
        self.toolRecording = toolRecording
        self.now = now
    }

    /// Runs one generation (§7.2, §7.3, §7.5).
    ///
    /// **Never throws, and every path returns exactly one terminal.** The store
    /// appended `generationStarted` before this call, so from here "how it ended"
    /// has one channel: a returned `Outcome`. Cancellation returns `.cancelled`
    /// rather than throwing, which is what makes §11's documented deviation
    /// structural instead of merely documented.
    public func generate(_ request: GenerationRequest, streamingInto channel: GenerationChannel) async -> Outcome {
        guard let material = rehydrate(request) else {
            return .failed(DriverDiagnostic.requestWithoutPrompt.error)
        }

        let session = LanguageModelSession(model: language, tools: tools, transcript: material.transcript)

        // §7.2's defensive gate. **Unreachable while D33 rebuilds per
        // generation** — a session created three lines ago cannot be responding
        // — and kept anyway for the three reasons rev 7 gives: the deprecated 26
        // error family can still deliver the overloaded shape, a typed error is
        // only useful to a driver that checks for it, and §6.5's eventual
        // parallel-generation relaxation is exactly when store single-flight
        // stops covering for this. A busy session is a LedgerKit defect, never a
        // provider signal, so it takes the loud floor and never `.rateLimited`.
        guard !session.isResponding else {
            return .failed(DriverDiagnostic.sessionBusy.error)
        }

        return await stream(material.prompt, from: session, into: channel)
    }

    // MARK: - Streaming

    /// Consumes cumulative snapshots, emits deltas, and returns the terminal.
    private func stream(
        _ prompt: String,
        from session: LanguageModelSession,
        into channel: GenerationChannel
    ) async -> Outcome {
        var previous: StreamSnapshot?
        var segmentAware = false
        var usage: LanguageModelSession.Usage?
        var tools = ToolObservation(policy: toolRecording)

        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                // **The extraction mode is chosen once, on the first snapshot,
                // and never changes.** Segment-aware and flat views disagree
                // about what a segment is called, so switching mid-stream reads
                // as a segment being replaced — which the differ correctly
                // refuses. Flat is always *safe* and strictly less informative;
                // segment-aware is preferred wherever the entries exist (§7.3).
                if previous == nil {
                    segmentAware = !responseSegments(of: snapshot).isEmpty
                }
                let current = segmentAware
                    ? StreamSnapshot(segments: responseSegments(of: snapshot))
                    : .flat(snapshot.content)

                switch delta(from: previous ?? StreamSnapshot(), to: current) {
                case .appended(let text):
                    // An empty delta is a snapshot that repeated. Legal, and
                    // emitting it would write an empty row for nothing.
                    if !text.isEmpty { channel.emit(.delta(text)) }
                case .nonPrefix(let reason):
                    // §7.3's release behaviour: fail the generation rather than
                    // emit a reconstruction. A wrong transcript is worse than a
                    // dead one, and rev 7 made this a real path — a provider may
                    // legally revise a segment it already sent.
                    return .failed(DriverDiagnostic.nonPrefixSnapshot(reason).error)
                }
                previous = current

                for record in tools.records(in: snapshot.transcriptEntries) {
                    channel.emit(.toolRecord(record))
                }
                usage = snapshot.usage
            }
        } catch is CancellationError {
            // §7.5: wind down and *return* `.cancelled`. Everything emitted
            // before the stop has already crossed the channel, so partial
            // content is retained by construction rather than by effort — and
            // the driver performs no cleanup writes, which is what keeps it
            // clear of the wall M5 hit (a cancelled task cannot record its own
            // cancellation).
            //
            // ⚠️ **Not the path cancellation actually takes** — see the check
            // after the loop. Kept because a provider that *does* throw on
            // cancellation must land here rather than in the normalizing arm
            // below, where a user's stop would be recorded as a failure.
            return .cancelled
        } catch {
            // §7.2: every failure after the store's start append is an
            // `Outcome`, including a request-time one that produced no tokens.
            // Those land as `.failed(partial: "")` — an empty failed bubble that
            // shows *how to recover* is the feature.
            return .failed(normalize(error, since: now()))
        }

        // ⚠️ **`ResponseStream` ends *silently* when the consuming task is
        // cancelled — it does not throw.** Measured on the iOS 27 simulator
        // (M6-PLAN Phase 2's probe): a cancelled consumer's `for try await`
        // simply stops, with zero snapshots and no error.
        //
        // Without this check the driver would return `.completed` for a
        // generation the user stopped — the store would record a completed
        // terminal, and §7.5's whole point is that cancelled ≠ failed ≠
        // interrupted, three states with three different UI treatments. A stop
        // would silently become a success, which is the worst of the three
        // possible mistakes here.
        //
        // Checked *after* the loop rather than inside it: a natural completion
        // that races a cancellation should still report what actually happened,
        // and by this line the loop has already drained everything the provider
        // produced.
        if Task.isCancelled { return .cancelled }

        return .completed(stopInfo(from: usage))
    }

    /// The ordered text segments of a snapshot's response entries (§7.3).
    ///
    /// Non-text segments — structure, attachment, custom — are **ignored, not
    /// refused**: v0.1 records text deltas only (N11, OQ9), and a provider
    /// interleaving a reasoning segment has not misbehaved. Ignoring them costs
    /// nothing because the delta is a concatenation of text.
    private func responseSegments(
        of snapshot: LanguageModelSession.ResponseStream<String>.Snapshot
    ) -> [StreamSnapshot.Segment] {
        snapshot.transcriptEntries.flatMap { entry -> [StreamSnapshot.Segment] in
            guard case .response(let response) = entry else { return [] }
            return response.segments.compactMap { segment in
                guard case .text(let text) = segment else { return nil }
                return StreamSnapshot.Segment(id: text.id, text: text.content)
            }
        }
    }

    /// §7.7's mapping, 1:1 and total, plus §7.8's identity.
    ///
    /// **`stopReason` and `resolvedModelID` are nil on-device, and that is not a
    /// gap.** Rev 8 read the interface for a stop-reason surface and found none
    /// anywhere in the 27 SDK; `resolvedModelID` has the same standing. Both are
    /// per-provider conventions read from the usage metadata where a provider
    /// follows one, and **a nil must never read as a failure**.
    private func stopInfo(from usage: LanguageModelSession.Usage?) -> StopInfo {
        guard let usage else { return StopInfo() }
        return StopInfo(
            stopReason: usage.metadata["stopReason"] as? String,
            usage: TokenUsage(
                inputTokens: usage.input.totalTokenCount,
                outputTokens: usage.output.totalTokenCount,
                cachedInputTokens: usage.input.cachedTokenCount,
                reasoningTokens: usage.output.reasoningTokenCount
            ),
            resolvedModelID: usage.metadata["modelID"] as? String
        )
    }

    // MARK: - Rehydration (§7.1)

    /// Materializes the request into a seeded transcript plus the prompt the
    /// generation answers.
    ///
    /// **The split is the whole subtlety.** `Transcript` is history and
    /// `streamResponse(to:)` needs a prompt, so the trailing user message — the
    /// generation's parent, by §6.5's eligibility rule — becomes the prompt and
    /// everything before it becomes entries. Putting the parent in *both* would
    /// show the model its own question twice.
    ///
    /// Fidelity is §7.1's, exactly: instructions **exact**; prompt and response
    /// text exact **including partials**, because what the user saw is what the
    /// model sees; tool calls, tool outputs and reasoning **absent** (N11) — so a
    /// rebuilt session no longer sees prior tool results, which is owned in §7.1
    /// rather than discovered here.
    ///
    /// Returns nil when the request has no trailing user message. The v0.1 store
    /// cannot produce that — `respond` and `regenerate` both resolve to a user
    /// parent — so it is a driver-visible contract violation rather than a
    /// provider condition, and it takes the loud floor.
    private func rehydrate(_ request: GenerationRequest) -> (transcript: Transcript, prompt: String)? {
        guard let last = request.context.last, last.role == .user else { return nil }

        var entries: [Transcript.Entry] = []
        if let instructions = request.instructions {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                // A closure rather than `map(ToolDefinition.init(tool:))`: the
                // initializer is generic over `some Tool`, and a generic
                // function cannot be passed as a *value* with an existential
                // argument — but calling it opens `any Tool` implicitly, which
                // is the same mechanism that lets `LanguageModelSession` take
                // this driver's `any LanguageModel` (§7.8).
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            )))
        }
        for message in request.context.dropLast() {
            let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: message.visibleText))]
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant:
                entries.append(.response(Transcript.Response(segments: segments)))
            }
        }

        return (Transcript(entries: entries), last.visibleText)
    }
}

// MARK: - Tool observation (§7.6)

/// Pairs `toolCalls` with their `toolOutput`s as they land mid-stream, emitting
/// one ``ToolRecord`` per completed invocation.
///
/// **Record, don't orchestrate.** The framework executes tools inside the
/// session; this only watches. `transcriptEntries` is cumulative, so the same
/// call reappears in every later snapshot — hence the seen-set, without which a
/// long generation would write one tool record per snapshot.
///
/// The shape §7.6 already owns: one event *after* the invocation completes,
/// carrying its duration. Live "using tool…" UI is therefore a session concern
/// and not a ledger one — representable from this same signal, deliberately not
/// represented here.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
struct ToolObservation {

    let policy: ToolRecordingPolicy
    /// When each call was first *observed*. The framework reports no timing, so
    /// duration is measured from this side — honest about what it is, and
    /// monotonic because it is a `ContinuousClock`, not the wall clock a long
    /// generation might see adjusted.
    private var firstSeen: [String: ContinuousClock.Instant] = [:]
    private var arguments: [String: String] = [:]
    private var recorded: Set<String> = []

    init(policy: ToolRecordingPolicy) {
        self.policy = policy
    }

    /// Records for invocations that *completed* in this snapshot.
    mutating func records(in entries: ArraySlice<Transcript.Entry>) -> [ToolRecord] {
        guard policy.recordsInvocations else { return [] }

        var completed: [ToolRecord] = []
        for entry in entries {
            switch entry {
            case .toolCalls(let calls):
                for call in calls where firstSeen[call.id] == nil {
                    firstSeen[call.id] = .now
                    if policy.recordsPayloads {
                        arguments[call.id] = String(describing: call.arguments)
                    }
                }
            case .toolOutput(let output) where !recorded.contains(output.id):
                recorded.insert(output.id)
                completed.append(ToolRecord(
                    name: output.toolName,
                    // The framework surfaces no per-call status: a tool that
                    // threw becomes a `ToolCallError` on the *response*, which
                    // ends the generation rather than producing an output entry.
                    // An output entry therefore means it succeeded.
                    status: .succeeded,
                    // ⚠️ **Canonicalized at birth, for ADR-001 R-5's reason,
                    // in the field R-5 explicitly exempted.** Its scope note
                    // reasoned that durations need no canonicalization because
                    // they "arrive from §8's normalization already coarse — a
                    // tool duration is measured in ms". That was true while
                    // nothing *minted* one; this driver measures with a
                    // `ContinuousClock`, so the value arrives at nanosecond
                    // precision and does **not** survive its own encoding (the
                    // wire form is integer milliseconds, R-4).
                    //
                    // Left raw, a tool record means one thing in the store's
                    // fold-forward cache and another once it has been to disk —
                    // the two-identities bug R-5 exists to prevent, and the
                    // healthy-log property caught it here as "cached state
                    // disagrees with a re-read of the log".
                    duration: firstSeen[output.id].map { start in
                        let measured = ContinuousClock.now - start
                        return Duration(wireMilliseconds: measured.wireMilliseconds)
                    },
                    argumentsJSON: arguments[output.id],
                    resultJSON: policy.recordsPayloads ? outputText(output) : nil
                ))
            default:
                break
            }
        }
        return completed
    }

    private func outputText(_ output: Transcript.ToolOutput) -> String {
        output.segments.compactMap { segment in
            if case .text(let text) = segment { text.content } else { nil }
        }.joined()
    }
}

// MARK: -

extension Message {

    /// What the user saw, which is what the model should see (§7.1).
    ///
    /// Partials included deliberately: a `.failed`, `.cancelled` or
    /// `.interrupted` message the user kept on the path contributes its text.
    var visibleText: String {
        switch state {
        case .complete(let content): content.text
        case .streaming(let partial): partial
        case .interrupted(let partial): partial
        case .cancelled(let partial): partial
        case .failed(let partial, _, _): partial
        }
    }
}

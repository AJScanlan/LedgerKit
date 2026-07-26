import Foundation
import FoundationModels
import Synchronization

/// A `LanguageModel` that plays a ``Script`` instead of doing inference.
///
/// ```swift
/// let model = ScriptedLanguageModel(script: "A valley fold brings the paper down.")
/// let session = LanguageModelSession(model: model)
/// ```
///
/// Because the protocol is Apple's, this is a drop-in wherever a real model
/// goes: unit tests, SwiftUI previews, demo screenshots, and CI on any Mac —
/// **zero network, zero Apple Intelligence eligibility, zero non-determinism.**
/// Two runs of the same script produce the same fragments in the same order.
///
/// ## Which side of the stream this is on
///
/// A model is a *provider*, and providers write **deltas**: each ``Script/Step``
/// `.emit` becomes one `appendText` fragment. A *consumer* reading
/// `LanguageModelSession.ResponseStream` sees **cumulative** snapshots, because
/// the framework accumulates in between. So a script of `["A valley ", "fold"]`
/// is read by a consumer as the snapshots `"A valley "` then `"A valley fold"`.
/// Scripts are written the way a model speaks, not the way a reader listens.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public struct ScriptedLanguageModel: LanguageModel {

    public typealias Executor = ScriptedLanguageModelExecutor

    /// What this model claims to support. Empty by default — a double should
    /// not promise capabilities it has no way to honour. Set it when the code
    /// under test branches on `capabilities`.
    public var capabilities: LanguageModelCapabilities

    private let playbook: Playbook

    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(playbook: playbook)
    }

    /// A model that plays one script, then has nothing left to say.
    ///
    /// A bare string is a whole response, so the common case is
    /// `ScriptedLanguageModel(script: "the answer")`.
    public init(
        script: Script,
        capabilities: LanguageModelCapabilities = LanguageModelCapabilities([]),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(scripts: [script], capabilities: capabilities, clock: clock)
    }

    /// A model that plays each script in turn, one per request.
    ///
    /// There is deliberately no `init(replying:)` or `init(failingWith:)`
    /// sugar: `script: "text"` and `script: [.fail(error)]` already say those
    /// things, and a second spelling for the same idea is a permanent tax on
    /// everyone reading call sites. Conveniences are easy to add later and
    /// impossible to remove.
    public init(
        scripts: [Script],
        whenExhausted: ScriptExhaustion = .fail,
        capabilities: LanguageModelCapabilities = LanguageModelCapabilities([]),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.capabilities = capabilities
        self.playbook = Playbook(scripts: scripts, exhaustion: whenExhausted, clock: clock)
    }

    /// Every request this model has been asked to answer, in order — the spy
    /// half of the double.
    ///
    /// Read it to assert what the *caller* did: which transcript was
    /// materialized, which tools were offered, what generation options were
    /// set. Synchronous on purpose, so an assertion needs no `await`.
    public var requests: [LanguageModelExecutorGenerationRequest] {
        playbook.requests
    }

    /// How many responses have been requested so far.
    public var responseCount: Int {
        playbook.requests.count
    }
}

// MARK: - Executor

/// The executor half of ``ScriptedLanguageModel``. You never construct one —
/// the framework does, from ``Configuration``.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public struct ScriptedLanguageModelExecutor: LanguageModelExecutor {

    public typealias Model = ScriptedLanguageModel

    /// Carries the model's shared state to the executor the framework builds.
    ///
    /// `Hashable & Sendable` is Apple's requirement, and it is why the playbook
    /// travels **by reference**: the framework instantiates executors from this
    /// value, so anything the model and its executors must agree on — the
    /// script cursor, the recorded requests — cannot live in the value itself.
    /// Identity is therefore the playbook's identity.
    public struct Configuration: Hashable, Sendable {
        let playbook: Playbook

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.playbook === rhs.playbook
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(playbook))
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    /// No-op: there are no weights to load and no connection to open.
    public func prewarm(model: Model, transcript: Transcript) {}

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let playbook = configuration.playbook
        let script = try playbook.nextScript(recording: request)
        try await ScriptPlayer(clock: playbook.clock).play(script, into: ChannelSink(channel: channel))
    }
}

// MARK: - Shared state

/// The scripts, the cursor into them, and the requests seen so far.
///
/// A reference type because ``ScriptedLanguageModelExecutor/Configuration`` must
/// be a `Hashable` value while still connecting every executor the framework
/// builds back to one model's state. `Mutex` rather than an actor so
/// ``ScriptedLanguageModel/requests`` can be read without `await` — there are no
/// continuations here, only data.
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
final class Playbook: Sendable {

    let cursor: ScriptCursor
    let clock: any Clock<Duration>

    private let recorded = Mutex<[LanguageModelExecutorGenerationRequest]>([])

    init(scripts: [Script], exhaustion: ScriptExhaustion, clock: any Clock<Duration>) {
        self.cursor = ScriptCursor(scripts: scripts, exhaustion: exhaustion)
        self.clock = clock
    }

    var requests: [LanguageModelExecutorGenerationRequest] {
        recorded.withLock { $0 }
    }

    /// The script for this request, advancing the cursor and recording the
    /// request. Throws ``ScriptExhausted`` under ``ScriptExhaustion/fail``.
    ///
    /// The request is recorded **before** the cursor can throw: a test asking
    /// "what was this model asked?" wants the over-ask in the answer, since
    /// that is usually the very thing being diagnosed.
    func nextScript(recording request: LanguageModelExecutorGenerationRequest) throws -> Script {
        recorded.withLock { $0.append(request) }
        return try cursor.next()
    }
}

// MARK: - Channel adapter

/// Translates played steps into channel events (SPEC §7.3's provider side).
@available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
private struct ChannelSink: ScriptSink {

    let channel: LanguageModelExecutorGenerationChannel

    func emit(_ text: String, tokenCount: Int) async {
        await channel.send(.response(action: .appendText(text, tokenCount: tokenCount)))
    }

    func reportUsage(input: Int, output: Int, cached: Int, reasoning: Int) async {
        await channel.send(
            .response(
                action: .updateUsage(
                    input: .init(totalTokenCount: input, cachedTokenCount: cached),
                    output: .init(totalTokenCount: output, reasoningTokenCount: reasoning)
                )
            )
        )
    }

    func reportMetadata(_ values: [String: String]) async {
        let boxed = values.mapValues { $0 as any Sendable & Codable & Equatable }
        await channel.send(.response(action: .updateMetadata(boxed)))
    }
}

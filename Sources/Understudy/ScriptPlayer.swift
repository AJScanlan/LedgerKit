import Foundation

/// Where a played script's output goes.
///
/// Internal: the only conformer that ships is the Foundation Models channel
/// adapter. It exists so the *engine* — the part with all the ordering,
/// cancellation and timing behaviour — is testable without a platform that has
/// the framework, and so ``Script`` never has to know what a channel is.
protocol ScriptSink: Sendable {
    func emit(_ text: String, segmentID: String?, tokenCount: Int) async
    func revise(_ text: String, segmentID: String, tokenCount: Int) async
    func callTool(_ name: String, id: String, arguments: String, tokenCount: Int) async
    func reportUsage(input: Int, output: Int, cached: Int, reasoning: Int) async
    func reportMetadata(_ values: [String: String]) async
}

/// Plays a ``Script`` into a ``ScriptSink``.
///
/// Deterministic by construction: the only inputs are the script, the sink and
/// the clock. Nothing here consults wall time, randomness or the environment,
/// so two runs of the same script produce the same emissions in the same order.
struct ScriptPlayer: Sendable {

    /// Injected so `.wait` is real in previews and controllable in tests.
    /// Defaults to `ContinuousClock`, which is the right answer for a demo and
    /// the wrong one for a suite that would rather not sleep.
    let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Runs every step in order.
    ///
    /// Cancellation is checked *between* steps as well as inside the ones that
    /// suspend, so a cancelled generation stops at a step boundary rather than
    /// part way through emitting — which keeps the partial content a test
    /// observes equal to some prefix of the script, always.
    func play(_ script: Script, into sink: some ScriptSink) async throws {
        for step in script.steps {
            try Task.checkCancellation()

            switch step.kind {
            case .emit(let text, let segmentID, let tokenCount):
                await sink.emit(text, segmentID: segmentID, tokenCount: tokenCount)

            case .revise(let text, let segmentID, let tokenCount):
                await sink.revise(text, segmentID: segmentID, tokenCount: tokenCount)

            case .callTool(let name, let id, let arguments, let tokenCount):
                await sink.callTool(name, id: id, arguments: arguments, tokenCount: tokenCount)

            case .wait(let duration):
                try await clock.sleep(for: duration)

            case .waitFor(let cue):
                try await cue.park()

            case .reportUsage(let input, let output, let cached, let reasoning):
                await sink.reportUsage(input: input, output: output, cached: cached, reasoning: reasoning)

            case .reportMetadata(let values):
                await sink.reportMetadata(values)

            case .fail(let error):
                throw error
            }
        }
    }
}

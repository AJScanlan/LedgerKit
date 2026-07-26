import Foundation

/// A rendezvous between a running script and the test watching it.
///
/// ```swift
/// let cue = Cue()
/// let model = ScriptedLanguageModel(script: ["half an ans", .waitFor(cue), "wer"])
///
/// await cue.reached()                     // the model is parked, mid-response
/// await store.cancelGeneration(in: id)    // …so cancel at a point you chose
/// await cue.signal()                      // let it go
/// ```
///
/// **Both sides wait, and that is the whole point.** A test that only *released*
/// the model would still have to guess when the model got there — which is a
/// sleep, which is a flake. ``reached()`` removes the guess: when it returns,
/// the generation is provably mid-flight and stopped, so whatever the test does
/// next happens at a known point in the stream rather than a hoped-for one.
///
/// A cue is single-use: once signalled it stays open, so a script that reaches
/// it again passes straight through. Use one cue per point of interest.
public actor Cue {

    private var arrived = false
    private var signalled = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, any Error>] = []

    public init() {}

    /// Whether the script has reached this cue.
    public var isReached: Bool { arrived }

    /// Suspends until the running script parks at this cue; returns immediately
    /// if it already has.
    public func reached() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    /// Releases the script. Idempotent, and safe to call before the script has
    /// arrived — a cue signalled early lets the script straight through.
    public func signal() {
        guard !signalled else { return }
        signalled = true
        let waiting = releaseWaiters
        releaseWaiters = []
        for continuation in waiting { continuation.resume() }
    }

    /// The script side. Announces arrival, then parks until signalled.
    ///
    /// Throws `CancellationError` if the generation is cancelled while parked —
    /// without which cancelling a model stopped at a cue would deadlock the very
    /// tests this type exists for.
    func park() async throws {
        arrived = true
        let arrivals = arrivalWaiters
        arrivalWaiters = []
        for continuation in arrivals { continuation.resume() }

        if signalled { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checked inside the actor, because cancellation can land
                // between the handler being installed and the continuation
                // being stored — the classic hole in this pattern.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.failWaiters() }
        }
    }

    private func failWaiters() {
        let waiting = releaseWaiters
        releaseWaiters = []
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
    }
}

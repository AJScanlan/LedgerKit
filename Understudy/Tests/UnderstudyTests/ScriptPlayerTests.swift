import Foundation
import Testing
@testable import Understudy

// The engine, tested where it runs: `Script`, `ScriptCursor`, `Cue` and
// `ScriptPlayer` carry no Foundation Models types, so everything here executes
// on any Mac today. `ScriptedLanguageModelTests` covers the 27-only conformance.

/// Records what a played script produced, in order.
private final class RecordingSink: ScriptSink, @unchecked Sendable {
    enum Event: Equatable {
        case text(String, tokenCount: Int)
        case revised(String, segmentID: String, tokenCount: Int)
        case toolCall(name: String, id: String, arguments: String)
        case usage(input: Int, output: Int, cached: Int, reasoning: Int)
        case metadata([String: String])
    }

    /// Fragments that named no segment. A control character so it can never
    /// collide with an ID a script chose.
    private static let anonymousSegment = "\u{0}anonymous"

    private let lock = NSLock()
    private var storage: [Event] = []
    /// Segment order and contents, kept beside the event log because the log
    /// answers "what happened, in what order" and this answers "what would a
    /// consumer be looking at".
    private var order: [String] = []
    private var segments: [String: String] = [:]

    var events: [Event] {
        lock.withLock { storage }
    }

    /// The response as a *consumer* would see it — which is **not** simply the
    /// fragments concatenated, once a script can revise.
    ///
    /// The framework accumulates per segment between a provider and a
    /// `ResponseStream`: an `emit` extends its segment, a `revise` replaces one.
    /// Modelling that here is what makes `.revise` testable at all — a sink that
    /// only appended would report the *provider's* history rather than the
    /// consumer's view, and the whole point of a revision is that those two stop
    /// agreeing.
    var text: String {
        lock.withLock { order.compactMap { segments[$0] }.joined() }
    }

    private func append(_ event: Event) {
        lock.withLock { storage.append(event) }
    }

    func emit(_ text: String, segmentID: String?, tokenCount: Int) async {
        append(.text(text, tokenCount: tokenCount))
        lock.withLock {
            let key = segmentID ?? Self.anonymousSegment
            if segments[key] == nil { order.append(key) }
            segments[key, default: ""] += text
        }
    }

    func revise(_ text: String, segmentID: String, tokenCount: Int) async {
        append(.revised(text, segmentID: segmentID, tokenCount: tokenCount))
        lock.withLock {
            if segments[segmentID] == nil { order.append(segmentID) }
            segments[segmentID] = text
        }
    }

    /// A tool call contributes no *text* — the framework runs the tool and the
    /// output becomes a transcript entry, not part of the response the model is
    /// building. So it is recorded and left out of `text`.
    func callTool(_ name: String, id: String, arguments: String, tokenCount: Int) async {
        append(.toolCall(name: name, id: id, arguments: arguments))
    }

    func reportUsage(input: Int, output: Int, cached: Int, reasoning: Int) async {
        append(.usage(input: input, output: output, cached: cached, reasoning: reasoning))
    }

    func reportMetadata(_ values: [String: String]) async {
        append(.metadata(values))
    }
}

/// A clock that never actually waits, so `.wait` steps cost nothing in a suite
/// while still meaning something in a preview.
private struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant

    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}

private struct Boom: Error, Equatable {}

/// A rendezvous that ignores cancellation, unlike ``Cue``.
///
/// Needed to test the player's *between-step* cancellation check in isolation.
/// Every step that suspends already throws on cancellation by itself, so a test
/// using `Cue` proves only that `Cue` works — mutation testing found exactly
/// that hole: deleting `try Task.checkCancellation()` from the step loop left
/// the whole suite green. Parking inside the **sink** and releasing normally
/// puts the player back at a step boundary with the task already cancelled,
/// which is the only place that check can be observed.
private actor Latch {
    private var arrived = false
    private var opened = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        arrived = true
        for continuation in arrivals { continuation.resume() }
        arrivals = []
        if opened { return }
        await withCheckedContinuation { releases.append($0) }
    }

    func reached() async {
        if arrived { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func open() {
        opened = true
        for continuation in releases { continuation.resume() }
        releases = []
    }
}

/// Parks inside `emit` once, so a test can cancel while the player is mid-step.
private final class ParkingSink: ScriptSink, @unchecked Sendable {
    let inner = RecordingSink()
    let latch = Latch()
    private let lock = NSLock()
    private var emitted = 0

    var text: String { inner.text }

    func emit(_ text: String, segmentID: String?, tokenCount: Int) async {
        await inner.emit(text, segmentID: segmentID, tokenCount: tokenCount)
        let isFirst = lock.withLock { emitted += 1; return emitted == 1 }
        if isFirst { await latch.arrive() }
    }

    func revise(_ text: String, segmentID: String, tokenCount: Int) async {
        await inner.revise(text, segmentID: segmentID, tokenCount: tokenCount)
    }

    func callTool(_ name: String, id: String, arguments: String, tokenCount: Int) async {
        await inner.callTool(name, id: id, arguments: arguments, tokenCount: tokenCount)
    }

    func reportUsage(input: Int, output: Int, cached: Int, reasoning: Int) async {
        await inner.reportUsage(input: input, output: output, cached: cached, reasoning: reasoning)
    }

    func reportMetadata(_ values: [String: String]) async {
        await inner.reportMetadata(values)
    }
}

@Suite("Script — the vocabulary")
struct ScriptVocabularyTests {

    @Test("a string literal is a whole response")
    func stringLiteralIsAResponse() async {
        let sink = RecordingSink()
        try? await ScriptPlayer(clock: ImmediateClock())
            .play("A valley fold brings the paper down.", into: sink)

        #expect(sink.events == [.text("A valley fold brings the paper down.", tokenCount: 1)])
    }

    @Test("an array literal mixes bare strings with steps")
    func arrayLiteralMixes() async throws {
        let sink = RecordingSink()
        let script: Script = [
            "A valley fold ",
            .wait(.milliseconds(80)),
            .emit("brings the paper down.", tokenCount: 5),
        ]
        try await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)

        #expect(
            sink.events == [
                .text("A valley fold ", tokenCount: 1),
                .text("brings the paper down.", tokenCount: 5),
            ],
            "a wait produces no output — it only paces the ones around it"
        )
        #expect(sink.text == "A valley fold brings the paper down.")
    }
}

@Suite("ScriptPlayer — playback")
struct ScriptPlayerTests {

    @Test("steps run in script order, whatever that order is")
    func stepsRunInOrder() async throws {
        // Foundation Models expects usage before text. A script may say
        // otherwise, and the player must obey — a double that cannot express a
        // misbehaving provider cannot test a driver's response to one.
        let sink = RecordingSink()
        let script: Script = [
            "first ",
            .reportUsage(input: 12, output: 8),
            "second",
            .reportMetadata(["modelID": "scripted-1"]),
        ]
        try await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)

        #expect(
            sink.events == [
                .text("first ", tokenCount: 1),
                .usage(input: 12, output: 8, cached: 0, reasoning: 0),
                .text("second", tokenCount: 1),
                .metadata(["modelID": "scripted-1"]),
            ]
        )
    }

    /// **The misbehaviour half of the double.** Apple's channel offers
    /// `replaceTextSegment` beside `appendText`, so a provider may legally revise
    /// a segment it already sent — and a consumer that diffs cumulative snapshots
    /// into append-only storage has to do *something* about that. Until this step
    /// existed, no script could make it happen, so no consumer could test it.
    @Test("a revision replaces its segment rather than extending it")
    func revisionReplacesASegment() async throws {
        let sink = RecordingSink()
        let script: Script = [
            .emit("The answer is 41", segmentID: "answer"),
            .revise("The answer is 42", segmentID: "answer"),
        ]

        try await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)

        #expect(
            sink.events == [
                .text("The answer is 41", tokenCount: 1),
                .revised("The answer is 42", segmentID: "answer", tokenCount: 1),
            ]
        )
        // **The property that makes this hostile**: what a consumer ends up
        // looking at is not an extension of what it saw a moment ago.
        #expect(sink.text == "The answer is 42")
    }

    /// Revision is per *segment*, so the segments beside it are untouched — which
    /// is what makes the accumulated whole stop being a prefix extension rather
    /// than simply becoming a different string.
    @Test("a revision leaves neighbouring segments alone")
    func revisionIsScopedToItsSegment() async throws {
        let sink = RecordingSink()
        let script: Script = [
            .emit("one ", segmentID: "a"),
            .emit("two", segmentID: "b"),
            .revise("ONE ", segmentID: "a"),
        ]

        try await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)

        #expect(sink.text == "ONE two")
    }

    @Test("the same script plays identically every time")
    func playbackIsDeterministic() async throws {
        let script: Script = ["a ", .wait(.milliseconds(5)), "b ", .reportUsage(input: 1, output: 2), "c"]

        var runs: [[RecordingSink.Event]] = []
        for _ in 0..<5 {
            let sink = RecordingSink()
            try await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)
            runs.append(sink.events)
        }

        #expect(runs.allSatisfy { $0 == runs[0] }, "playback is not reproducible")
    }

    @Test("a failure step throws, and everything after it is silence")
    func failureStops() async {
        let sink = RecordingSink()
        let script: Script = ["half an answer", .fail(Boom()), "never emitted"]

        await #expect(throws: Boom.self) {
            try await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)
        }
        #expect(
            sink.text == "half an answer",
            "the partial before a failure survives — that is the shape a failed bubble renders"
        )
    }

    @Test("a script of nothing but text still honours cancellation")
    func cancellationIsCheckedBetweenSteps() async {
        // No step here throws on cancellation by itself: `.emit` just appends.
        // Only the player's own check between steps can stop this script, so
        // this test fails if that line is ever deleted — which the suite
        // otherwise would not notice (found by mutation testing).
        let sink = ParkingSink()
        let script: Script = ["one ", "two ", "three ", "four"]

        let task = Task {
            try await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)
        }

        await sink.latch.reached()      // parked inside the first emit
        task.cancel()
        await sink.latch.open()         // released normally, *not* by cancellation

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(sink.text == "one ", "the player must not run on past a cancelled step boundary")
    }

    @Test("cancellation stops at a step boundary, so the partial is always a prefix")
    func cancellationStopsAtABoundary() async throws {
        let cue = Cue()
        let sink = RecordingSink()
        let script: Script = ["one ", "two ", .wait(until: cue), "three ", "four"]

        let task = Task {
            try await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)
        }

        await cue.reached()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(
            sink.text == "one two ",
            "a cancelled generation emits some prefix of its script, never a fragment of one"
        )
    }
}

@Suite("Cue — the rendezvous")
struct CueTests {

    @Test("reached() does not return until the script parks")
    func reachedWaitsForArrival() async throws {
        let cue = Cue()
        let sink = RecordingSink()

        let task = Task {
            try await ScriptPlayer(clock: ImmediateClock())
                .play(["before ", .wait(until: cue), "after"], into: sink)
        }

        await cue.reached()
        #expect(sink.text == "before ", "the script is parked exactly where the cue is")

        await cue.signal()
        try await task.value
        #expect(sink.text == "before after")
    }

    @Test("signalling early lets the script straight through")
    func earlySignalIsNotLost() async throws {
        // Otherwise every use would be a race between the test and the script.
        let cue = Cue()
        await cue.signal()

        let sink = RecordingSink()
        try await ScriptPlayer(clock: ImmediateClock())
            .play(["before ", .wait(until: cue), "after"], into: sink)

        #expect(sink.text == "before after")
    }

    @Test("signalling twice is harmless")
    func signalIsIdempotent() async throws {
        let cue = Cue()
        await cue.signal()
        await cue.signal()
        #expect(await cue.isReached == false, "nothing ever arrived")

        let sink = RecordingSink()
        try await ScriptPlayer(clock: ImmediateClock()).play([.wait(until: cue), "through"], into: sink)
        #expect(sink.text == "through", "a doubly-signalled cue is still open, not closed again")
    }

    @Test("a parked script that is cancelled throws rather than hanging forever")
    func cancellationWhileParked() async {
        // Without this the chaos suites would deadlock on the exact scenario
        // they exist to exercise.
        let cue = Cue()
        let sink = RecordingSink()

        let task = Task {
            try await ScriptPlayer(clock: ImmediateClock())
                .play(["partial", .wait(until: cue), "unreachable"], into: sink)
        }

        await cue.reached()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(sink.text == "partial")
    }
}

@Suite("ScriptCursor — exhaustion")
struct ScriptCursorTests {

    /// What a script actually says, since `Script` is not `Equatable` (its steps
    /// can hold errors and cues). Playing it is the honest comparison anyway:
    /// two scripts are the same when they produce the same response.
    private func spoken(_ script: Script) async -> String {
        let sink = RecordingSink()
        try? await ScriptPlayer(clock: ImmediateClock()).play(script, into: sink)
        return sink.text
    }

    @Test("scripts are served in order")
    func servesInOrder() async throws {
        let cursor = ScriptCursor(scripts: ["one", "two"], exhaustion: .fail)
        #expect(await spoken(try cursor.next()) == "one")
        #expect(cursor.served == 1)
        #expect(await spoken(try cursor.next()) == "two")
        #expect(cursor.served == 2)
    }

    @Test("running out throws by default, naming both numbers")
    func failWhenExhausted() throws {
        let cursor = ScriptCursor(scripts: ["only one"], exhaustion: .fail)
        _ = try cursor.next()

        // Loud by default: over-asking is a bug in the test or the code, and
        // silence would let it pass as a mysteriously empty response.
        let error = #expect(throws: ScriptExhausted.self) { _ = try cursor.next() }
        #expect(error?.scriptCount == 1)
        #expect(error?.requestNumber == 2, "1-based, so it reads as 'the second request'")
    }

    @Test("repeatLast keeps answering with the final script")
    func repeatLast() async throws {
        let cursor = ScriptCursor(scripts: ["first", "last"], exhaustion: .repeatLast)
        #expect(await spoken(try cursor.next()) == "first")
        #expect(await spoken(try cursor.next()) == "last")
        #expect(await spoken(try cursor.next()) == "last")
        #expect(await spoken(try cursor.next()) == "last")
    }

    @Test("loop starts over")
    func loop() async throws {
        let cursor = ScriptCursor(scripts: ["a", "b"], exhaustion: .loop)
        var spokenLines: [String] = []
        for _ in 0..<5 { spokenLines.append(await spoken(try cursor.next())) }

        #expect(spokenLines == ["a", "b", "a", "b", "a"])
    }

    @Test("an empty script list throws under every policy")
    func emptyScriptsAlwaysThrow() {
        // `.repeatLast` and `.loop` have nothing to repeat or loop over, and
        // must not quietly produce an empty response instead.
        for policy in [ScriptExhaustion.fail, .repeatLast, .loop] {
            let cursor = ScriptCursor(scripts: [], exhaustion: policy)
            #expect(throws: ScriptExhausted.self) { _ = try cursor.next() }
        }
    }
}

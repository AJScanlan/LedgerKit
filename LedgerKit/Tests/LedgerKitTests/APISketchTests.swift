import Foundation
import Testing
@testable import LedgerKit

// **The §11 sketch, as code that must compile and — since Phase 3 — must run.**
// M5-PLAN guardrail 1 and the milestone's first exit criterion.
//
// SPEC §11 is a sketch in a Markdown fence, which means nothing stops the landed
// API from drifting away from it one plausible signature at a time. This file is
// the check: if a §11 line stops being writable as sketched, either the
// signature is wrong or rev 8 records why the sketch moved. Never silently
// diverge.
//
// ``apiSketch`` is **executed** by the suite below — every §11 line, end to end
// against a scripted driver, including both stop-button paths and the delete.
// ``apiShape`` holds the single line that must type-check without running: the
// file-backed initializer, since no test should scribble a database into the
// filesystem to prove a parameter label.
//
// The one deliberate substitution from §11, recorded rather than glossed: §11
// constructs `GenerationDriver(model: SystemLanguageModel.default,
// toolRecording: .metadataOnly)`, which is M6's concrete driver over Foundation
// Models. M5 has only the seam (D21), so the sketch takes a `some
// GenerationDriving` — which is exactly the point of the seam, and what lets
// this file run on a machine with no Apple Intelligence eligibility.

// MARK: - The sketch, executed

/// SPEC §11's lifecycle, tree and generation lines, in order.
private func apiSketch(store: ConversationStore, driver: some GenerationDriving) async throws -> [String] {
    // Lifecycle & metadata
    let convo = try await store.createConversation()                      // optional title:
    try await store.setInstructions("You are an origami tutor.", in: convo.id)
    try await store.setTitle("Valley folds 101", in: convo.id)            // titleChanged; nil clears (§6.1)

    // Turn verbs — the three generation starters; all throw generationInFlight
    // under single-flight (§6.5), all suspend to a terminal Outcome.
    var rendered: [String] = []

    let outcome = try await store.send("Explain valley folds", in: convo.id, using: driver)
        // send ≡ append user message + respond(to: it) — the 95% path, one call.
        // Atomic within the actor (§6.5): the single-flight check, the user-message
        // append, and generationStarted commit together — a losing racer records
        // NOTHING. No orphaned user message, no yanked path.
    rendered.append(render(outcome))

    let thread = try await store.conversation(convo.id)
    guard let message = thread.activeMessages.first(where: { $0.role == .user }) else { return rendered }

    let replacement = try await store.edit(message.id,
                                           content: "Explain mountain folds",
                                           in: convo.id)
        // Pure ledger: messageEdited + activePathChanged, one transaction (§6.4).
        // Does NOT generate — composition is the app's business.

    let outcome2 = try await store.respond(to: replacement, in: convo.id, using: driver)
        // A generation whose parent is an existing USER message (§6.5 eligibility) —
        // the post-edit verb. Parent == endpoint here, so auto-extend fires (§6.4).
    rendered.append(render(outcome2))

    let edited = try await store.conversation(convo.id)
    guard let assistant = edited.activeMessages.last(where: { $0.role == .assistant }) else { return rendered }

    let outcome3 = try await store.regenerate(assistant.id, in: convo.id, using: driver)
        // EXACTLY respond(to: its parent) — pure sugar since rev 4 (§6.4): the
        // off-endpoint path event is respond's job now, so regenerate adds nothing
        // but the assistant-to-parent lookup. Sibling response falls out.
    rendered.append(render(outcome3))

    // SwiftUI — message states drive UI directly:
    rendered.append(contentsOf: (try await store.conversation(convo.id)).activeMessages.map(bubble))

    // Branching
    try await store.switchBranch(to: replacement, in: convo.id)           // bare activePathChanged

    // Cancellation — canonical path; the store outlives any Task handle:
    await store.cancelGeneration(in: convo.id)                            // no-op if none live; racing a
                                                                          // natural terminal is benign —
                                                                          // first append wins, I3 (§7.5)

    // send/respond/regenerate THROW only when the generation never started —
    // i.e. before generationStarted is appended (§7.2). After the append,
    // failures are outcomes, not exceptions. One channel for "couldn't record",
    // one channel for "recorded a failure".
    let generationTask = Task {
        try await store.send("Explain valley folds", in: convo.id, using: driver)
    }

    // Stop button — either path, same semantics (§7.5):
    generationTask.cancel()            // sugar: dies with its owner
    // …and §7.2's straddle is a real fork a consumer must write: cancelled
    // *before* `generationStarted` lands and the call throws, because nothing
    // started; cancelled *after* and it returns `.cancelled`, because the
    // recording succeeded. A stop button hits whichever side it lands on.
    do {
        rendered.append(render(try await generationTask.value))
    } catch is CancellationError {
        rendered.append("cancelled before it started")
    }
    // or:
    await store.cancelGeneration(in: convo.id)   // canonical

    try await store.deleteConversation(convo.id)                          // cancels any in-flight generation
                                                                          // first (§9), then irreversible,
                                                                          // out-of-band delete
    return rendered
}

/// The one §11 line that must type-check here but must not execute: no test
/// should scribble a database into the filesystem to prove a label.
///
/// Never called; see the file header.
private func apiShape(dbURL: URL) throws {
    _ = try ConversationStore(persistence: .sqlite(at: dbURL))            // actor
}

/// §11's showpiece: the compiler forces the app to handle interruption and
/// recoverability. Standing in for the SwiftUI `switch`, since the package has
/// no views — the exhaustiveness is the assertion, not the rendering.
private func bubble(for message: Message) -> String {
    switch message.state {
    case .complete(let content):
        "complete: \(content.text)"
    case .streaming(let partial):
        "streaming: \(partial)"
    case .interrupted(let partial):
        "interrupted, offer regenerate: \(partial)"
    case .failed(let partial, _, .recoverableUpstream(.reauthenticate)):
        "reauth prompt: \(partial)"
    case .failed(let partial, _, .recoverableUpstream(let action)):
        "upstream action \(action): \(partial)"
    case .failed(let partial, _, .retryable(let after)):
        "retry\(after.map { " after \($0)" } ?? ""): \(partial)"
    case .failed(let partial, let error, .terminal):
        "terminal failure \(error): \(partial)"
    case .cancelled(let partial):
        "cancelled: \(partial)"
    }
}

/// The other exhaustive switch a consumer writes: how a turn ended.
private func render(_ outcome: Outcome) -> String {
    switch outcome {
    case .completed(let stopInfo):
        "completed (\(stopInfo.usage?.outputTokens.map(String.init) ?? "unreported") output tokens)"
    case .failed(let error):
        "failed: \(error)"
    case .cancelled:
        "cancelled"
    }
}

// MARK: - Phase 0's behaviour, and Phase 3's exit criterion

@Suite("M5 — the §11 public API")
struct APISketchTests {

    /// **The milestone's first exit criterion, whole.** Every §11 line runs
    /// against a scripted driver — lifecycle, tree verbs, all three generation
    /// starters, both stop-button paths, and the delete — and the logs it
    /// produces are ones the reducer accepts without a single diagnostic.
    @Test("the §11 sketch runs end-to-end against a scripted driver")
    func sketchRuns() async throws {
        let fixture = try StoreUnderTest()
        let driver = ScriptedDriver(saying: "A valley fold is a fold toward you.")

        let rendered = try await apiSketch(store: fixture.store, driver: driver)

        // Three completed turns, each ending in exactly one terminal (I3)…
        #expect(rendered.prefix(3) == [
            "completed (8 output tokens)",
            "completed (8 output tokens)",
            "completed (8 output tokens)",
        ])
        #expect(rendered.contains { $0.hasPrefix("complete: A valley fold") })
        // …and a fourth that the stop button ended instead, on whichever side of
        // §7.2's straddle it landed. Both are correct; asserting one would be
        // asserting a race.
        #expect(rendered.last?.hasPrefix("cancelled") == true)

        // The sketch deletes the conversation it made, so nothing is left —
        // which is itself §9's claim, since the delete had an in-flight
        // generation to sequence behind.
        #expect(try await fixture.backing.conversationSummaries().isEmpty)
    }

    /// The healthy-log property over the §11 flow, up to the point the sketch
    /// erases it: a store-written log never carries a diagnostic.
    @Test("the §11 flow produces a log the reducer accepts without diagnostics")
    func sketchProducesHealthyLogs() async throws {
        let fixture = try StoreUnderTest()
        let convo = try await fixture.store.createConversation()
        try await fixture.store.setInstructions("You are an origami tutor.", in: convo.id)

        let driver = ScriptedDriver(saying: "A valley fold is a fold toward you.")
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

    @Test("opening an in-memory store succeeds and migrates")
    func opensInMemory() throws {
        _ = try ConversationStore(persistence: .inMemory)
    }

    /// **D32: both cadences are configurable from outside the module**, which
    /// §7.4 and §9 have promised since rev 2 while the public surface offered
    /// exactly one value each.
    ///
    /// The *behaviour* of each knob is asserted where it belongs —
    /// `StoreFlushTests` for the flush cadence, `StoreSnapshotRefreshTests` for
    /// the refresh floor — and both of those now construct through these
    /// factories, so this test's job is only the shape: that a consumer can name
    /// a cadence at all, and that naming one produces something other than the
    /// default it was meant to replace.
    @Test("both cadence policies are publicly constructible and reach the store")
    func policiesAreConfigurable() throws {
        let flush = DeltaFlushPolicy.flushing(every: .milliseconds(50), orAfterCharacters: 64)
        let snapshots = SnapshotPolicy.refreshing(afterEachGeneration: false, orAfterEvents: 5_000)

        #expect(flush != .default)
        #expect(snapshots != .default)

        _ = try ConversationStore(persistence: .inMemory, deltaFlush: flush, snapshots: snapshots)
    }

    /// Guardrail 4 at the one place it is testable today. ADR-003 rule 1 says
    /// GRDB never appears in a thrown type; the failure a caller sees is
    /// `LedgerError`, and the underlying description rides along as prose the
    /// test deliberately does not read (ADR-001: assert the case, never the
    /// wording).
    @Test("an unopenable database throws LedgerError, never the backend's error")
    func wrapsBackendFailure() throws {
        let unreachable = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/ledger.db")
        do {
            _ = try ConversationStore(persistence: .sqlite(at: unreachable))
            Issue.record("expected opening an unreachable database to fail")
        } catch let error as LedgerError {
            guard case .persistenceFailure = error else {
                Issue.record("expected .persistenceFailure, got \(error)")
                return
            }
        }
    }

    /// The channel's two properties are the ones a lost delta would violate:
    /// order, and delivery of everything emitted before the reader arrived
    /// (unbounded buffering — see ``GenerationChannel/makeStream()``).
    @Test("the generation channel delivers every signal, in order, then ends")
    func channelDeliversInOrder() async {
        let (signals, channel) = GenerationChannel.makeStream()
        let record = ToolRecord(name: "lookupFold", status: .succeeded)

        channel.emit(.delta("a valley fold "))
        channel.emit(.toolRecord(record))
        channel.emit(.delta("is a fold toward you"))
        channel.finish()

        var received: [GenerationSignal] = []
        for await signal in signals { received.append(signal) }

        #expect(received == [.delta("a valley fold "), .toolRecord(record), .delta("is a fold toward you")])
    }
}

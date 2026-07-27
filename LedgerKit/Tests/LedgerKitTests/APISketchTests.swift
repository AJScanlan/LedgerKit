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
// The file is in two halves, and the split is the milestone's progress made
// visible. ``apiSketch`` is **executed** by the suite below — every lifecycle,
// tree and generation line, end to end against a scripted driver. ``apiShape``
// is type-checked and never called, holding the lines that must not run here:
// the file-backed initializer, which no test should scribble a database for, and
// the cancellation and delete lines, whose verbs land at Phase 4. Phase 4 moves
// those into the runnable half and this comment shrinks.
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

    return rendered
}

/// The §11 lines that must type-check here but must not execute: a file-backed
/// store, and the two verbs Phase 4 implements.
///
/// Never called; see the file header.
private func apiShape(dbURL: URL, driver: some GenerationDriving) async throws {
    let store = try ConversationStore(persistence: .sqlite(at: dbURL))    // actor
    let convo = try await store.createConversation()

    // send/respond/regenerate THROW only when the generation never started —
    // i.e. before generationStarted is appended (§7.2): unknown conversation,
    // unknown/ineligible target, generationInFlight, persistence failure. After
    // the append, failures are outcomes, not exceptions. One channel for
    // "couldn't record", one channel for "recorded a failure".
    let generationTask = Task {
        _ = try await store.send("Explain valley folds", in: convo.id, using: driver)
    }

    // Stop button — either path, same semantics (§7.5):
    generationTask.cancel()                      // sugar: dies with its owner
    // or:
    await store.cancelGeneration(in: convo.id)   // canonical; no-op if none live,
                                                 // and racing a natural terminal is
                                                 // benign — first append wins, I3

    try await store.deleteConversation(convo.id)                          // cancels any in-flight generation
                                                                          // first (§9), then irreversible,
                                                                          // out-of-band delete
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

    /// **The milestone's first exit criterion**, minus the cancellation lines
    /// (Phase 4): every §11 line above runs against a scripted driver, and the
    /// log it produces is one the reducer accepts without a single diagnostic.
    @Test("the §11 sketch runs end-to-end against a scripted driver")
    func sketchRuns() async throws {
        let fixture = try StoreUnderTest()
        let driver = ScriptedDriver(saying: "A valley fold is a fold toward you.")

        let rendered = try await apiSketch(store: fixture.store, driver: driver)

        // Three turns, each ending in exactly one terminal outcome (I3).
        #expect(rendered.prefix(3) == [
            "completed (8 output tokens)",
            "completed (8 output tokens)",
            "completed (8 output tokens)",
        ])
        #expect(rendered.dropFirst(3).contains { $0.hasPrefix("complete: A valley fold") })
        #expect(driver.received.count == 3)

        // Every conversation the sketch touched reduces with empty diagnostics.
        let summaries = try await fixture.backing.conversationSummaries()
        for summary in summaries {
            let problems = try await healthyLogProblems(summary.id, in: fixture.store, backedBy: fixture.backing)
            #expect(problems.isEmpty, "\(summary.id): \(problems)")
        }
    }

    @Test("opening an in-memory store succeeds and migrates")
    func opensInMemory() throws {
        _ = try ConversationStore(persistence: .inMemory)
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

import Foundation
import Testing
@testable import LedgerKit

// **The §11 sketch, rendered as code that must compile** — M5-PLAN guardrail 1.
//
// SPEC §11 is a sketch in a Markdown fence, which means nothing stops the landed
// API from drifting away from it one plausible signature at a time. This file is
// the check: if a §11 line stops being writable as sketched, either the
// signature is wrong or rev 8 records why the sketch moved. Never silently
// diverge.
//
// **`apiSketch` is type-checked and never executed**, and that is not a
// temporary state of affairs at Phase 0 — it is the file's design. Every verb
// body is `fatalError` until its phase lands, so *running* it would crash; and
// even once M5 is complete, a sketch that ran would be a slow integration test
// pretending to be a shape assertion. Shape is what it asserts, and the compiler
// is the assertion. The real behaviour tests live per-phase beside the verbs.
//
// The one deliberate substitution from §11, recorded rather than glossed: §11
// constructs `GenerationDriver(model: SystemLanguageModel.default,
// toolRecording: .metadataOnly)`, which is M6's concrete driver over Foundation
// Models. M5 has only the seam (D21), so the sketch takes a `some
// GenerationDriving` — which is exactly the point of the seam, and what makes
// this file runnable on a machine with no Apple Intelligence eligibility.

/// A stand-in for M6's `GenerationDriver`: enough of a conformance to type-check
/// the sketch, and nothing more. Phase 3 brings the real scripted double, with
/// `Cue` parking for deterministic cancellation (D26).
private struct SketchDriver: GenerationDriving {
    let model = ModelDescriptor(provider: "understudy", model: "sketch")

    func generate(_ request: GenerationRequest, streamingInto channel: GenerationChannel) async -> Outcome {
        channel.emit(.delta("a valley fold is "))
        channel.emit(.delta("a fold toward you"))
        return .completed(StopInfo())
    }
}

// MARK: - The sketch

/// SPEC §11, line for line. Never called; see the file header.
private func apiSketch(dbURL: URL, driver: SketchDriver) async throws -> [String] {
    let store = try ConversationStore(persistence: .sqlite(at: dbURL))    // actor

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
        // EXACTLY respond(to: its parent) — pure sugar since rev 4 (§6.4).
    rendered.append(render(outcome3))

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
        _ = try await store.send("Explain valley folds", in: convo.id, using: driver)
    }

    // Stop button — either path, same semantics (§7.5):
    generationTask.cancel()                      // sugar: dies with its owner
    // or:
    await store.cancelGeneration(in: convo.id)   // canonical

    // SwiftUI — message states drive UI directly:
    rendered.append(contentsOf: edited.activeMessages.map(bubble))

    try await store.deleteConversation(convo.id)                          // cancels any in-flight generation
                                                                          // first (§9), then irreversible,
                                                                          // out-of-band delete
    return rendered
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

// MARK: - Phase 0's behaviour

/// The three Phase 0 declarations that are not scaffolding: the two initializers
/// and the signal channel. Everything else in this milestone's surface is a
/// signature awaiting its phase.
@Suite("M5 Phase 0 — store surface")
struct APISketchTests {

    @Test("Opening an in-memory store succeeds and migrates")
    func opensInMemory() throws {
        _ = try ConversationStore(persistence: .inMemory)
    }

    /// Guardrail 4 at the one place it is testable today. ADR-003 rule 1 says
    /// GRDB never appears in a thrown type; the failure a caller sees is
    /// `LedgerError`, and the underlying description rides along as prose the
    /// test deliberately does not read (ADR-001: assert the case, never the
    /// wording).
    @Test("An unopenable database throws LedgerError, never the backend's error")
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

    /// The channel is the only Phase 0 type with runtime behaviour, and its two
    /// properties are the ones a lost delta would violate: order, and delivery
    /// of everything emitted before the reader arrived (unbounded buffering —
    /// see ``GenerationChannel/makeStream()``).
    @Test("The generation channel delivers every signal, in order, then ends")
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

import LedgerKit
import SwiftUI
import Understudy

// M7 Phase 3's exit criterion: **streaming renders smoothly in a preview driven by
// `ScriptedLanguageModel`** — and D43's decision about where it lives.
//
// It is here, in the app target, rather than in the library, because LedgerKit ships
// **no view components** (N6). And it is deliberately *not* a throwaway: the
// exhaustive `switch message.state` below is the showpiece §11 describes, and M8
// styles this rather than replacing it.
//
// Zero Apple Intelligence eligibility is required. `ScriptedLanguageModel` is a real
// `LanguageModel` conformance (§10.1), so the whole pipeline runs — real session,
// real driver, real store, real projection — with a script standing in for a model.
// That is tenet 5's point: the double is first-class, so the demo is honest about
// every layer except which provider answered.

/// Drives one scripted generation and shows the message states as they happen.
@available(macOS 27.0, iOS 27.0, *)
struct StreamingPreview: View {

    @State private var harness: Harness?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let harness {
                    Transcript(projection: harness.projection, harness: harness)
                } else if let failure {
                    ContentUnavailableView("Could not open the store", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView("Opening the ledger…")
                }
            }
            .navigationTitle("LedgerKit")
        }
        .task {
            // The projection's initializer is `async throws` — attaching reads the
            // log and the conversation may not exist — so this is where an app pays
            // for it, once, in the place it is already suspended.
            do { harness = try await Harness() } catch { failure = String(describing: error) }
        }
    }
}

/// The store, a driver, and the projection over one conversation.
///
/// Deliberately thin: it holds no conversation state of its own. Everything on screen
/// comes from `projection.conversation`, which is a fold of the log plus liveness —
/// so there is no second copy of the truth to fall out of sync.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
@Observable
final class Harness {

    let projection: ConversationProjection
    private let store: ConversationStore
    private let conversation: ConversationID
    private(set) var isGenerating = false

    /// A script paced so a human can *see* the stream arrive.
    ///
    /// The delays are not decoration. Without them the framework coalesces everything
    /// into one or two snapshots (measured at M6), so the preview would finish in a
    /// frame and demonstrate nothing — and at 400 ms it was still too quick to
    /// screenshot mid-flight, which is a fair proxy for "too quick to watch".
    private static var script: Script {
        Script([
            .emit("A vall"),
            .wait(.milliseconds(400)),
            .emit("ey fold"),
            .wait(.milliseconds(400)),
            .emit(" bring"),
            .wait(.milliseconds(400)),
            .emit("s the "),
            .wait(.milliseconds(400)),
            .emit("paper "),
            .wait(.milliseconds(400)),
            .emit("toward you, "),
            .wait(.milliseconds(400)),
            .emit("creas"),
            .wait(.milliseconds(400)),
            .emit("ing awa"),
            .wait(.milliseconds(400)),
            .emit("y from t"),
            .wait(.milliseconds(400)),
            .emit("he mountain."),
        ])
    }

    init() async throws {
        // In-memory, because a preview should start from nothing every launch. Swap
        // this one line for `.sqlite(at:)` and the kill-and-relaunch story (DoD-1)
        // becomes demonstrable instead of described — which is M8's job.
        store = try ConversationStore(persistence: .inMemory)
        conversation = try await store.createConversation(title: "Valley folds 101").id
        try await store.setInstructions("You are an origami tutor.", in: conversation)
        projection = try await ConversationProjection(of: conversation, in: store)
    }

    /// **DoD-2's one line.** Every other line in this file is provider-agnostic;
    /// replacing `ScriptedLanguageModel` with `SystemLanguageModel.default` or
    /// `PrivateCloudComputeLanguageModel` is the entire swap.
    private func driver() -> GenerationDriver {
        GenerationDriver(
            model: ScriptedLanguageModel(script: Self.script),
            descriptor: ModelDescriptor(provider: "understudy", model: "scripted")
        )
    }

    func send(_ text: String) async {
        isGenerating = true
        defer { isGenerating = false }
        // The return value is the terminal `Outcome`; the *states along the way* are
        // what the projection published, which is why nothing here has to render it.
        _ = try? await store.send(text, in: conversation, using: driver())
    }

    func stop() async {
        await store.cancelGeneration(in: conversation)
    }

    func regenerate(_ message: MessageID) async {
        isGenerating = true
        defer { isGenerating = false }
        _ = try? await store.regenerate(message, in: conversation, using: driver())
    }
}

@available(macOS 27.0, iOS 27.0, *)
private struct Transcript: View {
    let projection: ConversationProjection
    let harness: Harness

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(projection.conversation.activeMessages) { message in
                        Bubble(message: message) { await harness.regenerate(message.id) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            Divider()
            HStack {
                Button("Send") { Task { await harness.send("Explain valley folds") } }
                    .disabled(harness.isGenerating)
                Button("Stop") { Task { await harness.stop() } }
                    .disabled(!harness.isGenerating)
                Spacer()
                if !projection.conversation.diagnostics.isEmpty {
                    // Empty on every healthy log (§6.5). Shown because a non-empty
                    // `diagnostics` means damage, a partial restore, or a *newer*
                    // LedgerKit having written this log — and a demo that hid that
                    // would be hiding the most interesting thing the reducer says.
                    Label("\(projection.conversation.diagnostics.count)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .padding()
        }
    }
}

/// **The showpiece: the compiler will not let this forget a state.**
///
/// Five cases, five treatments, and no `default`. Add a case to `MessageState` and
/// every app stops building until it decides what the new state looks like — which is
/// tenet 1 paying out at the last possible layer, in the view.
@available(macOS 27.0, iOS 27.0, *)
private struct Bubble: View {
    let message: Message
    let onRegenerate: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .user ? "You" : "Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            switch message.state {
            case .complete(let content):
                Text(content.text)

            case .streaming(let partial):
                // The live case, and the only one no fold can produce (§6.2). An empty
                // partial is a generation that has started and not yet spoken — §6.2
                // deliberately has no separate `.pending`, so this is what that looks
                // like.
                Text("\(partial)\(Text("▌").foregroundStyle(.tint))")

            case .interrupted(let partial):
                // What a crash looks like on reload: the fold found no terminal (I5).
                // Nothing repaired anything — this is simply what the log says.
                Text(partial).foregroundStyle(.secondary)
                affordance("Interrupted — regenerate", icon: "bolt.horizontal")

            case .cancelled(let partial):
                Text(partial).foregroundStyle(.secondary)
                Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)

            case .failed(let partial, let error, let recoverability):
                if !partial.isEmpty { Text(partial).foregroundStyle(.secondary) }
                // **The affordance comes from `Recoverability`, never from the error.**
                // §8's whole contract: the app switches over what it can *do*, not over
                // what went wrong.
                switch recoverability {
                case .retryable(let after):
                    affordance(after.map { "Retry in \($0)" } ?? "Retry", icon: "arrow.clockwise")
                case .recoverableUpstream(.enableAppleIntelligence):
                    affordance("Turn on Apple Intelligence", icon: "gear")
                case .recoverableUpstream(.awaitModelDownload):
                    affordance("Waiting for the model", icon: "arrow.down.circle")
                case .recoverableUpstream(.reduceContext):
                    affordance("Shorten the conversation", icon: "scissors")
                case .recoverableUpstream(.reauthenticate):
                    affordance("Sign in again", icon: "person.badge.key")
                case .terminal:
                    affordance("Regenerate", icon: "arrow.triangle.2.circlepath")
                }
                Text(String(describing: error)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func affordance(_ title: String, icon: String) -> some View {
        Button { Task { await onRegenerate() } } label: {
            Label(title, systemImage: icon).font(.caption)
        }
        .buttonStyle(.bordered)
    }
}

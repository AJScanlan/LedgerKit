import LedgerKit
import SwiftUI

/// The pitch in one exhaustive `switch` (SPEC §11).
///
/// The point of this view is not that it is pretty — it is that the compiler will
/// not let it forget a state. Add a case to `MessageState` and every consumer's
/// switch stops building, which is the whole reason interruption and
/// recoverability are *typed* rather than left to a `Bool` and an `Error?`.
///
/// Deliberately text-only: LedgerKit ships no view components (N6), so this is an
/// example of consuming the state machine, not a component to reuse.
public struct ConversationView: View {
    let conversation: Conversation

    public init(conversation: Conversation) {
        self.conversation = conversation
    }

    public var body: some View {
        ForEach(conversation.activeMessages) { message in
            VStack(alignment: .leading, spacing: 2) {
                Text(line(for: message)).font(.body.monospaced())

                // Non-empty exactly when a branch switcher is warranted — a
                // regenerate leaves the old response here as a sibling, which is
                // how "the interrupted partial survives as its own branch" falls
                // out of the model (§6.4).
                let siblings = conversation.messages.siblings(of: message.id)
                if !siblings.isEmpty {
                    Text("↔︎ \(siblings.count) other branch\(siblings.count == 1 ? "" : "es")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func line(for message: Message) -> String {
        let role = switch message.role {
        case .user: "USER"
        case .assistant: "BOT "
        }
        return "\(role): \(body(of: message.state))"
    }

    /// **Exhaustive on purpose — no `default`.** Each case is a distinct thing that
    /// happened and wants a distinct treatment; collapsing any two of them is the
    /// mistake tenet 1 exists to prevent. In a real UI these are five different
    /// bubbles, and the affordance for `.failed` comes from `Recoverability`
    /// rather than from inspecting the error.
    private func body(of state: MessageState) -> String {
        switch state {
        case .complete(let content):
            content.text
        case .streaming(let partial):
            // Projection-only: no fold of any log yields this, because a log
            // cannot know the process is alive (§7.4's overlay).
            "\(partial)▌"
        case .interrupted(let partial):
            // Synthesized from a *missing* terminal (I5) — the whole of crash
            // recovery. The affordance is Regenerate.
            "\(partial) ⟲ [interrupted]"
        case .cancelled(let partial):
            "\(partial) [stopped]"
        case .failed(let partial, _, let recoverability):
            // The error is *not* what drives the UI; the recoverability is (§8).
            "\(partial) ⚠︎ [\(affordance(for: recoverability))]"
        }
    }

    private func affordance(for recoverability: Recoverability) -> String {
        switch recoverability {
        case .retryable(let after):
            after.map { "retry in \($0)" } ?? "retry"
        case .recoverableUpstream(let action):
            switch action {
            case .enableAppleIntelligence: "turn on Apple Intelligence"
            case .awaitModelDownload: "waiting for the model"
            case .reduceContext: "shorten the conversation"
            case .reauthenticate: "sign in again"
            }
        case .terminal:
            "regenerate with changes"
        }
    }
}

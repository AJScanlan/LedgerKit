import LedgerKit
import SwiftUI

// **The code-aesthetics showpiece (SPEC §11), carried forward from M7's preview
// rather than rewritten.** The five-case switch below is the thing the README
// and the launch post are about: the compiler will not let an app forget that a
// message can be interrupted, and it will not let it forget what the user can
// *do* about a failure.
//
// M8's job was to style this, not replace it — so the comments that explain
// *why* each case looks the way it does are the M7 originals.
//
// ## Layout choice, and it is a choice
//
// User turns are trailing-aligned in a tinted bubble; assistant turns are
// leading-aligned as **plain text with no bubble**. That is the modern
// LLM-chat convention (ChatGPT, Claude) rather than the iMessage convention,
// and it is deliberate for two reasons: assistant turns are long, and long
// measure inside a bubble reads badly; and iOS 26's design language puts
// material on the *navigation* layer while content sits flat underneath — a
// glassy or heavily-tinted blob of body text fights that rule.
//
// This is the layer most worth arguing about, so it is kept small and separate.

@available(macOS 27.0, iOS 27.0, *)
struct MessageBubble: View {

    let message: Message
    let siblingCount: Int
    let onRegenerate: () async -> Void
    let onShowBranches: () -> Void

    var body: some View {
        // **Unary by construction.** A `List`/`LazyVStack` row whose body
        // branches at the top level forces SwiftUI to evaluate every row just to
        // compute identity; one root container keeps the templating fast path.
        // The exhaustive switch lives *inside* it.
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            content
            footer
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    // MARK: - The switch

    @ViewBuilder
    private var content: some View {
        switch message.state {
        case .complete(let content):
            text(content.text)

        case .streaming(let partial):
            // The live case, and the only one no fold can produce (§6.2). An
            // empty partial is a generation that has started and not yet spoken
            // — §6.2 deliberately has no separate `.pending`, so this is what
            // that looks like.
            text("\(partial)\(Text(" ●").foregroundStyle(.tint))")

        case .interrupted(let partial):
            // What a crash looks like on reload: the fold found no terminal
            // (I5). Nothing repaired anything — this is simply what the log
            // says.
            text(partial, dimmed: partial.isEmpty)
            affordance("Regenerate", icon: "arrow.clockwise", note: "Interrupted")

        case .cancelled(let partial):
            text(partial, dimmed: partial.isEmpty)
            note("Stopped", icon: "stop.circle")

        case .failed(let partial, let error, let recoverability):
            if !partial.isEmpty { text(partial) }
            // **The affordance comes from `Recoverability`, never from the
            // error.** §8's whole contract: the app switches over what it can
            // *do*, not over what went wrong.
            switch recoverability {
            case .retryable(let after):
                affordance(after == nil ? "Retry" : "Retry shortly", icon: "arrow.clockwise", note: "Failed")
            case .recoverableUpstream(.enableAppleIntelligence):
                affordance("Open Settings", icon: "gear", note: "Apple Intelligence is off")
            case .recoverableUpstream(.awaitModelDownload):
                affordance("Try again", icon: "arrow.down.circle", note: "The model is still downloading")
            case .recoverableUpstream(.reduceContext):
                // Kept even though the demo never approaches the window
                // (M8-PLAN D54): its *presence* is the demo of §8's contract,
                // and on-device the 4096-token budget makes it reachable in two
                // substantial turns.
                affordance("Shorten and retry", icon: "scissors", note: "This conversation is too long")
            case .recoverableUpstream(.reauthenticate):
                affordance("Sign in again", icon: "person.badge.key", note: "Credentials need attention")
            case .terminal:
                affordance("Regenerate", icon: "arrow.triangle.2.circlepath", note: "Failed")
            }
            Text(String(describing: error))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Pieces

    private func text(_ value: String, dimmed: Bool = false) -> some View {
        text(Text(value), dimmed: dimmed)
    }

    private func text(_ value: Text, dimmed: Bool = false) -> some View {
        value
            .textSelection(.enabled)
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, message.role == .user ? 12 : 0)
            .padding(.vertical, message.role == .user ? 8 : 0)
            .background {
                if message.role == .user {
                    // Content, not chrome — a plain fill rather than glass. iOS
                    // 26 reserves material for the navigation layer.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.tint.opacity(0.15))
                }
            }
            .frame(maxWidth: 560, alignment: message.role == .user ? .trailing : .leading)
    }

    private func note(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func affordance(_ title: String, icon: String, note title2: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            note(title2, icon: "exclamationmark.circle")
            Button(title, systemImage: icon) { Task { await onRegenerate() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// The branch switcher's entry point — shown only where there is another
    /// branch to reach, which is what `siblings(of:)` being non-empty means.
    ///
    /// **DoD-1 depends on this existing**: the hero GIF requires the interrupted
    /// partial to be "reachable via the branch switcher", which is why cut
    /// line 1 (hide the switcher) was retired rather than invoked.
    @ViewBuilder
    private var footer: some View {
        if siblingCount > 0 {
            Button {
                onShowBranches()
            } label: {
                Label("\(siblingCount + 1) versions", systemImage: "arrow.trianglehead.branch")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

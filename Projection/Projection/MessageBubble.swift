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

struct MessageBubble: View {

    let message: Message
    /// This message's position among its versions, and how many there are —
    /// `0`/`1` for a message that was never regenerated.
    let versionIndex: Int
    let versionCount: Int
    let onRegenerate: () async -> Void
    let onSelectVersion: (Int) -> Void

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

    /// **The showpiece: five cases, no `default`.** Add a case to `MessageState`
    /// and this stops compiling until someone decides what the new state looks
    /// like — tenet 1 paying out at the last possible layer.
    ///
    /// It returns *how to present* the message rather than the presentation
    /// itself, and that indirection is load-bearing rather than stylistic: it
    /// gives the assistant's renderer **exactly one call site** downstream, which
    /// is what keeps its view identity stable across the
    /// waiting → streaming → settled boundaries. Building the renderer inside
    /// three different branches made it three different views, and SwiftUI
    /// rebuilt it at every hand-off (see `AssistantMarkdown`).
    ///
    /// It also reads better as documentation: the mapping from state to
    /// treatment is now a table rather than a pile of view code.
    private var presentation: Presentation {
        switch message.state {
        case .complete(let content):
            Presentation(text: content.text)

        case .streaming(let partial):
            // The live case, and the only one no fold can produce (§6.2). An
            // empty partial is a generation that has started and not yet spoken
            // — §6.2 deliberately has no separate `.pending` — and
            // `AssistantMarkdown` shows the typing indicator for exactly that.
            Presentation(text: partial, isStreaming: true)

        case .interrupted(let partial):
            // What a crash looks like on reload: the fold found no terminal
            // (I5). Nothing repaired anything — this is simply what the log
            // says.
            Presentation(
                text: partial,
                affordance: .init(title: "Regenerate", icon: "arrow.clockwise", note: "Interrupted")
            )

        case .cancelled(let partial):
            Presentation(text: partial, note: .init(title: "Stopped", icon: "stop.circle"))

        case .failed(let partial, let error, let recoverability):
            // **The affordance comes from `Recoverability`, never from the
            // error.** §8's whole contract: the app switches over what it can
            // *do*, not over what went wrong.
            Presentation(
                text: partial,
                affordance: Self.affordance(for: recoverability),
                errorDetail: String(describing: error)
            )
        }
    }

    /// **§8's contract, as a total function.** The affordance comes from
    /// `Recoverability` and never from the error: the app switches over what the
    /// user can *do*, not over what went wrong. Exhaustive, no `default` — a new
    /// `RequiredAction` stops this compiling.
    private static func affordance(for recoverability: Recoverability) -> Presentation.Badge {
        switch recoverability {
        case .retryable(let after):
            .init(title: after == nil ? "Retry" : "Retry shortly",
                  icon: "arrow.clockwise", note: "Failed")
        case .recoverableUpstream(.enableAppleIntelligence):
            .init(title: "Open Settings", icon: "gear", note: "Apple Intelligence is off")
        case .recoverableUpstream(.awaitModelDownload):
            .init(title: "Try again", icon: "arrow.down.circle",
                  note: "The model is still downloading")
        case .recoverableUpstream(.reduceContext):
            // Kept even though the demo never approaches the window (M8-PLAN
            // D54): its *presence* is the demo of §8's contract, and on-device
            // the 4096-token budget makes it reachable in two substantial turns.
            .init(title: "Shorten and retry", icon: "scissors",
                  note: "This conversation is too long")
        case .recoverableUpstream(.reauthenticate):
            .init(title: "Sign in again", icon: "person.badge.key",
                  note: "Credentials need attention")
        case .terminal:
            .init(title: "Regenerate", icon: "arrow.triangle.2.circlepath", note: "Failed")
        }
    }

    @ViewBuilder
    private var content: some View {
        let presentation = presentation

        // **Markdown for the assistant, plain text for the user.** What a person
        // typed is not Markdown source and should not be reinterpreted as it — a
        // user asking about `**` would otherwise watch their own message turn
        // bold.
        if message.role == .assistant {
            // The one call site. Everything above decided *what* to show here.
            AssistantMarkdown(text: presentation.text, isStreaming: presentation.isStreaming)
                .frame(maxWidth: 560, alignment: .leading)
        } else {
            text(presentation.text)
        }

        if let note = presentation.note {
            self.note(note.title, icon: note.icon)
        }
        if let affordance = presentation.affordance {
            self.affordance(affordance.title, icon: affordance.icon, note: affordance.note)
        }
        if let detail = presentation.errorDetail {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    /// What one message looks like, independent of how it is drawn.
    private struct Presentation {
        struct Badge {
            var title: String
            var icon: String
            var note: String = ""
        }

        var text: String
        var isStreaming: Bool = false
        var note: Badge?
        var affordance: Badge?
        var errorDetail: String?
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

    /// **The branch switcher** — shown only where there is another version to
    /// reach, which is what more than one sibling means.
    ///
    /// **DoD-1 depends on this existing**: the hero GIF requires the interrupted
    /// partial to be "reachable via the branch switcher", which is why cut
    /// line 1 (hide the switcher) was retired rather than invoked. It is the
    /// visible proof of §6.4's central claim — that regenerate-as-sibling makes
    /// the crashed attempt *survive* rather than be overwritten.
    ///
    /// An inline pager rather than the sheet this started as: switching versions
    /// is a comparison, and a modal that covers the thing being compared is the
    /// wrong shape for it. `‹ 2 of 3 ›` is also what every LLM chat has
    /// converged on, so it needs no explaining.
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 14) {
            // **Regenerate a message that succeeded.** Easy to leave out, and its
            // absence is quietly serious: without it a sibling can only ever be
            // created by a *failure*, so the branch switcher below — and with it
            // DoD-1's whole "the partial survives as its own branch" claim —
            // would almost never appear. §6.4's regenerate-as-sibling is a
            // feature of healthy conversations, not an error path.
            //
            // Suppressed where the state already offers its own Regenerate, so
            // an interrupted message does not carry two of them.
            if showsRegenerate {
                Button {
                    Task { await onRegenerate() }
                } label: {
                    Image(systemName: "arrow.trianglehead.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Regenerate")
            }

            versionPager
        }
    }

    /// Whether the state already carries its own Regenerate affordance.
    private var showsRegenerate: Bool {
        guard message.role == .assistant else { return false }
        switch message.state {
        case .complete, .cancelled: return true
        case .streaming, .interrupted, .failed: return false
        }
    }

    @ViewBuilder
    private var versionPager: some View {
        if versionCount > 1 {
            HStack(spacing: 4) {
                step(-1, "chevron.left", enabled: versionIndex > 0)
                Text("\(versionIndex + 1) of \(versionCount)")
                    .font(.caption.monospacedDigit())
                    // Monospaced digits so the row does not twitch as the
                    // numbers change width under the user's thumb.
                    .foregroundStyle(.secondary)
                step(+1, "chevron.right", enabled: versionIndex < versionCount - 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Version \(versionIndex + 1) of \(versionCount)")
        }
    }

    private func step(_ delta: Int, _ icon: String, enabled: Bool) -> some View {
        Button {
            onSelectVersion(versionIndex + delta)
        } label: {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
        .disabled(!enabled)
        .accessibilityLabel(delta < 0 ? "Previous version" : "Next version")
    }
}

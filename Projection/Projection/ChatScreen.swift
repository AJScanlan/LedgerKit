import LedgerKit
import SwiftUI

// M8 Phase 2 — one conversation.
//
// **The screen owns its projection** (M8-PLAN D51). Attaching reads the log, so
// the initializer is `async throws` and this is where an app pays for that —
// once, in `.task`, which is already a suspending context. The reward is that
// `projection.conversation` is non-optional at every render site below.
//
// The screen holds **no** conversation state of its own. Everything on screen is
// `projection.conversation`, which is a fold of the log plus liveness — so there
// is no second copy of the truth to fall out of sync with the first.

@available(macOS 27.0, iOS 27.0, *)
struct ChatScreen: View {

    let model: AppModel
    let conversation: ConversationID

    @Environment(\.dismiss) private var dismiss
    @State private var projection: ConversationProjection?
    @State private var draft = ""
    @State private var branchOptions: BranchOptions?
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            if let projection {
                transcript(projection)
            } else {
                // Attaching is a *read*, so it can take a moment and can fail.
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(projection?.conversation.title ?? "New conversation")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: conversation) {
            // `id:` matters: on iPad and Mac this screen is reused as the
            // selection changes, so without it the projection would stay
            // attached to the conversation the user navigated *away* from.
            projection = try? await ConversationProjection(of: conversation, in: model.store)
        }
    }

    // MARK: - Transcript

    private func transcript(_ projection: ConversationProjection) -> some View {
        // Read once per body pass rather than per row: `activeMessages` is a
        // computed walk of the active path, so touching it inside `ForEach`'s
        // argument *and* again in a count would do the work twice.
        let messages = projection.conversation.activeMessages

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(messages) { message in
                    MessageBubble(
                        message: message,
                        siblingCount: projection.conversation.messages.siblings(of: message.id).count,
                        onRegenerate: { await model.regenerate(message.id, in: conversation) },
                        onShowBranches: { showBranches(for: message, in: projection) }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        // Chat reads bottom-up: newest content should be on screen when the
        // view appears, without a scroll animation the user did not ask for.
        .defaultScrollAnchor(.bottom)
        // **`safeAreaBar`, not `safeAreaInset` and not a `ZStack` overlay.**
        // New in iOS 26 and the difference is not cosmetic: a bar declared this
        // way participates in the scroll edge effect, so content passing behind
        // the composer gets the system's treatment rather than sliding under an
        // opaque rectangle.
        .safeAreaBar(edge: .bottom) {
            ChatComposer(
                draft: $draft,
                isGenerating: isGenerating(messages),
                focused: $composerFocused,
                onSend: send,
                onStop: { Task { await model.stop(in: conversation) } }
            )
        }
        .toolbar { toolbar(projection) }
        .onChange(of: projection.isDeleted) { _, isDeleted in
            // §9's deletion is irreversible and out-of-band, and rev 10 says the
            // read side is *told* rather than left to infer it from a failed
            // read. This is what being told is for.
            if isDeleted { dismiss() }
        }
        .confirmationDialog(
            "Switch to another version",
            isPresented: Binding(get: { branchOptions != nil }, set: { if !$0 { branchOptions = nil } }),
            presenting: branchOptions
        ) { options in
            ForEach(options.siblings) { sibling in
                Button(preview(of: sibling)) {
                    Task { await model.switchBranch(to: sibling.id, in: conversation) }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ projection: ConversationProjection) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Conversation", systemImage: "ellipsis") {
                Button("Rename…", systemImage: "pencil") { /* TODO(design) */ }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await model.delete(conversation) }
                }
                if !projection.conversation.diagnostics.isEmpty {
                    Section("Diagnostics") {
                        // Empty on every healthy log (§6.5). Surfaced because a
                        // non-empty `diagnostics` means damage, a partial
                        // restore, or a *newer* LedgerKit having written this
                        // log — and a demo that hid that would be hiding the
                        // most interesting sentence the reducer says.
                        ForEach(projection.conversation.diagnostics, id: \.sequence) { problem in
                            Text(String(describing: problem))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await model.send(text, in: conversation) }
    }

    /// Whether a generation is live, **derived from the projection rather than
    /// tracked separately.**
    ///
    /// A second `isGenerating` flag would be a copy of the truth that can drift
    /// from it — and `.streaming` is a state no fold of any log can produce
    /// (§6.2), so its presence *is* the store telling us this process is
    /// generating. That includes a generation which has started and not yet
    /// spoken, which renders `.streaming(partial: "")`.
    private func isGenerating(_ messages: [Message]) -> Bool {
        if case .streaming = messages.last?.state { true } else { false }
    }

    private func showBranches(for message: Message, in projection: ConversationProjection) {
        let siblings = projection.conversation.messages.siblings(of: message.id)
        guard !siblings.isEmpty else { return }
        branchOptions = BranchOptions(siblings: siblings)
    }

    private func preview(of message: Message) -> String {
        let text = switch message.state {
        case .complete(let content): content.text
        case .streaming(let partial), .interrupted(let partial),
             .cancelled(let partial), .failed(let partial, _, _): partial
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Empty version" : String(trimmed.prefix(48))
    }

    /// `confirmationDialog(presenting:)` wants an `Identifiable`, and wrapping
    /// the siblings gives the dialog a stable identity across presentations.
    private struct BranchOptions: Identifiable {
        let siblings: [Message]
        var id: MessageID? { siblings.first?.id }
    }
}

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
    @State private var renameRequest: RenameRequest?
    @FocusState private var composerFocused: Bool

    /// Measured heights, keyed by message — the inputs to `trailingSpace`.
    @State private var heights: [MessageID: CGFloat] = [:]
    @State private var viewportHeight: CGFloat = 0

    private static let messageSpacing: CGFloat = 20

    /// The visible gap between the navigation bar and an anchored question.
    /// **The number to turn** if it rests too high or too low.
    private static let anchorLead: CGFloat = 24

    /// What `scrollTo(_:anchor:)` costs before the gap above is even applied —
    /// **measured, not reasoned about**, after two corrections that guessed wrong.
    ///
    /// Instrumenting the real geometry showed the scroll view's visible top at
    /// `y = 116` and the anchored row settling at `y = 112` *with* a 28 pt lead
    /// already applied — so with no lead at all the row lands at 84, a full
    /// **32 pt above the visible top**. `scrollTo` resolves against content
    /// coordinates that include the stack's own top padding and the inter-message
    /// spacing, and neither is visible from the API.
    ///
    /// Kept separate from ``anchorLead`` rather than folded into one number,
    /// because the two mean different things: this is a fixed property of the
    /// layout, that is a design choice. Adjusting the gap should not require
    /// re-deriving the correction.
    private static let anchorCorrection: CGFloat = 32

    /// How far the anchored question should sit below the scroll view's visible
    /// top, in the coordinates both the scroll target *and* the reserved space
    /// have to agree on.
    ///
    /// ⚠️ **They must use the same value, and finding that out took measuring.**
    /// For a short answer the requested scroll is unsatisfiable — there is not
    /// enough content below the question to scroll it that far — so the position
    /// clamps and is decided entirely by how much trailing space exists. Two
    /// instrumented runs made the relationship exact: the spacer grew by 36 pt and
    /// the row rose by 36 pt, one for one. For a *long* answer the spacer is zero
    /// and the anchor governs instead. Feed them different numbers and the
    /// question rests in two different places depending on how much the model
    /// happened to say.
    private static var anchorOffset: CGFloat { anchorLead + anchorCorrection }

    /// Converts ``anchorLead`` into the `UnitPoint` `scrollTo` wants.
    ///
    /// `scrollTo(_:anchor:)` resolves its anchor as a **fraction of the row's own
    /// height**, so a fixed point value cannot be handed to it directly. A
    /// negative fraction resolves to a position *above* the row, which is exactly
    /// "stop short by this much" — and dividing by the row's measured height is
    /// what makes the result a constant number of points rather than something
    /// that drifts with how tall the question happens to be.
    ///
    /// The fallback is one line of chat; it is only ever used on the first frame
    /// of a brand-new message, before `onGeometryChange` has reported.
    private static func anchorPoint(forRowOfHeight height: CGFloat?) -> UnitPoint {
        let measured = max(height ?? 44, 1)
        return UnitPoint(x: 0, y: -anchorOffset / measured)
    }

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

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.messageSpacing) {
                    ForEach(messages) { message in
                        let versions = versions(of: message, in: projection.conversation)
                        MessageBubble(
                            message: message,
                            versionIndex: versions.firstIndex(of: message.id) ?? 0,
                            versionCount: versions.count,
                            onRegenerate: { await model.regenerate(message.id, in: conversation) },
                            onSelectVersion: { index in
                                guard versions.indices.contains(index) else { return }
                                Task { await model.switchBranch(to: versions[index], in: conversation) }
                            }
                        )
                        .id(message.id)
                        // Only the streaming message's height actually changes,
                        // because `onGeometryChange` fires on change alone — so
                        // settled rows cost one write each and then go quiet.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            heights[message.id] = height
                        }
                    }

                    // **The room the answer grows into.** See `trailingSpace`.
                    Color.clear
                        .frame(height: trailingSpace(for: messages))
                        .allowsHitTesting(false)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            // ⚠️ **Not `contentMargins`.** Insetting the scroll content was the
            // obvious fix and was wrong twice: it pushed every conversation's
            // first message away from the navigation bar, and it moved the
            // anchored question *further* under the bar rather than clear of it,
            // because the inset shifts the offset `scrollTo` resolves against.
            // The lever that works is the anchor itself — see below.
            //
            // Governs where an *existing* conversation opens — at the bottom,
            // with no animation nobody asked for. The send-time positioning
            // below is explicit and takes over from there.
            .defaultScrollAnchor(.bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .onChange(of: latestUserMessage(in: messages)) { _, anchor in
                // **The Claude behaviour**: on send, the question rises to the
                // top and the answer fills the space beneath it, rather than the
                // question being shoved upward by text arriving under it.
                //
                // Only fires when the *user* message identity changes, so a
                // regeneration or a branch switch does not yank the view.
                guard let anchor else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(anchor, anchor: Self.anchorPoint(forRowOfHeight: heights[anchor]))
                }
            }
        }
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
        .renameConversation($renameRequest) { id, title in
            Task { await model.setTitle(title, in: id) }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ projection: ConversationProjection) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Conversation", systemImage: "ellipsis") {
                Button("Rename…", systemImage: "pencil") {
                    renameRequest = RenameRequest(
                        id: conversation,
                        currentTitle: projection.conversation.title
                    )
                }
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

    /// Every version of a message, in sibling order, **including the message
    /// itself** — what a `‹ 2 of 3 ›` pager needs.
    ///
    /// ⚠️ **API friction worth recording for M9's review.** `siblings(of:)`
    /// deliberately *excludes* the message — matching the English word, and its
    /// doc even says "non-empty exactly when a branch switcher is warranted" — so
    /// the one consumer the method anticipates cannot use it directly. Building a
    /// pager needs the inclusive, ordered set *and* the current message's index
    /// in it, which forces reaching past `siblings(of:)` to `parent` +
    /// `children(of:)`, and special-casing the virtual root through
    /// `rootChildren` (I6). Nothing here is wrong; it is a missing convenience
    /// that the library's own documentation implies exists.
    private func versions(of message: Message, in conversation: Conversation) -> [MessageID] {
        if let parent = message.parent {
            conversation.messages.children(of: parent).map(\.id)
        } else {
            // Root-level messages are children of the virtual root, which is not
            // a message and so has no `children(of:)` to ask (I6). An edited
            // first message legitimately has root-level siblings.
            conversation.messages.rootChildren
        }
    }

    /// The most recent user message — the thing the answer is an answer *to*,
    /// and therefore what should be at the top of the screen while it arrives.
    private func latestUserMessage(in messages: [Message]) -> MessageID? {
        messages.last { $0.role == .user }?.id
    }

    /// Blank space below the transcript, sized so the latest question can sit at
    /// the top of the viewport with its answer beneath it.
    ///
    /// ## Why a spacer rather than a scroll animation
    ///
    /// Scrolling the question to the top is only *possible* if there is enough
    /// content beneath it to scroll — at the moment of sending there is almost
    /// none, so the scroll would have nothing to move into. This manufactures
    /// exactly the shortfall.
    ///
    /// **And it is what keeps the question still afterwards.** The spacer shrinks
    /// by precisely as much as the answer grows, so total content height is
    /// constant while the response streams and nothing above it moves. That is
    /// the whole difference from an ordinary chat transcript, where arriving text
    /// pushes the question upward — and it falls out of the arithmetic rather
    /// than needing a second animation to counteract the first.
    ///
    /// Once the answer outgrows the reserved space this reaches zero and normal
    /// bottom-anchored scrolling resumes, which is the right behaviour for a long
    /// reply: the reading position should follow the text.
    private func trailingSpace(for messages: [Message]) -> CGFloat {
        guard viewportHeight > 0,
              let anchor = latestUserMessage(in: messages),
              let start = messages.firstIndex(where: { $0.id == anchor })
        else { return 0 }

        let turn = messages[start...]
        let content = turn.reduce(CGFloat.zero) { $0 + (heights[$1.id] ?? 0) }
        let gaps = CGFloat(turn.count - 1) * Self.messageSpacing

        // **Deliberately the same constant that positions the question**, not a
        // second number that happens to look similar: the room to reserve below
        // the question is exactly the viewport minus where the question starts.
        // Two independent values would drift, and the symptom would be a strip of
        // dead space under a finished answer.
        return max(0, viewportHeight - Self.anchorOffset - content - gaps)
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

}

import LedgerKit
import SwiftUI

// M8 Phase 2 — the conversation list (G9).
//
// **A table read, not N reductions.** Each row is a `ConversationSummary` from
// the store's index, so opening a list of five hundred conversations costs one
// query rather than five hundred folds. The list also does not churn while a
// generation streams: the index is maintained on non-delta appends only (§9), so
// a streaming conversation moves nothing here — no reordering, no reload.
//
// `NavigationSplitView` rather than `NavigationStack`, deliberately: it is the
// shape Mail and Messages use, it collapses to a push-pop stack on iPhone
// without any conditional code, and it gives iPad and Mac a real sidebar for
// free. Choosing the stack would have to be undone the first time this app runs
// anywhere but a phone.

struct ConversationListScreen: View {

    let model: AppModel

    @State private var list: ConversationListProjection?
    @State private var selection: ConversationID?
    @State private var pendingDeletion: ConversationSummary?
    @State private var renameRequest: RenameRequest?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selection {
                ChatScreen(model: model, conversation: selection)
                    // Rebuild the screen when the selection changes rather than
                    // letting SwiftUI reuse it: a chat screen is *about* one
                    // conversation, and its projection, draft and focus should
                    // not survive a move to a different one.
                    .id(selection)
            } else {
                ContentUnavailableView(
                    "No conversation selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a conversation, or start a new one.")
                )
            }
        }
        .task {
            list = try? await ConversationListProjection(in: model.store)
        }
        // D55's rendered throw channel. `LedgerError`'s `description` is
        // explicitly **non-contractual** (ADR-001), so this shows it for triage
        // and never matches on it.
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            ),
            presenting: model.presentedError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(String(describing: error))
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if let list {
                if list.conversations.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations", systemImage: "bubble.left")
                    } description: {
                        Text("Start one to see how a ledger-backed chat behaves.")
                    } actions: {
                        Button("New conversation", action: newConversation)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    conversations(list)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Projection")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New conversation", systemImage: "square.and.pencil", action: newConversation)
            }
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { summary in
            Button("Delete", role: .destructive) {
                Task { await delete(summary.id) }
            }
        } message: { _ in
            // Worth saying plainly: §9 makes conversation delete a transactional
            // DELETE of the log, its snapshots and its index row. There is no
            // tombstone and no undo.
            Text("This permanently deletes the conversation and its history.")
        }
        .renameConversation($renameRequest) { id, title in
            Task { await model.setTitle(title, in: id) }
        }
    }

    private func conversations(_ list: ConversationListProjection) -> some View {
        List(list.conversations, selection: $selection) { summary in
            NavigationLink(value: summary.id) {
                // The row takes only the fields it renders, not the projection —
                // so editing one conversation's title cannot invalidate rows
                // that display a different one.
                ConversationRow(title: summary.title, lastEventAt: summary.lastEventAt)
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = summary
                }
                // Leading edge would put Rename under the swipe that usually
                // means "archive" elsewhere in iOS; keeping both on the trailing
                // edge matches Mail, where destructive sits outermost.
                Button("Rename", systemImage: "pencil") {
                    renameRequest = RenameRequest(id: summary.id, currentTitle: summary.title)
                }
                .tint(.accentColor)
            }
            // The same action a long press offers, because a swipe is not
            // discoverable on its own and a context menu is where iOS users
            // look for "what else can I do to this row".
            .contextMenu {
                Button("Rename…", systemImage: "pencil") {
                    renameRequest = RenameRequest(id: summary.id, currentTitle: summary.title)
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = summary
                }
            }
        }
    }

    // MARK: - Actions

    private func newConversation() {
        Task {
            guard let created = await model.createConversation() else { return }
            selection = created
        }
    }

    private func delete(_ conversation: ConversationID) async {
        // Clear the selection *first*. `deleteConversation` cancels any
        // in-flight generation and then commits the DELETE (§9); the attached
        // projection is told via `isDeleted` and dismisses itself, but on a
        // split-view detail there is nothing to dismiss *to* — so the list is
        // the one that has to let go.
        if selection == conversation { selection = nil }
        await model.delete(conversation)
    }
}

/// One row. Takes the two fields it renders — the narrow-input rule, which for
/// value types is what keeps a row from invalidating on unrelated changes.
private struct ConversationRow: View {

    let title: String?
    let lastEventAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? "New conversation")
                .lineLimit(1)
            Text(lastEventAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

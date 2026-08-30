import LedgerKit
import SwiftUI

// Renaming, in the one shape iOS has settled on: an alert with a text field.
//
// Apple uses this for the same job across Files, Shortcuts and Notes, so it is
// the answer least in need of explaining — and it keeps the transcript visible
// behind it, which a sheet would not.
//
// Factored into a modifier because two screens want it: the list (renaming a row
// you are looking at) and the chat toolbar (renaming the thing you are reading).
// The alternative was two copies of the same small state machine, which is how
// they end up differing.

/// A conversation the user asked to rename, and what it is called now.
@available(macOS 27.0, iOS 27.0, *)
struct RenameRequest: Identifiable, Equatable {
    let id: ConversationID
    let currentTitle: String?
}

@available(macOS 27.0, iOS 27.0, *)
extension View {

    /// Presents the rename alert whenever `request` is non-nil.
    ///
    /// - Parameter onRename: Receives `nil` when the field is left empty —
    ///   **clearing rather than storing an empty string**. `titleChanged(nil)`
    ///   is how the wire format says "no title" (§6.1, symmetric with
    ///   instructions), and it is what makes the row fall back to "New
    ///   conversation" instead of rendering a blank line.
    func renameConversation(
        _ request: Binding<RenameRequest?>,
        onRename: @escaping (ConversationID, String?) -> Void
    ) -> some View {
        modifier(RenameConversationModifier(request: request, onRename: onRename))
    }
}

@available(macOS 27.0, iOS 27.0, *)
private struct RenameConversationModifier: ViewModifier {

    @Binding var request: RenameRequest?
    let onRename: (ConversationID, String?) -> Void

    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Conversation",
                isPresented: Binding(
                    get: { request != nil },
                    set: { if !$0 { request = nil } }
                ),
                presenting: request
            ) { target in
                TextField("Name", text: $draft)
                    // A title is a name, not prose: no autocapitalised sentence,
                    // no autocorrect second-guessing a deliberate choice.
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif

                Button("Rename") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    onRename(target.id, trimmed.isEmpty ? nil : trimmed)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Leave the name empty to clear it.")
            }
            // Seed the field from the current title each time the alert opens,
            // rather than once: the same modifier serves every row in a list, so
            // a draft left over from the last rename would be offered for the
            // next one.
            .onChange(of: request) { _, target in
                draft = target?.currentTitle ?? ""
            }
    }
}

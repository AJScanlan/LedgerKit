import SwiftUI

// The message composer — the one control that is always on screen, so the one
// most worth getting right.
//
// **It lives in `safeAreaBar`, not in the scroll content and not in a `ZStack`.**
// That placement is what lets the keyboard, the home indicator and the scroll
// edge effect all behave without the app arranging any of it.
//
// ⚠️ **Deliberately unstyled.** This is the surface most likely to be redesigned,
// so it uses stock components and no custom materials: iOS 26 puts material on
// the navigation layer and a bar declared here already sits on it. Reach for
// `.glassEffect` only after checking it against the stock appearance on device —
// specular highlights and motion response do not render correctly in the
// Simulator, so a glass decision made from a screenshot is a decision made blind.

@available(macOS 26.0, iOS 26.0, *)
struct ChatComposer: View {

    @Binding var draft: String
    let isGenerating: Bool
    @FocusState.Binding var focused: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                // A capped range keeps a long draft from eating the transcript
                // while still growing for a paragraph — the iMessage behaviour.
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(onSend)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: .capsule)

            // **Send and Stop are one control in two states, not two controls.**
            // §7.5 gives cancellation its own semantics — cancelled is neither
            // failed nor interrupted — and a stop button that only appears
            // mid-stream is how a user discovers that stopping is a real,
            // recorded outcome rather than an abandonment.
            Button {
                isGenerating ? onStop() : onSend()
            } label: {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend && !isGenerating)
            .accessibilityLabel(isGenerating ? "Stop generating" : "Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

import SwiftUI

/// The "generating" placeholder — shown for a generation that has started and
/// has not yet produced a character.
///
/// **This is `.streaming(partial: "")` given a face.** §6.2 deliberately refuses
/// a separate `.pending` state on the grounds that it would have no distinct UI
/// meaning; an empty partial *is* the pending state. That argument holds right up
/// until the app has to draw something, and what it should draw is not empty text
/// — it is the same signal Messages shows for a contact who is typing.
///
/// It disappears the instant the first character arrives, rather than growing a
/// caret: once there is text, the text is the evidence that something is
/// happening, and a second indicator alongside it would be redundant motion.
struct TypingIndicator: View {

    static let indicatorHeight: CGFloat = 29

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    private let dotSize: CGFloat = 7
    private let period = 0.65

    var body: some View {
        HStack(spacing: 5) {
            dot(delay: 0)
            dot(delay: 0.15)
            dot(delay: 0.30)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(height: Self.indicatorHeight)
        .background(.quaternary.opacity(0.55), in: .capsule)
        // One label for the group, not three: VoiceOver should say what is
        // happening, not enumerate the decoration that says it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Generating a response")
        .onAppear { animating = true }
    }

    private func dot(delay: Double) -> some View {
        Circle()
            .fill(.secondary)
            .frame(width: dotSize, height: dotSize)
            // **Opacity and scale together.** Opacity alone reads as a flicker at
            // small sizes; the slight scale is what makes it read as a pulse.
            .opacity(animating ? 1 : 0.3)
            .scaleEffect(animating ? 1 : 0.72)
            .animation(motion.delay(delay), value: animating)
    }

    /// **Reduced Motion turns this off rather than reinterpreting it.**
    ///
    /// Apple's guidance is that a repeating animation is exactly the kind of
    /// motion the setting exists to suppress — and this one has no informational
    /// content the static shape does not already carry: three dots in a bubble
    /// mean "working on it" whether or not they pulse.
    private var motion: Animation {
        reduceMotion
            ? .default
            : .easeInOut(duration: period).repeatForever(autoreverses: true)
    }
}

// `accessibilityReduceMotion` is read-only in the environment — it mirrors a
// system setting rather than something a view can assert — so the reduced-motion
// branch is checked by toggling Settings ▸ Accessibility ▸ Motion in the
// Simulator, not by a second preview.
#Preview("Typing indicator") {
    TypingIndicator()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
}

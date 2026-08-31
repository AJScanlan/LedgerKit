import LedgerKit
import SwiftStreamingMarkdown
import SwiftUI

// **Spike (M8 Phase 2):** render assistant turns as Markdown, and animate newly
// arrived text, by handing LedgerKit's partials to `SwiftStreamingMarkdown`.
//
// ## Why the two libraries meet so cleanly
//
// `StreamedMarkdownSource.text` is an `AsyncStream<String>` whose every emission
// must be **"the complete Markdown source so far, not an incremental delta"** —
// which is exactly, and not coincidentally, what LedgerKit hands us.
// `MessageState.streaming(partial:)` carries the whole partial, and the store's
// feed was deliberately designed the same way (M7-PLAN D47: *a delta carries the
// cumulative partial, never a suffix*), because a suffix would have to be
// reconciled against the base on every re-pull. Two independent designs reached
// the same conclusion, so the adapter below is a `yield` rather than an
// accumulator.
//
// ## What that buys, concretely
//
// The stream can use `.bufferingNewest(1)` and **drop intermediate snapshots
// under back-pressure without losing a character** — because each snapshot
// contains everything before it. With suffix-deltas that same policy would
// silently corrupt the text. The cumulative choice is what makes dropping safe.

/// Bridges LedgerKit's *pull* model (SwiftUI re-reads `projection.conversation`)
/// to SwiftStreamingMarkdown's *push* model (an `AsyncStream` it consumes).
///
/// Held in `@State` by the view below, because `StreamedMarkdownView` captures
/// its source in a `@StateObject` at init and never re-reads it — so the source
/// has to outlive every body evaluation of its owner, and a fresh one per body
/// pass would leave the view consuming a stream nobody writes to.
/// ## Why this paces rather than forwards
///
/// **Microsoft's own LLM-chat sample does not stream a model.** It replays a
/// finished string at a fixed cadence — `chunkSize = 3` characters every `30 ms`,
/// roughly **100 characters per second** — and that constant, gentle rate is the
/// entire reason it looks calm. Forwarding a real provider's partials straight
/// through cannot look like that, for two reasons that compound:
///
/// - **Too fast.** The on-device model outruns 100 ch/s comfortably.
/// - **Lumpy.** The framework coalesces snapshots on its own cadence (measured
///   at M6: three emissions arriving as one) and §7.4's flush policy reshapes
///   them again, so text lands in irregular jumps. No per-character animation can
///   smooth a lump that arrives in a single frame — by the time the renderer sees
///   it, it is already one edit.
///
/// So the fix is not a nicer animation, it is **decoupling display rate from
/// arrival rate**: hold the newest partial as a *target*, and release a prefix of
/// it at a steady rate.
///
/// **This is only sound because partials are cumulative and monotonic.** Showing
/// a prefix of the latest known partial is always a state the conversation really
/// passed through — the third time D47's cumulative choice has paid for itself in
/// this file.
@MainActor
@Observable
final class StreamingPartialSource: StreamedMarkdownSource {

    /// Characters released per tick, and the tick itself — Microsoft's sample's
    /// numbers, because they are demonstrably calm and there is no reason to
    /// invent different ones.
    private static let charactersPerTick = 3
    private static let tick = Duration.milliseconds(30)

    /// Above this backlog the pacer stops being polite and starts catching up.
    ///
    /// Without it a fast provider leaves the display arbitrarily far behind, and
    /// the text would still be typing itself out long after the generation ended
    /// — which reads as a hang, not as calm. `120` characters is about 1.2 s of
    /// backlog at the base rate: enough that ordinary streaming never trips it,
    /// small enough that a burst drains before anyone reads the end.
    private static let comfortableBacklog = 120

    let text: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    /// The newest partial LedgerKit has given us — what the log says right now.
    private var target = ""
    /// How much of the target has been **released to the renderer** — which is
    /// not the same as how much is on screen, and conflating the two caused a
    /// visible jump.
    ///
    /// ⚠️ Releasing is a `yield`; the renderer then has to consume it, parse the
    /// Markdown and lay out, all of which lands some frames later. So this goes
    /// positive *before* the first character appears. Anything that must not
    /// happen until text is genuinely visible cannot key on it — see
    /// `AssistantMarkdown`, which keeps the indicator's height reserved for the
    /// whole streaming phase rather than dropping it here.
    private(set) var shown = 0
    /// Set when the generation ends. The pump keeps going until the backlog is
    /// gone, *then* closes the stream — see ``completeWhenDrained()``.
    private var isCompleting = false
    private var pump: Task<Void, Never>?

    /// Whether the pacer has released anything yet. **Not** whether anything is
    /// on screen — see ``shown``.
    var hasReleasedText: Bool { shown > 0 }

    init() {
        // See the file note: `.bufferingNewest(1)` is safe only because every
        // emission is cumulative.
        (text, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        // Inherits this class's `@MainActor` isolation, so `release()` is a
        // direct call — the pump and the `update(_:)` it races are on the same
        // actor, which is what makes `target`/`shown` safe without a lock.
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self else { return }
                self.release()
            }
        }
    }

    deinit {
        // A stream that is never finished leaves its consumer suspended forever.
        //
        // The pump is deliberately *not* cancelled here — `deinit` is nonisolated
        // and `pump` is main-actor state, so touching it is a concurrency error.
        // It needs no cancelling: the loop holds `[weak self]` and returns the
        // first time it wakes to find the source gone, so it retires one tick
        // after the view does.
        continuation.finish()
    }

    /// Adopts whatever text already exists, **without pacing it**, and decides
    /// whether anything more is coming.
    ///
    /// ⚠️ **The rule that makes this correct: pace only what arrives *after* the
    /// view is watching.** Text that was already there was not streamed to us —
    /// it was read from the log — and typing it out would be theatre, not
    /// feedback. Without this, opening an existing conversation replayed every
    /// answer at 100 ch/s, and so did switching branches, because the pacer had
    /// no way to tell "this is new" from "this is history".
    ///
    /// Three cases, one line each, and they are the same line:
    /// - **A fresh generation** starts with `text == ""`, so nothing is adopted
    ///   and everything that follows is paced. Unchanged.
    /// - **A settled message** adopts all of it and closes the stream — instant,
    ///   with no pump left running behind it.
    /// - **Attaching mid-generation** (scrolling a long conversation until a live
    ///   answer comes into view) adopts what has arrived so far and paces only
    ///   the rest, which is the behaviour §7.4 describes for a projection created
    ///   while a generation is streaming.
    func begin(with text: String, isStreaming: Bool) {
        target = text
        shown = text.count
        continuation.yield(text)
        if !isStreaming { finish() }
    }

    /// Records the newest partial. **Does not display it** — the pump does that.
    func update(_ partial: String) {
        guard partial != target else { return }
        // ⚠️ **The partial can get shorter**, and only in one situation: D50's
        // abandonment path, where a failed flush drops the shown text back to the
        // durable prefix. Clamping rather than interpolating is deliberate — the
        // pacer must not appear to *un-type* text, and there is nothing calm to
        // animate about content that was never durable.
        target = partial
        shown = min(shown, target.count)
    }

    /// The generation reached a terminal — **keep drawing until the backlog is
    /// gone**, then close the stream.
    ///
    /// This is what removes the second jump. Swapping to a fully-rendered view
    /// the instant the message settles discards whatever the pacer had not yet
    /// released, so the remaining text lands in one frame — a step change in
    /// content height, which a bottom-anchored scroll view turns into a visible
    /// lurch. Draining first means the last character arrives at the same
    /// cadence as every character before it, and nothing is ever *replaced*.
    func completeWhenDrained() {
        isCompleting = true
        // Already caught up: close now rather than waiting a tick.
        if target.count == shown { finish() }
    }

    func finish() {
        pump?.cancel()
        pump = nil
        continuation.finish()
    }

    /// Advances the visible prefix by one tick's worth.
    private func release() {
        let backlog = target.count - shown
        guard backlog > 0 else {
            // Drained. If the generation is over, this is the moment to stop —
            // a settled message must not keep a pump alive, and there are as
            // many settled messages as there are turns.
            if isCompleting { finish() }
            return
        }

        // Polite by default; proportional once the backlog stops being
        // comfortable, so lag decays instead of accumulating.
        let step = backlog > Self.comfortableBacklog
            ? max(Self.charactersPerTick, backlog / 4)
            : Self.charactersPerTick

        shown = min(target.count, shown + step)
        continuation.yield(String(target.prefix(shown)))
    }
}

/// **One view for an assistant turn's entire life** — waiting, streaming, and
/// settled.
///
/// ## Why it is one view and not three
///
/// It used to be three: `TypingIndicator`, then a streaming renderer, then a
/// static one. Each hand-off is an **identity change**, so SwiftUI tears the
/// subtree down and builds the next at whatever height it starts at — and with
/// `.defaultScrollAnchor(.bottom)` every height discontinuity shoves the whole
/// transcript. That produced two visible lurches:
///
/// 1. the indicator's ~40 pt collapsing to a not-yet-populated renderer, and
/// 2. the pacer's drained prefix being replaced wholesale by the full text.
///
/// Animating the transitions could not have fixed either, because there is
/// nothing to interpolate *between*: the two subtrees are unrelated. Keeping one
/// view means the renderer is never rebuilt, its height only ever grows, and it
/// grows one tick at a time.
///
/// The indicator becomes an **overlay** on that stable view rather than a
/// replacement for it, and it retires on the first *displayed* character — not
/// the first *arrived* one, which would leave a gap while the pacer holds text
/// back.
@available(macOS 27.0, iOS 27.0, *)
struct AssistantMarkdown: View {

    static let config = MarkdownRenderConfig.default
        .withShouldAnimateText(value: false)

    /// The partial while streaming; the final text once settled.
    let text: String
    /// Whether the generation is still running (`MessageState.streaming`).
    let isStreaming: Bool

    @State private var source = StreamingPartialSource()

    var body: some View {
        StreamedMarkdownView(source: source, config: Self.config)
            // **Reserved for the whole streaming phase, not just until the first
            // release** — your commented-out fix, made permanent with its reason.
            //
            // Keying this on "has text been released" looked right and was wrong:
            // releasing is a `yield`, and the renderer consumes, parses and lays
            // out some frames later, so the reservation dropped while the view was
            // still empty and the transcript lurched. Holding it until the
            // generation *ends* costs nothing — by then the text is far taller
            // than the indicator, so letting go changes no layout — and it avoids
            // reserving 29 pt under settled messages, which holding it forever
            // would do to every empty terminal bubble.
            .frame(minHeight: isStreaming ? TypingIndicator.indicatorHeight : 0,
                   alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if isStreaming && !source.hasReleasedText {
                    TypingIndicator().transition(.opacity)
                }
            }
            // The same frames-of-lag argument applies to the indicator itself: a
            // hard removal blinks it out before any glyph replaces it. A short
            // cross-fade covers the parse.
//            .animation(.easeOut(duration: 0.2), value: source.hasReleasedText)
            // Adopt what is already there; pace only what comes after.
            .onAppear { source.begin(with: text, isStreaming: isStreaming) }
            .onChange(of: text) { _, updated in source.update(updated) }
            .onChange(of: isStreaming) { _, streaming in
                // Terminal reached. Let the pacer finish what it is holding
                // rather than snapping to the full text.
                if !streaming { source.completeWhenDrained() }
            }
            .onDisappear { source.finish() }
    }
}

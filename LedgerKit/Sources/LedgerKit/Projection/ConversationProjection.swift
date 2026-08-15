import Foundation
import Observation
import Synchronization

/// One conversation, observable and always current — the read side of the ledger
/// (SPEC §6.2, §7.4, §11).
///
/// ```swift
/// let projection = try await ConversationProjection(of: convo.id, in: store)
///
/// ForEach(projection.conversation.activeMessages) { message in
///     switch message.state {
///     case .streaming(let partial):   StreamingBubble(partial)
///     case .interrupted(let partial): InterruptedBubble(partial, onRegenerate: …)
///     …
///     }
/// }
/// ```
///
/// ## What it is
///
/// §7.4's formula, running:
/// `overlay_live( reduce(persistedLog ++ unflushedTail, mapping) )`. The store
/// tells this object what changed; it re-reduces and applies liveness, so a
/// streaming generation renders `.streaming` at **display** cadence while the log
/// fills at **durability** cadence. Those are two different clocks on purpose
/// (§7.4), and the delta path here never waits for a disk flush.
///
/// ## What it is not
///
/// Derived, rebuildable and deletable — tenet 2 applied to the read side. Throwing
/// this object away and making another loses nothing, because the log is the truth
/// and this holds no state that is not a function of it. There is deliberately no
/// `refresh()`, no `reload()`, and no way to set `conversation`: everything arrives
/// from the store or it does not exist.
///
/// ## Recovery is the absence of a feature
///
/// After process death the live set is vacuously empty, the overlay is the identity,
/// and the fold's honest `.interrupted` shows through (§6.3's three-name table read
/// right-to-left). There is no recovery pass here to call, because there is nothing
/// to recover — which is the whole of G4.
@MainActor
@Observable
public final class ConversationProjection {

    /// The conversation as it should be displayed **right now** — reduced from the
    /// log, then overlaid with what this process is currently generating.
    ///
    /// Non-optional because ``init(of:in:mapping:displayCadence:)`` refuses a
    /// conversation that does not exist, so there is no "not loaded yet" state to
    /// represent. If it is later deleted, this keeps its last value and
    /// ``isDeleted`` becomes `true` — a frozen last view is more useful to a screen
    /// that is navigating away than a sudden absence, and it keeps every render site
    /// free of unwrapping.
    public private(set) var conversation: Conversation

    /// Whether the conversation has been deleted underneath this projection (§9).
    ///
    /// Deletion is irreversible and out-of-band — there is no log left to read — so
    /// this is terminal: once `true`, ``conversation`` will never change again. An
    /// app should navigate away. Surfaced as a property rather than left for the app
    /// to infer from a thrown read, because inferring a lifecycle fact from an error
    /// is the pattern tenet 1 exists to replace.
    public private(set) var isDeleted = false

    private let store: ConversationStore
    private let id: ConversationID
    private let mapping: RecoverabilityMapping
    private let displayCadence: Duration

    /// The dead-log answer, cached so a delta costs one overlay rather than a
    /// re-classification. Refreshed only on `.changed`.
    ///
    /// Internal for ``folded``'s reason — P2's `overlaying:` argument.
    private(set) var classified: Conversation
    /// The folded layer beneath it — needed to route a generation to its message
    /// when pruning the live set, which is a *folded* property (`generationID`).
    ///
    /// Internal rather than private for `ConversationStore.liveGenerations`' reason:
    /// it exists to be **observed**. P2's predicate takes `foldedFrom:` and `live:`,
    /// and it must be handed the very fold and live set this projection rendered
    /// from — reading them back off the store instead would check a different pair
    /// and quietly stop testing the projection.
    private(set) var folded: FoldedState
    private var messageForGeneration: [GenerationID: MessageID] = [:]
    /// What the store says is streaming, keyed by generation, each value the **whole**
    /// partial (D47). Never accumulated here — assigned.
    ///
    /// Internal for ``folded``'s reason: P2 checks the projection against the live
    /// set it actually used.
    private(set) var live: LiveSet = [:]

    /// Nonisolated so ``deinit`` can cancel it — see ``FeedHandle``.
    private let feed = FeedHandle()
    private var tick: Task<Void, Never>?

    /// How many times the overlay has been applied — the measurement D48 asks for,
    /// so the display-cadence knob's value is a number rather than an intuition.
    /// Internal: it exists to be tested, like `ConversationStore.liveGenerations`.
    private(set) var overlayApplications = 0

    /// Attaches to a conversation and reduces it once.
    ///
    /// **`async throws` because attaching is genuinely both.** It reads the log, so
    /// it suspends; the conversation may not exist, so it can fail. Doing this work
    /// in a synchronous initializer would mean publishing a `Conversation` that is
    /// not yet a reduction of anything, and the only honest spelling of that is an
    /// `Optional` whose `nil` conflates "still loading" with "deleted" with "the disk
    /// failed" — three conditions with three different responses.
    ///
    /// - Parameters:
    ///   - conversation: The conversation to display.
    ///   - store: The store to read and observe.
    ///   - mapping: §8's error → affordance table. **This is where an override
    ///     belongs**, not on the store: `Recoverability` is never persisted, so
    ///     fixing a mapping retroactively upgrades the affordances on historical
    ///     failures, and the projection is where an app observes them.
    ///     `ConversationStore.conversation(_:)` deliberately keeps `.default`.
    ///   - displayCadence: How long deltas may be coalesced before the overlay is
    ///     re-applied. **Defaults to `.zero` — apply immediately** (D48): SwiftUI
    ///     already coalesces `@Observable` invalidations per frame, so a timer here
    ///     buys no extra smoothness, only less work. Raise it if a profile shows the
    ///     re-overlay is hot on a large conversation; the trade is latency for CPU
    ///     and nothing else.
    /// - Throws: ``LedgerError/unknownConversation(_:)`` if it does not exist, or a
    ///   persistence failure.
    public init(
        of conversation: ConversationID,
        in store: ConversationStore,
        mapping: RecoverabilityMapping = .default,
        displayCadence: Duration = .zero
    ) async throws {
        self.store = store
        self.id = conversation
        self.mapping = mapping
        self.displayCadence = displayCadence

        // **Subscribe first, read second.** Reading first leaves a window in which a
        // change lands unseen and is never mentioned again; subscribing first merely
        // buffers it, and the redundant re-read that follows is free because
        // re-reading is idempotent. No atomicity argument needed — just an order.
        let notifications = await store.notifications()

        let state = try await store.foldedState(of: conversation)
        let dead = classify(state, mapping: mapping)
        // Attaching **mid-generation** is an ordinary case (list → detail
        // navigation), and without this the first render would show `.interrupted`
        // for something still streaming — right up until the next delta.
        let live = await store.liveSet(of: conversation)

        self.folded = state
        self.classified = dead
        self.messageForGeneration = Self.routing(in: state)
        self.live = live
        self.conversation = overlay(dead, live: live)
        self.overlayApplications = 1

        feed.hold(Task { [weak self] in
            for await notification in notifications {
                guard let self else { return }
                await self.handle(notification)
            }
        })
    }

    deinit {
        // The tick is deliberately not cancelled here: it captures `self` weakly and
        // returns once the projection is gone, so it costs one pending sleep and
        // holds nothing open. The feed holds the notification stream, which is what
        // keeps the store's subscriber entry alive.
        feed.cancel()
    }

    // MARK: - The feed

    private func handle(_ notification: StoreNotification) async {
        guard notification.conversation == id else { return }
        switch notification {
        case .delta(_, let generation, let partial):
            // One assignment, and D47 is what makes it that small: the store computed
            // the whole partial, so there is no accumulator to keep and nothing to
            // reconcile against the base. Applying the same notification twice is a
            // no-op, which is why P2's clause 1 cannot be broken from here.
            live[generation] = partial
            scheduleApply()
        case .changed:
            await repull()
        case .deleted:
            // Terminal: stop consuming, keep the last view, and say so.
            isDeleted = true
            stop()
        }
    }

    /// Re-reduces from the log and re-applies the overlay.
    ///
    /// **A failed read keeps the last good state rather than publishing a worse
    /// one.** An `unknownConversation` means the conversation is gone, which is
    /// deletion by another name and is handled as such. Anything else is a storage
    /// failure this object cannot fix and the next notification will retry — so the
    /// screen goes *stale*, never wrong. Owned limitation: a persistent read failure
    /// is currently invisible to the app, which is a candidate for a status surface
    /// if anything ever needs one.
    private func repull() async {
        let state: FoldedState
        do {
            state = try await store.foldedState(of: id)
        } catch LedgerError.unknownConversation {
            isDeleted = true
            stop()
            return
        } catch {
            return
        }

        folded = state
        classified = classify(state, mapping: mapping)
        messageForGeneration = Self.routing(in: state)
        pruneLiveSet()
        apply()
    }

    /// Drops live entries the log says are finished — which is what keeps P2's
    /// clause 3 (live ⊆ open) true **by construction** rather than by the store and
    /// the projection agreeing.
    ///
    /// Derived from the base on every re-pull, so the live set is *self-correcting*:
    /// it cannot drift, because it is re-checked against the log every time the log
    /// is read. That is why the feed needs no "generation ended" notification — a
    /// terminal is an append, the append sends `.changed`, and this runs.
    ///
    /// The test is `.interrupted`: a generation still open classifies to
    /// `.interrupted` (I5), and any terminal state means the store has finished with
    /// it. A generation with no message at all — a live set outliving its
    /// conversation — is dropped by the same predicate.
    private func pruneLiveSet() {
        live = live.filter { generation, _ in
            guard let message = messageForGeneration[generation],
                  case .interrupted = classified.messages[message]?.state
            else { return false }
            return true
        }
    }

    // MARK: - Display cadence

    /// Applies immediately at `.zero`, or coalesces onto one pending tick (D48).
    private func scheduleApply() {
        guard displayCadence > .zero else { return apply() }
        // One pending tick at a time: a second delta inside the window rides the
        // tick already scheduled, which is what coalescing means.
        guard tick == nil else { return }
        tick = Task { [weak self] in
            try? await Task.sleep(for: self?.displayCadence ?? .zero)
            guard let self, !Task.isCancelled else { return }
            self.tick = nil
            self.apply()
        }
    }

    private func apply() {
        conversation = overlay(classified, live: live)
        overlayApplications += 1
    }

    /// Stops consuming, permanently. Reached only by deletion, which is irreversible
    /// (§9) — so there is deliberately no way to resume.
    private func stop() {
        feed.cancel()
        tick?.cancel()
        tick = nil
    }

    /// Generation → message, from the **folded** layer.
    ///
    /// `static` so the initializer can call it before `self` is fully formed.
    private static func routing(in state: FoldedState) -> [GenerationID: MessageID] {
        var routing: [GenerationID: MessageID] = [:]
        for message in state.messages.values {
            guard let generation = message.generationID else { continue }
            routing[generation] = message.id
        }
        return routing
    }
}

// MARK: -

/// Holds a projection's feed task somewhere `deinit` can reach it.
///
/// **Needed because `deinit` on a `@MainActor` class is nonisolated** and therefore
/// cannot touch isolated stored properties, while the task it must cancel is created
/// and replaced on the main actor. A `Mutex`-protected box is the small, checked way
/// across that line — no `@unchecked Sendable` anywhere, which tenet 6 forbids.
///
/// Only the *feed* task needs this. A display tick captures `self` weakly and simply
/// returns when the projection is gone, so it costs at most one pending sleep. A feed
/// task is different: it holds the notification stream open, and the store's
/// subscriber entry lives exactly as long as that stream — so an uncancelled feed
/// leaks a registration until the next notification happens to arrive, which for a
/// quiet store could be never.
final class FeedHandle: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func hold(_ feed: Task<Void, Never>) {
        task.withLock { $0 = feed }
    }

    func cancel() {
        task.withLock { held in
            held?.cancel()
            held = nil
        }
    }
}

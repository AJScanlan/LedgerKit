import Foundation
import Observation

/// The conversation list, observable and always current (SPEC §9's index, G9).
///
/// ```swift
/// let list = try await ConversationListProjection(in: store)
///
/// ForEach(list.conversations) { summary in
///     NavigationLink(summary.title ?? "New conversation", value: summary.id)
/// }
/// ```
///
/// **A table read, not N reductions.** Each row is a `ConversationSummary` from the
/// `conversations` index — id, created-at, title, last-event-at — so opening a list
/// of five hundred conversations costs one query rather than five hundred folds.
/// Rebuildable by scanning the log, and deletable at any time: same class as
/// snapshots, and truth is still the log.
///
/// ## Why it does not churn while a generation streams
///
/// The index is maintained on **non-delta** appends only (§9), and this projection
/// refreshes on exactly the notifications those appends produce. A streaming
/// generation therefore moves nothing here — no reordering, no reload, no
/// invalidation — which is deliberate twice over: `lastEventAt` means "last
/// *meaningful* event", which is what a list sorts by, and re-sorting five hundred
/// rows at ~4 Hz to report information the list does not show would be the churn
/// §9 declines. Live activity belongs to the per-conversation overlay (§7.4), not
/// here.
///
/// ## Why GRDB's `ValueObservation` is not underneath this
///
/// ADR-003 rule 4 anticipated value observation joining "at M7 as an
/// `AsyncSequence`", and M7 declined it (D41). The store actor is the **only writer
/// in the process**, so database-level observation would watch for changes that can
/// only originate one actor-hop away — a second, heavier mechanism to learn what the
/// store already knew at the moment it did the writing. Declining keeps the
/// persistence seam at six verbs, keeps the in-memory test double trivial, and keeps
/// a GRDB feature out of the dependency surface. If v0.2+ ever admits a second
/// writer — a widget, an extension, sync — that is when observation earns its way in,
/// with the argument it deserves.
@MainActor
@Observable
public final class ConversationListProjection {

    /// Every conversation, **last-event-at descending** — the order the index
    /// returns and the order a list wants, so no client-side sort is needed or
    /// wanted.
    public private(set) var conversations: [ConversationSummary]

    private let store: ConversationStore
    /// Nonisolated so ``deinit`` can cancel it — see ``FeedHandle``.
    private let feed = FeedHandle()

    /// How many times the list has been re-read. Internal, and it exists to make
    /// "a streaming generation does not churn this" an assertion about a number
    /// rather than a claim about ordering that happens to hold.
    private(set) var refreshes = 1

    /// Attaches to the store and reads the index once.
    ///
    /// - Throws: a persistence failure. Unlike ``ConversationProjection``'s
    ///   initializer there is no "does not exist" case — an empty store has an empty
    ///   list, which is a perfectly good answer.
    public init(in store: ConversationStore) async throws {
        self.store = store

        // Subscribe before reading, for ``ConversationProjection``'s reason: a
        // conversation created during the read must not be missed, and a redundant
        // refresh is free.
        let notifications = await store.notifications()
        self.conversations = try await store.conversationSummaries()

        feed.hold(Task { [weak self] in
            for await notification in notifications {
                guard let self else { return }
                await self.handle(notification)
            }
        })
    }

    deinit {
        feed.cancel()
    }

    private func handle(_ notification: StoreNotification) async {
        switch notification {
        case .delta:
            // The whole of §9's no-churn rule, from above: a delta moves nothing in
            // the index, so it moves nothing here. Stated as a case rather than left
            // to a `default` so that a future notification kind has to be decided
            // rather than silently ignored.
            return
        case .changed, .deleted:
            await refresh()
        }
    }

    /// Re-reads the index, keeping the last good list if the read fails.
    ///
    /// A stale list is a worse-than-ideal screen; an empty one is a *wrong* screen
    /// that says the user has no conversations. Given the index is a rebuildable
    /// projection and the next notification retries, keeping what we had is the
    /// conservative choice — the same reasoning that makes a snapshot read failure
    /// something the store shrugs off (§9).
    private func refresh() async {
        guard let summaries = try? await store.conversationSummaries() else { return }
        conversations = summaries
        refreshes += 1
    }
}

import Foundation

/// What the store tells a projection happened (M7-PLAN D38/D39, amended by D47).
///
/// **Infrastructure, not API** — internal, like `liveGenerations`. Consumers see
/// `ConversationProjection` and `ConversationListProjection`; the feed underneath
/// them is ours to reshape. Publishing it would turn a mechanism into a contract,
/// and §7.4 deliberately says only that the projection is "fed by the store".
///
/// ## Two cadences, two shapes
///
/// §7.4's truth hierarchy has display cadence independent of disk cadence, and that
/// is precisely why there are two cases rather than one:
///
/// - ``delta(conversation:generation:partial:)`` crosses **at signal receipt**,
///   before the flush buffer decides anything. That independence *is* the
///   separation of cadences: if this waited for a flush, the screen would advance at
///   ~4 Hz and §7.4's two cadences would collapse into one.
/// - ``changed(_:)`` crosses at **append commit**, for everything that is not a
///   delta — starts, terminals, edits, path changes, metadata. Rare by construction:
///   §9's index argument one layer up, since these are the once-per-turn events.
///
/// ## Why a delta carries the whole partial
///
/// D47, and it is the decision that removes a class of bug rather than guarding
/// against it. A suffix would oblige the projection to accumulate, and an
/// accumulator has to be reconciled against the base conversation on every re-pull:
/// a flush landing between a `.delta` and a `.changed` puts the same text in both
/// places, and a projection created *mid-generation* starts with an empty
/// accumulator and no way to recover what was already flushed. The store holds every
/// delta the driver emitted, so it can just say what the whole partial is, and the
/// projection's rule becomes one idempotent assignment.
///
/// ## Deliberately absent
///
/// **No tool-record shape.** A tool record is a non-delta append, so it already
/// arrives as ``changed(_:)`` and the re-pull carries `Message.toolRecords`. A live
/// "using tool…" signal stays a session concern v0.1 declines to surface (§7.6), and
/// the feed must not become a side channel that quietly re-opens that decision.
///
/// **No "generation ended" shape.** It would be redundant *and* a chance to
/// disagree: a terminal is an append, so it already sends ``changed(_:)``, and the
/// projection drops a live entry whose re-pulled message is no longer
/// `.interrupted`. Deriving it from the base makes the live set **self-correcting**
/// — it cannot drift out of sync with the log, because it is pruned from the log
/// every time the log is read.
enum StoreNotification: Sendable, Equatable {

    /// A live generation's shown partial advanced to `partial` — **the whole
    /// partial**, not the new suffix (D47).
    case delta(conversation: ConversationID, generation: GenerationID, partial: String)

    /// A non-delta event landed. The reader should re-read; this deliberately does
    /// not say *what* changed, because the answer is always "re-reduce", and a
    /// finer-grained signal would be a second description of the log that could
    /// disagree with the first.
    case changed(ConversationID)

    /// The conversation was deleted (§9) — irreversible, and there is nothing left
    /// to read.
    ///
    /// Distinct from ``changed(_:)`` on purpose: a reader that responded to this
    /// with a re-pull would get `unknownConversation` thrown at it and have to infer
    /// deletion from an error. Tenet 1 says say it instead.
    case deleted(ConversationID)

    /// The conversation this notification concerns — every case has one, since a
    /// single stream carries every conversation and subscribers filter.
    var conversation: ConversationID {
        switch self {
        case .delta(let conversation, _, _): conversation
        case .changed(let conversation): conversation
        case .deleted(let conversation): conversation
        }
    }
}

// MARK: - Notification policy

extension LedgerEvent.Payload {

    /// Whether this payload is a delta flush, and therefore **not** a reason to send
    /// `.changed` (D39).
    ///
    /// The same line §9 draws for the `conversations` index, drawn again one layer
    /// up and for the same reason: a delta's content already crossed the feed as
    /// `.delta` at display cadence, so re-announcing it at flush cadence would wake
    /// every subscriber to re-reduce for information it already has.
    ///
    /// Exhaustive rather than `if case .deltaAppended`, matching ``updatesIndex``
    /// and ``isGenesis``: a future payload kind cannot be added without someone
    /// deciding which side of this line it falls on. Note the three predicates are
    /// **not** interchangeable — `deltaAppended` is the only kind that is
    /// simultaneously index-irrelevant and notification-irrelevant, and a fourth
    /// kind might easily split them.
    var isDelta: Bool {
        switch self {
        case .deltaAppended:
            true
        case .conversationCreated, .userMessageAppended, .instructionsChanged,
             .generationStarted, .toolInvocationRecorded, .generationEnded,
             .messageEdited, .activePathChanged, .titleChanged:
            false
        }
    }
}

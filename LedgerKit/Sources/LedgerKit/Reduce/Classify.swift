/// Finalizes and classifies a folded conversation (SPEC §6.3).
///
/// Two conclusions are drawn here and nowhere else, and both are
/// *finalization-time* — they require having stopped reading the log:
///
/// - **`.open ⇒ .interrupted`** (I5). A fold cannot draw it: an open generation
///   in an intermediate fold is genuinely just open. Only a completed reduction
///   with no live overlay says the process died.
/// - **`Recoverability`** (§8), from the supplied mapping. Never persisted, so a
///   mapping fix retroactively upgrades the affordances on historical failures.
///
/// The remaining step, `.interrupted ⇒ .streaming` for in-flight generations, is
/// the projection's (`overlay_live`, §7.4) and deliberately not here — the
/// reducer never learns what "live" means.
///
/// Walks `messages` as a **dictionary**, not as a tree. The transform is per
/// message and disjoint, so iteration order cannot reach the output: every
/// ordered field is copied from an already-ordered source (`children` from the
/// folded node, `rootChildren` and `activePath` from arrays). Two reasons to
/// prefer this over recursing the tree, given the I1 hazard would otherwise
/// argue the other way:
///
/// - A tree walk drops anything unreachable from `rootChildren`. Nothing is
///   unreachable today, but "correct because a different invariant holds" is
///   fragile coupling whose failure mode is *silently losing messages*.
/// - Tree depth tracks message count in a linear conversation, so recursion is a
///   stack-overflow risk on a pathological log.
///
/// The per-message transform is factored into `Message.init(_:mapping:)` so this
/// loop body is a single call — the order-independence argument stays checkable
/// at a glance, rather than needing re-derivation every time the body grows.
func classify(_ folded: FoldedState, mapping: RecoverabilityMapping) -> Conversation {
    var nodes: [MessageID: Message] = Dictionary(minimumCapacity: folded.messages.count)
    for (id, message) in folded.messages {
        nodes[id] = Message(message, mapping: mapping)
    }

    return Conversation(
        id: folded.id,
        title: folded.title,
        instructions: folded.instructions,
        messages: MessageTree(nodes: nodes, rootChildren: folded.rootChildren),
        activePath: folded.activePath,
        diagnostics: folded.diagnostics
    )
}

// MARK: - Folded → public projections

extension Conversation {

    /// Reduces a conversation's log to its state — `classify ∘ fold`, the
    /// composition the public API exposes (§6.3), and the one entry point
    /// consumers need.
    ///
    /// ```swift
    /// let conversation = Conversation(reducing: rows, loadedFrom: id)
    /// ```
    ///
    /// An initializer rather than a top-level `reduce(_:for:)` because that is
    /// what this operation *is*: a `Conversation` is derived state, constructed
    /// from a log the same way `String(decoding:as:)` is constructed from
    /// bytes. Spelling it as a free function put a context-free verb in the
    /// module namespace and read, at a call site, as though it might be
    /// `Sequence.reduce`. The internal pipeline keeps its `fold` / `classify`
    /// vocabulary (§6.3 names the seams, and snapshots depend on them); the
    /// public surface does not have to inherit it.
    ///
    /// - Parameters:
    ///   - rows: The conversation's log in sequence order. §6.6 rows 1–2 arrive
    ///     as `LoadedEvent.undecodable` — a row that would not decode is
    ///     *present and unintelligible*, which is a different fact from absent
    ///     (a gap), and both surface in ``diagnostics``.
    ///   - conversation: The stream the rows were loaded from. Required because
    ///     row 4 compares every envelope against it — an event cannot
    ///     self-certify which stream it belongs to.
    ///   - mapping: Part of classification's identity (I1), which is why it is
    ///     an explicit input rather than a global. Defaults to §8's table;
    ///     overriding it retroactively upgrades the affordances on historical
    ///     failures, because `Recoverability` is never persisted (§8).
    public init(
        reducing rows: some Sequence<LoadedEvent>,
        loadedFrom conversation: ConversationID,
        mapping: RecoverabilityMapping = .default
    ) {
        self = classify(fold(rows, for: conversation), mapping: mapping)
    }
}

extension Message {

    /// Projects a folded node. Everything but `state` passes through unchanged —
    /// including `generationID`, which the folded layer needed for delta routing
    /// and which is worth surfacing for audit.
    init(_ folded: FoldedMessage, mapping: RecoverabilityMapping) {
        self.init(
            id: folded.id,
            role: folded.role,
            generationID: folded.generationID,
            parent: folded.parent,
            children: folded.children,
            state: MessageState(folded.state, mapping: mapping),
            model: folded.model,
            stopInfo: folded.stopInfo,
            toolRecords: folded.toolRecords,
            timestamp: folded.timestamp,
            terminalTimestamp: folded.terminalTimestamp
        )
    }
}

extension MessageState {

    /// Four folded cases become five public ones — the asymmetry is the whole
    /// point of the parallel enum (§6.3).
    init(_ folded: FoldedMessageState, mapping: RecoverabilityMapping) {
        switch folded {
        case .complete(let content):
            self = .complete(content)
        case .open(let partial):
            // I5, and the only place it happens. `.streaming` is unreachable
            // from here by construction: liveness is store state, applied by
            // `overlay_live` on the projection side (§7.4).
            self = .interrupted(partial: partial)
        case .failed(let partial, let error):
            self = .failed(
                partial: partial,
                error: error,
                recoverability: mapping.recoverability(for: error)
            )
        case .cancelled(let partial):
            self = .cancelled(partial: partial)
        }
    }
}

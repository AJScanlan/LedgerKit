import Foundation

/// The fold's accumulator (SPEC §6.3).
///
/// **This is deliberately not `FoldedState`.** `FoldedState` is a read model —
/// shaped for consumers and for snapshot storage. Folding needs bookkeeping no
/// consumer wants: which message a `GenerationID` routes to, delta text in
/// progress, the path endpoint, and where the sequence run is expected to be.
/// Keeping them here rather than in the output is what lets the output stay the
/// clean thing that gets persisted.
///
/// **Every field below must be reconstructible from `FoldedState`**, because a
/// snapshot is a paused fold and ``init(resuming:after:)`` has to rebuild the
/// working set from one. That constraint is why `FoldedMessage` carries
/// `generationID`: without it the routing map would be unrecoverable and the
/// first delta after a mid-generation checkpoint would quarantine under row 9 —
/// replay and resume would diverge, which is precisely what P3 asserts against.
///
/// **I1 hazard:** Swift seeds its hasher per process, so `Dictionary` iteration
/// order varies between runs of the same binary. Nothing here may let that order
/// reach the output. The one place we iterate a dictionary — materializing
/// partials in ``finish()`` — is safe only because the writes are disjoint (I7
/// makes generation↔message 1:1) and therefore commutative. Any new iteration
/// needs the same argument or it breaks determinism in the most infuriating way
/// available: passing locally, flaking in CI.
struct Folder {

    /// The outcome of resolving a `GenerationID` to a message that can still
    /// accept content (I4).
    ///
    /// A small enum rather than `Result`, because `Result`'s failure must be an
    /// `Error` and `QuarantineReason` deliberately is not one — a malformed
    /// event is *data about the log*, not a failure of this computation. It also
    /// lets the caller take the resolved `MessageID` without a force-unwrap,
    /// which the fold cannot afford: I2 promises no path traps.
    private enum Resolution {
        case open(MessageID)
        case rejected(QuarantineReason)
    }

    private var state: FoldedState

    /// Routes `deltaAppended` / `toolInvocationRecorded` / `generationEnded` to
    /// a message. Entries are **never removed** — a `GenerationID` stays used
    /// after termination, so row 8's reuse check outlives the generation.
    private var generationMessages: [GenerationID: MessageID]

    /// Delta text for generations still open. Held aside rather than mutated
    /// into the message's state per delta: appending into an enum payload inside
    /// a dictionary either copies per delta (quadratic) or needs the
    /// move-out-mutate-move-back COW dance. Terminals consume and remove their
    /// entry; whatever remains at ``finish()`` belongs to an open generation.
    private var partials: [GenerationID: String]

    /// The active path's tip. `nil` means the **virtual root**, which is what
    /// makes auto-extend (§6.4) one uniform comparison with no special case for
    /// the conversation's first message. Materialized into `activePath` at
    /// ``finish()`` by walking parents, rather than maintained per event.
    private var endpoint: MessageID?

    /// The next sequence a contiguous run would produce. A row above this is a
    /// gap (§6.1).
    private var expectedSequence: Int64

    /// Rebuilds the working set from a persisted fold.
    ///
    /// - Parameters:
    ///   - state: A snapshot's `FoldedState`, or `.empty(id)` to fold from
    ///     genesis — the genesis fold is deliberately the degenerate resume, so
    ///     there is only one reduction path to get wrong (§9).
    ///   - sequence: The last sequence already folded into `state`; `0` for a
    ///     fold from genesis. Passed rather than stored in `FoldedState` for the
    ///     same reason `sequence` lives only in the events-table key (§6.1):
    ///     duplicating it would create something to disagree with. The store has
    ///     it as `Snapshot.upToSequence`.
    init(resuming state: FoldedState, after sequence: Int64) {
        self.state = state
        self.expectedSequence = sequence + 1
        self.endpoint = state.activePath.last

        (self.generationMessages, self.partials) = Self.reconstructRouting(from: state)
    }

    /// Rebuilds the routing map and partial buffers by walking the tree in
    /// sibling order — over `children` arrays, **not** over `state.messages`, so
    /// reconstruction never depends on dictionary order (see the I1 hazard).
    ///
    /// Iterative with an explicit stack rather than recursive. In a linear
    /// conversation — the ordinary shape — tree depth *is* message count, so
    /// recursion here would consume stack proportional to conversation length and
    /// could overflow on a pathological log. I2 promises the reducer never traps,
    /// and overflowing the stack is trapping.
    ///
    /// `visited` bounds the walk. A cycle is unreachable through the fold, which
    /// validates that a parent exists before inserting a child — but this
    /// consumes a *snapshot*, which is bytes on disk, and a decodable-but-corrupt
    /// one must terminate rather than spin forever.
    private static func reconstructRouting(
        from state: FoldedState
    ) -> ([GenerationID: MessageID], [GenerationID: String]) {
        var generationMessages: [GenerationID: MessageID] = [:]
        var partials: [GenerationID: String] = [:]
        var visited: Set<MessageID> = []
        // Reversed so `popLast` yields siblings in order: depth-first, sibling
        // order preserved, identical to the recursive traversal it replaces.
        var stack = Array(state.rootChildren.reversed())

        while let id = stack.popLast() {
            guard visited.insert(id).inserted, let message = state.messages[id] else { continue }
            if let generation = message.generationID {
                generationMessages[generation] = id
                if case .open(let partial) = message.state { partials[generation] = partial }
            }
            stack.append(contentsOf: message.children.reversed())
        }

        return (generationMessages, partials)
    }

    // MARK: - Applying

    /// Folds one row in, quarantining it if it is unintelligible (I2).
    ///
    /// Total by construction: no path here throws, traps, or returns a failure
    /// to the caller. A malformed event is not an error — it is a *fact about
    /// the log*, and the output records it. Events have already happened; the
    /// fold cannot reject one, only decide what it means.
    mutating func apply(_ row: LoadedEvent) {
        detectGap(before: row)
        expectedSequence = max(expectedSequence, row.sequence + 1)

        switch row {
        case .undecodable(let sequence, let eventID, let failure):
            // Rows 1–2 arrive pre-diagnosed: only the loader is positioned to
            // observe them (§6.6 input corollary).
            quarantine(sequence: sequence, eventID: eventID, failure.quarantineReason)

        case .decoded(let event):
            // Split rather than `precheck(event) ?? applyPayload(event)`: the
            // first borrows `self`, the second mutates it, and keeping them in
            // separate statements avoids relying on `??`'s evaluation order for
            // exclusivity.
            let reason: QuarantineReason?
            if let rejection = precheck(event) {
                reason = rejection
            } else {
                reason = applyPayload(event)
            }
            if let reason {
                quarantine(sequence: event.sequence, eventID: event.id, reason)
            }
        }
    }

    /// One diagnostic per *contiguous* gap, so a 10k-row hole costs one
    /// diagnostic rather than 10k (§6.1). The diagnostic's own `sequence` is the
    /// first missing row; the range rides in the reason.
    private mutating func detectGap(before row: LoadedEvent) {
        guard row.sequence > expectedSequence else { return }
        quarantine(
            sequence: expectedSequence,
            eventID: nil,
            .sequenceGap(missing: expectedSequence...(row.sequence - 1))
        )
    }

    /// Stream-level checks that precede any payload interpretation.
    ///
    /// Precedence is deliberate: row 4 outranks row 5, because an event that
    /// isn't ours has no business being judged against *our* genesis.
    private func precheck(_ event: LedgerEvent) -> QuarantineReason? {
        if event.conversationID != state.id {
            return .foreignConversation(found: event.conversationID)
        }
        if case .conversationCreated = event.payload {
            return state.hasGenesis ? .duplicateGenesis : nil
        }
        return state.hasGenesis ? nil : .beforeGenesis
    }

    private mutating func applyPayload(_ event: LedgerEvent) -> QuarantineReason? {
        switch event.payload {
        case .conversationCreated(let title):
            // Accepted wherever it first appears. Anything that preceded it
            // already quarantined individually under row 5, and "sequence 1" is
            // a store guarantee (§6.1) rather than something the tolerant
            // reader re-litigates.
            state.hasGenesis = true
            state.title = title
            return nil

        case .userMessageAppended(let message, let content, let parent):
            return applyUserMessage(message, content: content, parent: parent, timestamp: event.timestamp)

        case .instructionsChanged(let instructions):
            state.instructions = instructions
            return nil

        case .titleChanged(let title):
            state.title = title
            return nil

        case .generationStarted(let generation, let message, let parent, let model):
            return applyGenerationStarted(
                generation, message, parent: parent, model: model, timestamp: event.timestamp
            )

        case .deltaAppended(let generation, let text):
            switch resolveOpen(generation) {
            case .rejected(let reason): return reason
            case .open:
                partials[generation, default: ""] += text
                return nil
            }

        case .toolInvocationRecorded(let generation, let record):
            switch resolveOpen(generation) {
            case .rejected(let reason): return reason
            case .open(let messageID):
                state.messages[messageID]?.toolRecords.append(record)
                return nil
            }

        case .generationEnded(let generation, let outcome):
            return applyTerminal(generation, outcome, timestamp: event.timestamp)

        case .messageEdited(let original, let replacement, let content):
            return applyEdit(original, replacement, content: content, timestamp: event.timestamp)

        case .activePathChanged(let target):
            guard state.messages[target] != nil else { return .unknownPathEndpoint(target) }
            endpoint = target
            return nil
        }
    }

    private mutating func applyUserMessage(
        _ id: MessageID,
        content: String,
        parent: MessageID?,
        timestamp: Date
    ) -> QuarantineReason? {
        if state.messages[id] != nil { return .messageIDAlreadyUsed(id) }
        if let parent {
            guard state.messages[parent] != nil else { return .unknownParent(parent) }
        } else if !state.rootChildren.isEmpty {
            // Row 7 — "new topic ≠ new branch." An accidental nil parent must
            // not silently become a hidden root-level branch (I6).
            return .additionalRootMessage(id)
        }

        insert(
            FoldedMessage(
                id: id,
                role: .user,
                parent: parent,
                state: .complete(MessageContent(text: content)),
                timestamp: timestamp
            )
        )
        return nil
    }

    private mutating func applyEdit(
        _ original: MessageID,
        _ replacement: MessageID,
        content: String,
        timestamp: Date
    ) -> QuarantineReason? {
        guard let target = state.messages[original] else { return .unknownEditTarget(original) }
        // Editing an assistant message would manufacture user-authored
        // assistant content and corrupt the audit trail (§6.1).
        guard target.role == .user else { return .editTargetNotUser(original) }
        if state.messages[replacement] != nil { return .messageIDAlreadyUsed(replacement) }

        // A sibling under the same parent — which is what makes editing the
        // first message legal: its parent is the virtual root, so the
        // replacement lands in `rootChildren` with no special case (I6).
        insert(
            FoldedMessage(
                id: replacement,
                role: .user,
                parent: target.parent,
                state: .complete(MessageContent(text: content)),
                timestamp: timestamp
            )
        )
        return nil
    }

    private mutating func applyTerminal(
        _ generation: GenerationID,
        _ outcome: Outcome,
        timestamp: Date
    ) -> QuarantineReason? {
        guard let messageID = generationMessages[generation] else {
            return .unknownGeneration(generation)
        }
        // A terminal against an already-terminated generation is row 10, not
        // row 9: I3 allows at most one. A cancel racing a natural completion
        // lands here benignly — first append wins.
        guard state.messages[messageID]?.state.isOpen == true else {
            return .duplicateTerminal(generation)
        }

        let partial = partials.removeValue(forKey: generation) ?? ""
        switch outcome {
        case .completed(let stopInfo):
            state.messages[messageID]?.state = .complete(MessageContent(text: partial))
            state.messages[messageID]?.stopInfo = stopInfo
        case .failed(let error):
            state.messages[messageID]?.state = .failed(partial: partial, error)
        case .cancelled:
            state.messages[messageID]?.state = .cancelled(partial: partial)
        }
        state.messages[messageID]?.terminalTimestamp = timestamp
        return nil
    }

    // MARK: - Generation start

    /// Binds a generation to a new assistant message (SPEC §6.1, §6.4, I6, I7).
    ///
    /// The densest node in the reducer: three separate row-8 conditions, I7's
    /// once-only rule, node insertion, and the auto-extend interaction all meet
    /// here.
    ///
    /// **Guards, none of which mutate** — I2 containment means a quarantined
    /// start leaves the tree exactly as it was:
    ///
    /// 1. A `GenerationID` already in ``generationMessages`` ⇒
    ///    ``QuarantineReason/generationIDAlreadyUsed(_:)`` (row 8). The map keeps
    ///    terminated generations, so reuse stays invalid *after* the generation
    ///    ended — the binding is permanent, not merely current.
    /// 2. A `MessageID` already in `state.messages` ⇒
    ///    ``QuarantineReason/messageIDAlreadyUsed(_:)`` (row 8 / I7 once-only).
    /// 3. A non-`nil` parent the tree does not hold ⇒
    ///    ``QuarantineReason/unknownParent(_:)`` (row 8). Self-parenting lands
    ///    here too: guard 2 has already established the ID is unused, so a
    ///    message naming itself as parent names something absent.
    ///
    /// **Two conditions are deliberately *not* guarded**, and the fixtures in
    /// `FolderGenerationStartedTests` exist to keep them that way:
    ///
    /// - A `nil` parent is **legal here**, unlike for `userMessageAppended`
    ///   (row 7). It means a child of the virtual root — wire headroom for N10's
    ///   assistant-initiated conversations. The v0.1 store never emits one; the
    ///   reducer accepts it.
    /// - An **assistant** parent is legal too. That is the continuation shape
    ///   (I7/§12), and §6.6 records role adjacency as an explicit *non-rule*:
    ///   enforcement is store policy, tolerance is wire.
    ///
    /// ``partials`` is deliberately untouched — an absent buffer reads as empty,
    /// and ``finish()`` materializes `.open(partial:)` from whatever accumulated.
    private mutating func applyGenerationStarted(
        _ generation: GenerationID,
        _ message: MessageID,
        parent: MessageID?,
        model: ModelDescriptor,
        timestamp: Date
    ) -> QuarantineReason? {
        guard generationMessages[generation] == nil else {
            return .generationIDAlreadyUsed(generation)
        }

        guard state.messages[message] == nil else {
            return .messageIDAlreadyUsed(message)
        }

        if let parent, state.messages[parent] == nil {
            return .unknownParent(parent)
        }

        insert(
            FoldedMessage(
                id: message,
                role: .assistant,
                generationID: generation,
                parent: parent,
                state: .open(partial: ""),
                model: model,
                timestamp: timestamp
            )
        )

        generationMessages[generation] = message

        return nil
    }

    // MARK: - Shared mutations

    /// Adds a node to the tree, in sibling order, and applies §6.4's
    /// auto-extend rule.
    ///
    /// Auto-extend is one comparison — `parent == endpoint` — and it covers the
    /// conversation's first message for free, because `nil` endpoint *is* the
    /// virtual root. That is the whole reason I6 models the root as a virtual
    /// node instead of a special case.
    ///
    /// - Precondition: the caller has already validated that `message.id` is
    ///   unused and that any non-`nil` parent exists.
    private mutating func insert(_ message: FoldedMessage) {
        state.messages[message.id] = message
        if let parent = message.parent {
            state.messages[parent]?.children.append(message.id)
        } else {
            state.rootChildren.append(message.id)
        }
        if message.parent == endpoint { endpoint = message.id }
    }

    /// The shared row-9 gate for deltas and tool records: the generation must
    /// exist *and* still be open. A terminal message's content and audit trail
    /// are both immutable (I4).
    private func resolveOpen(_ generation: GenerationID) -> Resolution {
        guard let messageID = generationMessages[generation] else {
            return .rejected(.unknownGeneration(generation))
        }
        guard state.messages[messageID]?.state.isOpen == true else {
            return .rejected(.generationAlreadyTerminated(generation))
        }
        return .open(messageID)
    }

    private mutating func quarantine(sequence: Int64, eventID: EventID?, _ reason: QuarantineReason) {
        state.diagnostics.append(
            QuarantinedEvent(sequence: sequence, eventID: eventID, reason: reason)
        )
    }

    // MARK: - Finishing

    /// Projects the working set into the persistable read model.
    ///
    /// Note what this does *not* do: synthesize `.interrupted`. An open
    /// generation stays `.open` — a fold that has stopped reading has not
    /// thereby learned that the process died, and a snapshot storing
    /// `.interrupted` could forge a crash. That conclusion belongs to `classify`
    /// (I5, §6.3).
    func finish() -> FoldedState {
        var result = state
        for (generation, partial) in partials {
            guard let messageID = generationMessages[generation],
                  result.messages[messageID]?.state.isOpen == true
            else { continue }
            result.messages[messageID]?.state = .open(partial: partial)
        }
        result.activePath = materializedPath(in: result)
        return result
    }

    /// Walks parents from the endpoint to a root-level node and reverses (§6.4).
    ///
    /// The `count` bound is defensive rather than necessary: a cycle would need
    /// a node whose parent was inserted after it, which insertion-time parent
    /// validation already forbids. But I2 promises the fold never traps *or
    /// hangs*, and a bound is cheaper than the argument.
    ///
    /// If the walk ever meets a missing parent — which I believe unreachable in
    /// v0.1, since nothing removes messages — it returns the intact suffix,
    /// which is the closest reading of I6's "clamp to the nearest valid
    /// ancestor" that preserves where the user was looking. A test asserts this
    /// branch is dead across every fixture.
    private func materializedPath(in state: FoldedState) -> [MessageID] {
        guard let endpoint, state.messages[endpoint] != nil else { return [] }
        var path: [MessageID] = []
        var cursor: MessageID? = endpoint
        while let id = cursor, let message = state.messages[id], path.count <= state.messages.count {
            path.append(id)
            cursor = message.parent
        }
        return path.reversed()
    }
}

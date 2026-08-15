import Foundation

/// The durable conversation state engine — every write goes through here
/// (SPEC §6.5, §11).
///
/// ```swift
/// let store = try ConversationStore(persistence: .sqlite(at: dbURL))
/// let convo = try await store.createConversation()
/// let outcome = try await store.send("Explain valley folds", in: convo.id, using: driver)
/// ```
///
/// ## The two-channel contract
///
/// Stated once here and restated on every verb that has one, because it is the
/// single rule a consumer must internalize: **`try` guards *did it start*; the
/// return value and the observed state answer *how did it end*.** A throw is a
/// failure to **record** (``LedgerError``): usually the verb never started and
/// the log is untouched, and in the one post-start case — a backend failure while
/// flushing or recording a terminal — the start persists with no terminal and
/// reduces to `.interrupted` (rev 8's "couldn't record" clause). Once
/// `generationStarted` is in the log, *generation* failures are `Outcome`s, and a
/// cancelled generation *returns* `.cancelled` rather than throwing (§7.2,
/// §11's documented deviation).
///
/// ## Single-flight, and how it survives reentrancy
///
/// One generation per conversation (§6.5); cross-conversation concurrency is
/// unrestricted. §6.5 asks for the single-flight check, the verb's appends, and
/// in-flight registration in "one actor-isolated critical section" — but the
/// append awaits the database, and **a Swift actor is reentrant at every
/// `await`**, so a second `send` can interleave exactly there. A lock held
/// across the await is not something the language offers.
///
/// The resolution (M5-PLAN D24) is that the *reservation* is the critical
/// section, and it is fully synchronous: **reserve → append → confirm or roll
/// back.** Reserve with no await in it, so a second starter arriving mid-append
/// sees the reservation and throws `generationInFlight`; on append success the
/// reservation becomes the live generation; on *any* throw it is removed, and
/// since the seam's batch is all-or-nothing the log was never touched. A losing
/// racer records **nothing** — no orphaned user message, no yanked path — and
/// a failed starter leaves no trace. §6.5's behaviour, achieved by ordering.
///
/// ## What is derived, and therefore not here
///
/// The actor **folds forward**: `append` returns the assembled tail, so its own
/// writes are reduced into an in-memory `FoldedState` rather than re-read (P1 is
/// the property that licenses it). Cold load goes through the snapshot
/// fast-path. Deliberately absent (D28): no synchronous reads, no conversation
/// list, no `AsyncSequence` of changes — the `@MainActor @Observable` projection
/// is M7's, and it is where the liveness overlay and display cadence live
/// (§7.4). The store exposes exactly one read verb, ``conversation(_:)``.
public actor ConversationStore {

    /// One conversation's folded state and the sequence it is folded to (D23).
    ///
    /// The actor **folds forward**: `append` returns the assembled tail, so its
    /// own writes are reduced into this pair rather than re-read. P1 is the
    /// property that licenses it — it asserts the values `append` returned are
    /// interchangeable with the bytes a re-read decodes, which is precisely the
    /// claim this cache makes on every write.
    ///
    /// **No eviction policy in v0.1** beyond delete and the divergence drop
    /// below: the cache is bounded by conversations actually touched in a
    /// session, a `FoldedState` is small, and an LRU nobody measured is
    /// complexity nobody asked for.
    private struct CachedFold {
        var state: FoldedState
        var lastSequence: Int64
        /// The sequence the newest checkpoint covers — 0 when none was used.
        /// Only the §9 event floor reads it, and only to answer "how far has
        /// this conversation drifted from its last checkpoint".
        var snapshotAt: Int64 = 0
    }

    /// A conversation's generation slot (§6.5, D24).
    ///
    /// Two states because D24 has two moments: the slot is claimed *before* the
    /// start append (so a racer arriving mid-append is turned away), and only
    /// becomes a running generation once that append succeeded. A single
    /// "is generating" flag could not express the window in between, which is
    /// precisely the window the race lives in.
    private enum Reservation {
        /// Claimed, nothing appended yet — D24 step 1.
        ///
        /// `cancelled` closes the one gap a stop button would otherwise have:
        /// a cancel arriving *during* the start append has no task to cancel
        /// yet, and silently ignoring it would mean the visible generation runs
        /// to completion after the user pressed stop. Recording the intent lets
        /// the loop honour it the instant there is something to honour it with.
        case reserved(cancelled: Bool)
        /// Confirmed and running — D24 step 3. The handle is what
        /// ``cancelGeneration(in:)`` cancels and what ``deleteConversation(_:)``
        /// waits on; a generation the store cannot reach is one the stop button
        /// cannot stop and the delete cannot sequence behind.
        case running(generation: GenerationID, task: Task<Outcome, Error>)
    }

    /// Accumulates stream text until the flush policy says it is worth a
    /// transaction (§7.4, D25).
    ///
    /// Timed on a **`ContinuousClock`**, not on the store's injected `now` —
    /// deliberately, and for two reasons. An interval measured against a wall
    /// clock is wrong whenever that clock is adjusted, which is a real thing
    /// during a long generation; and `now` is *the stamping site*, so spending
    /// its reads on flush bookkeeping would make an event's timestamp depend on
    /// how often the buffer was consulted. Determinism in tests comes from the
    /// character bound and from `.zero` / very large intervals, which need no
    /// clock control at all.
    private struct DeltaBuffer {
        private let policy: DeltaFlushPolicy
        /// Readable but not clearable from outside — see ``reset(at:)``.
        private(set) var text = ""
        /// Tracked incrementally: `String.count` is O(n), and calling it per
        /// delta would make buffering quadratic in a long generation.
        private var characters = 0
        private var openedAt: ContinuousClock.Instant

        init(policy: DeltaFlushPolicy, openedAt: ContinuousClock.Instant = .now) {
            self.policy = policy
            self.openedAt = openedAt
        }

        var isEmpty: Bool { text.isEmpty }

        /// Whether the policy says the buffer is worth a transaction.
        var isDue: Bool {
            !text.isEmpty
                && (characters >= policy.characterCount || ContinuousClock.now - openedAt >= policy.interval)
        }

        mutating func append(_ delta: String) {
            text += delta
            characters += delta.count
        }

        /// Clears the buffer. **Called only after a successful append**, which
        /// is why it is separate from reading ``text``: a flush that failed
        /// leaves its text pending, so the wind-down writes it rather than the
        /// stream losing it (§7.5's partial retention).
        mutating func reset(at instant: ContinuousClock.Instant = .now) {
            text = ""
            characters = 0
            openedAt = instant
        }
    }

    private let persistence: any PersistenceStore
    private let deltaFlush: DeltaFlushPolicy
    private let snapshots: SnapshotPolicy
    /// Mutating on every mint — each call advances the v7 generator's
    /// monotonicity state (``IDGenerator``).
    private var identifiers: any IdentifierSource
    private let now: @Sendable () -> Date
    private var folds: [ConversationID: CachedFold] = [:]
    /// Conversations whose one generation slot is taken — reserved, or reserved
    /// and running (§6.5, D24).
    ///
    /// **Single-flight gates generation *starts*, not ledger writes.** Nothing
    /// in ``edit(_:content:in:)`` or ``switchBranch(to:in:)`` consults this, and
    /// that omission is normative rather than incidental: §6.5 makes mid-stream
    /// edits and switches legal, so a user may move the visible path while a
    /// generation streams off it. The stream continues and terminates normally —
    /// completion changes state in place and emits no path event, so the bubble
    /// stays wherever the user left it.
    private var live: [ConversationID: Reservation] = [:]
    /// Verbs suspended until a `.reserved` slot resolves (M6-PLAN A1).
    ///
    /// Only ``deleteConversation(_:)`` waits today, and only because it is the
    /// one verb that *overrides* a generation rather than respecting it. A
    /// continuation rather than a yield-loop for two reasons: a spin would burn
    /// the actor for the whole duration of an append it is waiting on, and it
    /// would leave the wait unobservable, so a test could only *hope* it had
    /// reached the window rather than know it.
    private var startWaiters: [ConversationID: [CheckedContinuation<Void, Never>]] = [:]

    /// Opens (or creates) a store.
    ///
    /// - Throws: ``LedgerError/persistenceFailure(description:)`` if the backend
    ///   cannot be opened or migrated. The underlying error's type stops at this
    ///   boundary (ADR-003 rule 1) — GRDB never appears in a LedgerKit
    ///   signature, thrown type, or re-export, which is what keeps raw sqlite3 a
    ///   §12 cut line priced in days.
    public init(
        persistence: PersistenceConfiguration,
        deltaFlush: DeltaFlushPolicy = .default,
        snapshots: SnapshotPolicy = .default
    ) throws {
        do {
            self.persistence = try SQLitePersistenceStore(persistence)
        } catch {
            throw LedgerError.wrapping(error)
        }
        self.deltaFlush = deltaFlush
        self.snapshots = snapshots
        self.identifiers = IDGenerator.live()
        self.now = { Date() }
    }

    /// The injectable initializer (M5-PLAN D27) — a seeded generator and a fake
    /// clock make a verb sequence produce **byte-stable logs**, which is what
    /// lets verb tests assert against hand-written `Log` fixtures instead of
    /// against "roughly this shape". Same design as ``IDGenerator`` itself; the
    /// store only plumbs it. Taking `any PersistenceStore` additionally lets a
    /// failing double drive the two-channel tests, where the interesting
    /// assertion is that the log is untouched afterward.
    ///
    /// Internal rather than public because the two clocks want to agree and
    /// nothing enforces that: `IDGenerator` carries its own millisecond clock
    /// for the v7 timestamp, and `now` stamps envelopes. A test passes a
    /// coherent pair; a consumer has no reason to pass either.
    init(
        persistence: any PersistenceStore,
        deltaFlush: DeltaFlushPolicy = .default,
        snapshots: SnapshotPolicy = .default,
        identifiers: some IdentifierSource,
        now: @escaping @Sendable () -> Date
    ) {
        self.persistence = persistence
        self.deltaFlush = deltaFlush
        self.snapshots = snapshots
        self.identifiers = identifiers
        self.now = now
    }

    // MARK: - Lifecycle & metadata

    /// Creates a conversation — a `conversationCreated` genesis event — and
    /// returns its (empty) reduced state.
    public func createConversation(title: String? = nil) async throws -> Conversation {
        let id = identifiers.makeConversationID()
        let tail = try await commit([mint(.conversationCreated(title: title), in: id)], to: id)

        // Seeded from `.empty` rather than cold-loaded: the identifier was
        // minted a line ago, so no log can exist under it, and a read would be
        // a round trip to confirm nothing. The genesis still arrives through
        // `foldForward`, so there is one advance path rather than a special
        // case that could drift from it.
        folds[id] = CachedFold(state: .empty(id), lastSequence: 0)
        foldForward(tail, in: id)

        // Read back through the ordinary accessor rather than returning the
        // state built above. In the happy path it is a dictionary lookup, and in
        // any path where the genesis failed to reach the cache it falls back to
        // the log — so this has no unreachable branch to get wrong.
        return classify(try await existingFold(of: id).state, mapping: .default)
    }

    /// Sets the conversation's instructions; `nil` clears (§6.1).
    ///
    /// Instructions live in the ledger rather than on a driver because a ledger
    /// that cannot rebuild the session is not the truth (§7.1). Last write wins,
    /// so this is idempotent under replay.
    ///
    /// - Throws: ``LedgerError/unknownConversation(_:)``, or a persistence
    ///   failure. Legal mid-generation.
    public func setInstructions(_ instructions: String?, in conversation: ConversationID) async throws {
        try await record(.instructionsChanged(instructions), in: conversation)
    }

    /// Sets the conversation's title; `nil` clears — symmetric with
    /// instructions. Updates the index projection in the same transaction (§9).
    ///
    /// - Throws: ``LedgerError/unknownConversation(_:)``, or a persistence
    ///   failure. Legal mid-generation.
    public func setTitle(_ title: String?, in conversation: ConversationID) async throws {
        try await record(.titleChanged(title), in: conversation)
    }

    /// Deletes a conversation's events, snapshots, and index row. **Irreversible.**
    ///
    /// Out-of-band — not an event — because there is no log left to append to
    /// (§9). The one verb that *overrides* an in-flight generation rather than
    /// respecting it: it **cancels first**, letting the cancel run to its
    /// terminal through the normal path (the suspended verb returns `.cancelled`,
    /// never a persistence error), and only then commits the `DELETE`. Both steps
    /// sequence through this actor, so the terminal-append-versus-`DELETE` race
    /// cannot occur.
    ///
    /// - Throws: ``LedgerError/unknownConversation(_:)``, or a persistence
    ///   failure.
    public func deleteConversation(_ conversation: ConversationID) async throws {
        _ = try await existingFold(of: conversation)

        // §9's cancel-first sequencing, and the two awaits are the whole of it.
        // The cancel runs to its terminal through the normal path — the
        // suspended verb returns `.cancelled`, not a persistence error — and
        // only then does the DELETE commit. Actor isolation alone would *not* be
        // enough: the actor yields at every await, so a generation still winding
        // down would happily append `generationEnded` into a conversation this
        // verb had already erased, leaving a genesis-less row and a stale index
        // entry.
        //
        // **Waiting only on `.running` was not enough either** (M6-PLAN A1, from
        // the M5 boundary audit). D24's reservation window is precisely an
        // interval in which a generation is claimed and its start append is
        // *in flight* — invisible to a `.running` check, and holding a
        // transaction this verb cannot see. Racing it produces one of the two
        // artifacts this doc says cannot occur, depending on which commit lands
        // first: rows written into an erased conversation, or a terminal
        // appended after the DELETE. So the reserved case is waited out first,
        // which converges it onto the running case — the starter confirms, the
        // recorded early cancel fires, the terminal lands, and only then is
        // there anything for the DELETE to erase.
        cancelGeneration(in: conversation)
        await waitForStartToResolve(in: conversation)
        if case .running(_, let task) = live[conversation] {
            // Swallowed: whatever that generation's own verb reports is its
            // caller's business, not this one's.
            _ = try? await task.value
        }

        do {
            try await persistence.deleteConversation(conversation)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw LedgerError.wrapping(error)
        }
        evict(conversation)
    }

    // MARK: - Reading

    /// The conversation's current reduced state (§6.2).
    ///
    /// The **only** read verb, deliberately (D28). §11 says the store exposes no
    /// synchronous reads, and `createConversation` already returns a
    /// `Conversation`, so an async read existed in all but name; this makes it
    /// honest without opening a second read surface. The conversation *list*
    /// (the index projection) and any observation of changes belong to M7's
    /// projection, where the liveness overlay lives — `.streaming` is not
    /// something this verb can ever return, because no fold of any log yields it
    /// (§7.4).
    ///
    /// Uses §8's default `RecoverabilityMapping`. An app overriding the mapping
    /// does so on the projection, since `Recoverability` is never persisted and
    /// a mapping fix retroactively upgrades historical failures.
    ///
    /// - Throws: ``LedgerError/unknownConversation(_:)``, or a persistence
    ///   failure. An `events` read that fails **propagates** — that is the truth
    ///   failing to load, and returning an empty conversation would be
    ///   indistinguishable from one that is genuinely empty.
    public func conversation(_ id: ConversationID) async throws -> Conversation {
        classify(try await existingFold(of: id).state, mapping: .default)
    }

    // MARK: - Branching

    /// Replaces a user message with an edited sibling and moves the active path
    /// onto it, returning the replacement's identifier.
    ///
    /// `messageEdited` + `activePathChanged`, **one transaction** (§6.4, §9), so
    /// no crash strands half an edit. Editing a root-level message creates a
    /// root-level sibling under the virtual root — same rule, no special case
    /// (I6). The original branch is retained and unreachable-by-default,
    /// surfaced by a branch switcher.
    ///
    /// **Does not generate.** Composition is the app's business; `respond(to:)`
    /// on the returned identifier is the other half of the post-edit flow.
    ///
    /// Legal mid-generation (§6.5): single-flight gates generation *starts*, not
    /// ledger writes. The stream continues off-path and terminates normally.
    ///
    /// - Throws: ``LedgerError/unknownMessage(_:)`` if the tree lacks it,
    ///   ``LedgerError/ineligibleTarget(message:expected:found:)`` if it is
    ///   assistant-authored (§6.1: assistant text is the product of a
    ///   generation, so editing it would forge one), or a persistence failure.
    public func edit(
        _ message: MessageID,
        content: String,
        in conversation: ConversationID
    ) async throws -> MessageID {
        _ = try await target(message, expecting: .user, in: conversation)

        // The path event is not optional here and never conditional, unlike
        // `respond`'s: an edit's replacement is a *sibling* of the original, so
        // its parent is never the current endpoint and auto-extend can never
        // fire (§6.4). Without it the edit would land off-path and invisible.
        let replacement = identifiers.makeMessageID()
        let tail = try await commit(
            [
                mint(.messageEdited(original: message, replacement: replacement, content: content), in: conversation),
                mint(.activePathChanged(endpoint: replacement), in: conversation),
            ],
            to: conversation
        )
        foldForward(tail, in: conversation)
        return replacement
    }

    /// Moves the visible thread to the branch ending at `endpoint` — a bare
    /// `activePathChanged` (§6.4).
    ///
    /// Legal mid-generation (§6.5). Whether switching away should *cancel* is a
    /// product decision; the store takes no position and offers
    /// ``cancelGeneration(in:)``.
    ///
    /// - Throws: ``LedgerError/unknownMessage(_:)`` for an endpoint that never
    ///   existed, or a persistence failure. Note the layer difference: the
    ///   reducer *quarantines* the same fact (§6.6 row 12) because an event in a
    ///   log has no caller to tell.
    public func switchBranch(to endpoint: MessageID, in conversation: ConversationID) async throws {
        // No role expectation: switching *to* an assistant message is the
        // ordinary case — it is how a branch switcher moves between sibling
        // responses — and the only requirement §6.4 states is that the endpoint
        // exists.
        _ = try await target(endpoint, expecting: nil, in: conversation)

        let tail = try await commit([mint(.activePathChanged(endpoint: endpoint), in: conversation)], to: conversation)
        foldForward(tail, in: conversation)
    }

    // MARK: - Generation

    /// Appends a user message and generates a response — the 95% path, one call.
    ///
    /// `userMessageAppended` + `generationStarted`, one transaction and nothing
    /// more: auto-extend is a fold rule, not an event (§6.4). Suspends until the
    /// generation reaches a terminal and the terminal is **durable**.
    ///
    /// Two channels (§7.2): this `throws` when the generation could not be
    /// **recorded** — almost always because it never started, and then the log is
    /// untouched, so a losing single-flight racer records nothing at all. Every
    /// *generation* failure after the start append is the returned `Outcome`
    /// instead, including zero-token request-time failures (auth, instant
    /// guardrail), which land as `.failed(partial: "", …)`; an empty failed
    /// bubble showing *how to recover* is the feature.
    ///
    /// - Throws: ``LedgerError/unknownConversation(_:)``,
    ///   ``LedgerError/generationInFlight(_:)``,
    ///   ``LedgerError/persistenceFailure(description:)`` — which alone may land
    ///   *after* the start, leaving an open generation that reduces to
    ///   `.interrupted` (rev 8) — or `CancellationError` if the task is cancelled
    ///   before the append lands (§7.2 — after it, cancellation *returns*
    ///   `.cancelled`).
    public func send(
        _ text: String,
        in conversation: ConversationID,
        using driver: some GenerationDriving
    ) async throws -> Outcome {
        let state = try await existingFold(of: conversation).state
        try reserve(conversation)

        let message = identifiers.makeMessageID()
        // `endpoint == nil` is the virtual root, which opens the tree — and it
        // can only be nil when the tree is empty, since the first inserted node
        // auto-extends onto it and nothing ever sets it back. So this cannot
        // produce §6.6 row 7's "second bare nil-parent append".
        let user = mint(.userMessageAppended(message: message, content: text, parent: state.endpoint), in: conversation)

        // The user message's parent *is* the endpoint, so auto-extend moves the
        // path onto it, and the generation then hangs off the new endpoint —
        // which is why `send` is two events and never three (§6.4, §6.5).
        return try await generate(
            from: message,
            in: conversation,
            precededBy: [user],
            movingPath: false,
            using: driver
        )
    }

    /// Generates a response to an existing **user** message.
    ///
    /// `generationStarted`, plus `activePathChanged` in the same transaction
    /// when the target is not the current endpoint (§6.4) — a generation the
    /// user asked for must never stream invisibly. Where the target already has
    /// a response, the new one falls out as a sibling and the old one survives
    /// on its own branch, including an `.interrupted` partial. That is how
    /// "partial retained as its own branch" falls out of the model rather than
    /// being a feature.
    ///
    /// Two channels (§7.2): `throws` when the generation could not be recorded —
    /// before the append in every case but a persistence failure; every
    /// *generation* failure after it is the returned `Outcome`.
    ///
    /// - Throws: ``LedgerError/unknownConversation(_:)``,
    ///   ``LedgerError/unknownMessage(_:)``,
    ///   ``LedgerError/ineligibleTarget(message:expected:found:)`` for an
    ///   assistant target (that is the *continuation* shape — v0.2 research,
    ///   I7 — not something v0.1 backs into),
    ///   ``LedgerError/generationInFlight(_:)``, a persistence failure, or
    ///   `CancellationError` before the append.
    public func respond(
        to message: MessageID,
        in conversation: ConversationID,
        using driver: some GenerationDriving
    ) async throws -> Outcome {
        let (state, _) = try await target(message, expecting: .user, in: conversation)
        try reserve(conversation)

        return try await generate(
            from: message,
            in: conversation,
            // Off the endpoint, auto-extend cannot fire, and a generation the
            // user asked for must never stream invisibly (§6.4).
            movingPath: state.endpoint != message,
            using: driver
        )
    }

    /// Regenerates an **assistant** message: exactly ``respond(to:in:using:)`` on
    /// its parent.
    ///
    /// Pure sugar since rev 4 (§6.4) — the off-endpoint path event is `respond`'s
    /// job now, so this adds nothing but the assistant-to-parent lookup, and it
    /// is implemented as one code path with two entry points rather than two
    /// implementations that must be kept agreeing.
    ///
    /// - Throws: as ``respond(to:in:using:)``, except that
    ///   ``LedgerError/ineligibleTarget(message:expected:found:)`` names the
    ///   opposite expectation — a user target has no generation to redo.
    public func regenerate(
        _ message: MessageID,
        in conversation: ConversationID,
        using driver: some GenerationDriving
    ) async throws -> Outcome {
        let (state, assistant) = try await target(message, expecting: .assistant, in: conversation)

        // The assistant-to-parent lookup is the *whole* of what regenerate adds
        // over respond (§6.4, rev 4). A root-level assistant has no parent
        // message to respond to — see `unsupportedTarget`.
        guard let parent = assistant.parent else {
            throw LedgerError.unsupportedTarget(message: message)
        }
        try reserve(conversation)

        return try await generate(
            from: parent,
            in: conversation,
            movingPath: state.endpoint != parent,
            using: driver
        )
    }

    // MARK: - Cancellation

    /// Cancels the conversation's in-flight generation, if any. **No-op if none**
    /// — not a throw: "stop" on nothing already stopped is not an error worth a
    /// caller's attention.
    ///
    /// The canonical stop path (§7.5): the store is the authority on in-flight
    /// state and outlives any `Task` handle a view was holding. Cancelling the
    /// awaiting task is the sugar version, and both reach the same place — the
    /// driver winds down, the loop flushes, `generationEnded(.cancelled)` lands,
    /// and the suspended verb returns `.cancelled`.
    ///
    /// **Returns as soon as the cancel is signalled, not when the terminal is
    /// durable**, which is why it does not need to be `async` internally even
    /// though callers still `await` the actor hop. A stop button that blocked
    /// until disk agreed would be a stop button that hangs. Racing a natural
    /// terminal is benign: first append wins and I3 quarantines the loser, so
    /// exactly one terminal exists either way.
    public func cancelGeneration(in conversation: ConversationID) {
        switch live[conversation] {
        case .running(_, let task):
            task.cancel()
        case .reserved:
            // The start append is still in flight, so there is nothing to
            // cancel *yet*. Recording the intent is what stops a stop from
            // being silently dropped in that window.
            live[conversation] = .reserved(cancelled: true)
        case nil:
            break
        }
    }

    // MARK: - The cache

    /// Drops a conversation's cached fold.
    ///
    /// Correctness never depends on this — the log is the truth, so the worst an
    /// eviction costs is the replay it was avoiding. Phase 4's
    /// ``deleteConversation(_:)`` calls it because the conversation is gone;
    /// ``foldForward(_:in:)`` calls it because the cache can no longer be
    /// trusted.
    func evict(_ conversation: ConversationID) {
        folds[conversation] = nil
    }

    /// A conversation's cached fold, cold-loading it if this is the first touch.
    ///
    /// **``FoldedState/hasGenesis`` is the existence predicate**, which is a
    /// happy consequence rather than a design: the flag exists so a snapshot
    /// resumed from a genesis-less log agrees with a replay of it (P3), and
    /// "this conversation has a valid `conversationCreated`" is exactly what a
    /// caller means by asking whether it exists. A log whose genesis quarantined
    /// reads as unknown for the same reason it should — every subsequent append
    /// to it would quarantine under §6.6 row 5.
    ///
    /// A missing conversation is deliberately **not** cached. A negative entry
    /// would need invalidation, and unknown identifiers are not a hot path.
    private func existingFold(of conversation: ConversationID) async throws -> CachedFold {
        if let cached = folds[conversation] {
            guard cached.state.hasGenesis else { throw LedgerError.unknownConversation(conversation) }
            return cached
        }

        let loaded: LoadedFold
        do {
            loaded = try await persistence.loadedFold(of: conversation)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw LedgerError.wrapping(error)
        }
        guard loaded.state.hasGenesis else { throw LedgerError.unknownConversation(conversation) }

        // **Publish only if newer.** The load above awaited, and an actor is
        // reentrant at every await, so another verb may have populated *and*
        // advanced this entry while the read was in flight. Overwriting it would
        // silently rewind the cache behind that verb's back, and the next append
        // would then fold its tail onto a state missing an event — a false gap
        // in memory that disk never had. The log only grows and this actor is
        // its only writer, so "at least as far along" is the whole test.
        if let current = folds[conversation], current.lastSequence >= loaded.lastSequence {
            return current
        }

        let entry = CachedFold(
            state: loaded.state,
            lastSequence: loaded.lastSequence,
            snapshotAt: loaded.snapshotSequence
        )
        folds[conversation] = entry
        return entry
    }

    /// Folds an appended tail into the conversation's cached state (D23).
    ///
    /// **Drops the entry rather than folding a hole into it** when the tail does
    /// not continue exactly where the cache left off. Two verbs writing to one
    /// conversation both await the database, and nothing orders their
    /// resumptions: the later-sequenced tail can arrive first, and folding it
    /// would raise a `sequenceGap` diagnostic *in memory* against a log that has
    /// no gap — state diverging from disk while both halves look plausible
    /// alone, which is the worst available shape and precisely what P1 exists to
    /// catch. Dropping costs one replay and cannot be wrong.
    private func foldForward(_ tail: [LedgerEvent], in conversation: ConversationID) {
        guard let first = tail.first, let last = tail.last else { return }
        guard var entry = folds[conversation], entry.lastSequence + 1 == first.sequence else {
            evict(conversation)
            return
        }
        entry.state = fold(
            resuming: entry.state,
            after: entry.lastSequence,
            with: tail.lazy.map(LoadedEvent.decoded)
        )
        entry.lastSequence = last.sequence
        folds[conversation] = entry
    }

    // MARK: - Eligibility

    /// Resolves a verb's target message — the one place `edit`, `switchBranch`,
    /// `respond` and `regenerate` agree about what a valid target is (§6.5).
    ///
    /// Shared rather than repeated because the four verbs differ only in the
    /// role they expect, and four copies of "look it up, check the role" is four
    /// chances for one of them to disagree with §6.5 about which error a
    /// wrong-role target deserves.
    ///
    /// **The layer difference is the point.** The reducer *quarantines* these
    /// same facts — an unknown edit target is §6.6 row 11, a never-existent path
    /// endpoint is row 12 — because an event sitting in a log has no caller to
    /// tell. A verb does, so it throws. Same fact, correct channel per layer.
    ///
    /// The decision cannot go stale across the `await` that follows it: roles
    /// never change and messages are never removed, so a target valid now is
    /// valid when the append lands.
    ///
    /// - Parameter role: `nil` accepts any role — `switchBranch`'s case, where
    ///   existence is the only requirement.
    private func target(
        _ message: MessageID,
        expecting role: Role?,
        in conversation: ConversationID
    ) async throws -> (state: FoldedState, message: FoldedMessage) {
        let state = try await existingFold(of: conversation).state
        guard let found = state.messages[message] else {
            throw LedgerError.unknownMessage(message)
        }
        if let role, found.role != role {
            throw LedgerError.ineligibleTarget(message: message, expected: role, found: found.role)
        }
        return (state, found)
    }

    // MARK: - Single-flight

    /// Reserves the conversation's one generation slot (§6.5, D24 step 1).
    ///
    /// **Synchronous by construction, and that is the whole design.** §6.5 asks
    /// for the single-flight check, the appends and the registration in "one
    /// actor-isolated critical section", which no lock can provide across an
    /// `await`. Ordering provides it instead: this contains no suspension point,
    /// so a second starter arriving while the first is mid-append sees the
    /// reservation and throws.
    ///
    /// Phase 3 widens the stored value to carry the running task (cancellation
    /// needs a handle); the two entry points here are already the shape D24's
    /// step 1 and rollback want.
    func reserve(_ conversation: ConversationID) throws {
        guard live[conversation] == nil else {
            throw LedgerError.generationInFlight(conversation)
        }
        live[conversation] = .reserved(cancelled: false)
    }

    /// Upgrades a reservation to a running generation — D24 step 3, reached only
    /// after the start append committed.
    ///
    /// Reports whether a cancel arrived while the slot was merely reserved, so
    /// the caller can honour it immediately rather than dropping it.
    private func confirm(
        _ conversation: ConversationID,
        running task: Task<Outcome, Error>,
        as generation: GenerationID
    ) -> Bool {
        let cancelledEarly = if case .reserved(true) = live[conversation] { true } else { false }
        live[conversation] = .running(generation: generation, task: task)
        resumeStartWaiters(in: conversation)
        return cancelledEarly
    }

    /// Suspends until this conversation's slot is no longer merely *reserved*
    /// (M6-PLAN A1). Returns immediately when nothing is claimed, or when the
    /// generation is already running.
    ///
    /// **Bounded by the start append, which is why no timeout is needed:** a
    /// reservation resolves when that append commits (``confirm(_:running:as:)``)
    /// or fails (``release(_:)``), and both are the same one transaction the
    /// caller would otherwise be racing. There is deliberately no cancellation
    /// path — a caller cancelled here waits out the same bounded window, exactly
    /// as it already does on the `.running` handle, and abandoning the wait would
    /// re-open the race the wait exists to close.
    private func waitForStartToResolve(in conversation: ConversationID) async {
        guard case .reserved = live[conversation] else { return }
        // No lost wakeup: the body runs synchronously on the actor before
        // suspending, and only actor-isolated code resolves a reservation — so
        // nothing can resolve it between the check above and the append below.
        await withCheckedContinuation { continuation in
            startWaiters[conversation, default: []].append(continuation)
        }
    }

    private func resumeStartWaiters(in conversation: ConversationID) {
        guard let waiting = startWaiters.removeValue(forKey: conversation) else { return }
        for continuation in waiting { continuation.resume() }
    }

    /// Conversations where a verb is waiting out a claimed-but-unconfirmed start.
    ///
    /// Internal for the same reason ``liveGenerations`` is: it exists to be
    /// *observed*. A test driving the reservation window needs to know the waiter
    /// has arrived rather than hope it has — which is the parked-point discipline
    /// (§10.4) applied to a wait instead of to a stream.
    var conversationsAwaitingStart: Set<ConversationID> { Set(startWaiters.keys) }

    /// The generations currently in flight — **M7's `overlay_live` input**, and
    /// P2's third clause: the live set is always a subset of *open* (started,
    /// un-terminated) generations.
    ///
    /// Keyed by `GenerationID` rather than by conversation because that is what
    /// the overlay maps over: `.interrupted → .streaming` for exactly these. A
    /// reservation that has not started yet contributes nothing — there is no
    /// generation in the log to overlay.
    var liveGenerations: Set<GenerationID> {
        Set(live.values.compactMap { reservation in
            if case .running(let generation, _) = reservation { generation } else { nil }
        })
    }

    /// Releases the slot — D24's rollback *and* its normal completion path, so
    /// a generation that failed to start leaves no more trace than one that
    /// finished.
    func release(_ conversation: ConversationID) {
        live[conversation] = nil
        // The rollback half of A1's wait: a start that failed resolves its
        // reservation too, and a waiter that only woke on *success* would hang
        // on precisely the case where nothing was recorded.
        resumeStartWaiters(in: conversation)
    }

    // MARK: - Generating

    /// The one implementation behind `send`, `respond` and `regenerate`.
    ///
    /// **Callers reserve, this rolls back.** The slot is claimed by the verb —
    /// synchronously, with no `await` between its check and its registration
    /// (D24 step 1) — and released here on any failure to start. Splitting it
    /// that way keeps the critical section inside a single verb body, where it
    /// is checkable by reading, rather than spread across a call boundary.
    ///
    /// Everything the three verbs disagree about is a parameter: `send` brings
    /// its user message, `respond` and `regenerate` bring a path event when the
    /// parent is off the endpoint. `regenerate` is *exact* sugar for `respond`
    /// on the target's parent (§6.4, rev 4), so there is one implementation and
    /// two entry points rather than two implementations to keep agreeing.
    ///
    /// - Parameters:
    ///   - parent: The message the new assistant node hangs from.
    ///   - precededBy: Events committing in the **same transaction** ahead of
    ///     `generationStarted` — `send`'s user message. §6.5's start atomicity
    ///     is exactly this: a losing racer records nothing, so there is no
    ///     orphaned user message with the path already yanked onto it.
    ///   - movingPath: Whether to emit `activePathChanged` onto the new node.
    private func generate(
        from parent: MessageID,
        in conversation: ConversationID,
        precededBy leading: [LedgerEvent.Record] = [],
        movingPath: Bool,
        using driver: some GenerationDriving
    ) async throws -> Outcome {
        let generation = identifiers.makeGenerationID()
        let assistant = identifiers.makeMessageID()

        var records = leading
        records.append(mint(
            // The *requested* descriptor comes from the driver and is never
            // invented here (§7.8, D21 constraint 3): nothing in the framework
            // exposes model identity, so the app supplies it at driver init and
            // the store copies it.
            .generationStarted(generation: generation, message: assistant, parent: parent, model: driver.model),
            in: conversation
        ))
        if movingPath {
            records.append(mint(.activePathChanged(endpoint: assistant), in: conversation))
        }

        do {
            // §7.2's straddle, the near side: cancelled *before* the append and
            // Swift's convention holds — nothing started, so nothing to record
            // and `CancellationError` is the honest answer. Past the append the
            // rule inverts and cancellation becomes a returned `.cancelled`.
            try Task.checkCancellation()
            let tail = try await commit(records, to: conversation)
            foldForward(tail, in: conversation)
        } catch {
            // D24's rollback. The seam's batch is all-or-nothing, so the log was
            // never touched — a failed starter leaves no more trace than a
            // losing racer, and the slot must not stay wedged either way.
            release(conversation)
            throw error
        }

        // Past this line the generation exists in the log, so §7.2 applies:
        // every *generation* failure from here is an `Outcome`, not a throw.
        return try await run(generation, from: parent, in: conversation, using: driver)
    }

    /// Hands the generation to a task the store can reach, confirms the
    /// reservation, and bridges cancellation into it (D24 step 3, §7.5).
    ///
    /// Deliberately thin: everything about *running* a generation is
    /// ``drive(_:from:in:using:)``'s, including the rehydration read as of
    /// M6-PLAN A2. What can only happen here is the pairing of a task handle with
    /// the slot that owns it — the reservation cannot be confirmed before the
    /// handle exists, and the handle must not outlive the confirmation.
    private func run(
        _ generation: GenerationID,
        from parent: MessageID,
        in conversation: ConversationID,
        using driver: some GenerationDriving
    ) async throws -> Outcome {
        // **One task per generation, and it is unstructured on purpose.**
        // `cancelGeneration(in:)` is a *different* entry into this actor and
        // cannot cancel work it holds no handle to; `deleteConversation(_:)`
        // must wait on that same handle so the terminal lands before the
        // DELETE (§9). Structured concurrency gives neither. What it does give
        // — cancellation reaching the verb's own caller — is restored below.
        let task = Task { [self] in
            try await drive(generation, from: parent, in: conversation, using: driver)
        }
        // **Nothing suspends between that line and this one, and that is
        // load-bearing.** The task body is actor-isolated, so it cannot begin
        // until this method yields — which means `drive` never observes an
        // unconfirmed slot, and the reservation window closes here rather than
        // spanning a read (M6-PLAN A2).
        if confirm(conversation, running: task, as: generation) {
            // A stop arrived while the slot was merely reserved (§7.2's window).
            task.cancel()
        }

        // §7.2's far side, and D21 constraint 5's behaviour restored: cancelling
        // the Task awaiting `send` must reach the generation, exactly as
        // `cancelGeneration` does. Same semantics, two entry points (§7.5).
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The generation itself: rehydrate, consume, persist on cadence, record one
    /// terminal (D25, §7.4).
    ///
    /// **The loop is the store's, not the driver's.** §7.4 attributed delta
    /// coalescing to "the driver", written before the seam existed; the store
    /// owns every append, so the *cadence of appends* is necessarily its
    /// business too. What the driver still owns is the thing §7.4 cared about —
    /// producing deltas rather than snapshots, which is the diffing on the far
    /// side of the seam.
    ///
    /// **Only deltas coalesce** (§7.4). A tool record forces the buffer out
    /// first, or the log would claim the tool ran before text that preceded it;
    /// and the terminal is always preceded by a flush, which is not a policy
    /// choice — the unflushed tail is exactly what a crash costs, and losing it
    /// at the very end would lose a *completed* generation's last words.
    private func drive(
        _ generation: GenerationID,
        from parent: MessageID,
        in conversation: ConversationID,
        using driver: some GenerationDriving
    ) async throws -> Outcome {
        defer { release(conversation) }

        // **The rehydration read belongs inside this guard** (M6-PLAN A2, from
        // the M5 boundary audit). It used to sit in `run`, between `generate`'s
        // rollback and the `defer` above — covered by neither. It reads from the
        // cache in the warm case and from disk in the cold one (a mid-flight
        // `edit` racing this start lands D29's eviction), so it is a real
        // suspension point with two real failures, and both were mishandled: a
        // throw wedged single-flight forever, and a task-cancel escaped as a
        // **post-append `CancellationError`**, which §7.2 says is impossible.
        let request: GenerationRequest
        do {
            request = try await rehydrationMaterial(upTo: parent, in: conversation)
        } catch is CancellationError {
            // Past the start append, "how it ended" has exactly one channel
            // (§7.2): a recorded terminal. Nothing streamed, so there is no
            // partial to flush — and the wind-down runs outside this cancelled
            // scope for the reason §7.5 spells out.
            return try await windDown(generation, in: conversation, flushing: nil, as: .cancelled)
        }
        // A persistence failure falls through as `persistenceFailure` with the
        // generation left **open** — rev 8's "couldn't record" clause, which is
        // already the contract: `.interrupted` on reload says something went
        // wrong, where a terminal claiming success would lie.

        let (signals, channel) = GenerationChannel.makeStream()
        let driving = Task { await Self.produce(request, from: driver, into: channel) }

        // **Cancellation stops the driver, never the recording — and the whole
        // shape of this method follows from that.**
        //
        // GRDB honours task cancellation, so any append performed inside a
        // cancelled task *throws instead of writing*. Left that way, cancelling
        // a generation would prevent the one append that makes the cancellation
        // visible: the generation would stay open and reduce to `.interrupted`,
        // a different state for a different thing (§7.5 — cancelled ≠ failed ≠
        // interrupted). Measured, not assumed — inline, every cancellation test
        // failed with `CancellationError` escaping the verb.
        //
        // It also fixes a quieter loss. If cancellation ended the *consume*
        // loop, signals the driver had already emitted but the store had not yet
        // read would vanish with it. Here the loop's only exit is the stream
        // ending, and the stream ends because the driver was cancelled — so
        // everything the driver actually produced is drained and recorded first.
        // That is what §7.5's "partial content retained" has to mean.
        //
        // Unstructured tasks do not inherit cancellation, which makes this the
        // smallest scope that survives it.
        let recording = Task { [self] in
            let consumed = await consume(signals, of: generation, in: conversation)
            if consumed.failure != nil {
                // Stop the driver producing into a stream nobody is reading.
                driving.cancel()
            }
            let outcome = await driving.value

            if let failure = consumed.failure {
                // §11's principle is "one channel for *couldn't record*", and a
                // persistence failure is emphatically that. Deliberately **no**
                // terminal is written: the generation stays open, reduces to
                // `.interrupted`, and says "something went wrong" — where a
                // `.completed` terminal missing a flush would claim success.
                throw failure
            }

            return try await windDown(generation, in: conversation, flushing: consumed.pending, as: outcome)
        }

        return try await withTaskCancellationHandler {
            try await recording.value
        } onCancel: {
            // Without this a parked driver would never notice: no signals
            // arrive, so the loop never runs, so nothing observes the stop.
            driving.cancel()
        }
    }

    /// The wind-down: §7.4's pre-terminal flush, then the one terminal.
    ///
    /// **Always outside the cancelled scope, whoever calls it** (§7.5, rev 8). A
    /// cancellation-aware backend makes writes inside a cancelled task throw
    /// instead of writing, so a stop performed here would erase its own
    /// evidence — no terminal, generation left open, and the conversation reads
    /// `.interrupted` for something the user explicitly did. The inner task is
    /// redundant when the caller is already outside that scope and free when it
    /// is not, which is the price of having **one** wind-down rather than two
    /// that could drift: the flush-before-terminal rule (§7.4) is not a policy
    /// choice, so it must not be a thing a second caller can forget.
    private func windDown(
        _ generation: GenerationID,
        in conversation: ConversationID,
        flushing pending: String?,
        as outcome: Outcome
    ) async throws -> Outcome {
        try await Task { [self] in
            if let pending {
                try await append(.deltaAppended(generation: generation, text: pending), in: conversation)
            }
            try await append(.generationEnded(generation: generation, outcome: outcome), in: conversation)
        }.value
        return outcome
    }

    /// Runs the driver and closes the stream behind it.
    ///
    /// `nonisolated static` so it executes off the actor: a generation holding
    /// the store's isolation would serialize every other conversation's verbs
    /// behind it, which is the opposite of §6.5's cross-conversation freedom.
    private nonisolated static func produce(
        _ request: GenerationRequest,
        from driver: some GenerationDriving,
        into channel: GenerationChannel
    ) async -> Outcome {
        // The store finishes the stream, always — so the consume loop
        // terminates whether or not the driver was well behaved.
        defer { channel.finish() }
        return await driver.generate(request, streamingInto: channel)
    }

    /// Consumes signals, persisting them on the flush policy (§7.4, D25).
    ///
    /// **Only `deltaAppended` coalesces.** A tool record forces the buffer out
    /// first, or the log would claim the tool ran before text that preceded it.
    ///
    /// Returns the first persistence failure rather than throwing it, because
    /// the caller has a decision to make that an unwound stack would take away:
    /// a generation that started must still be accounted for, and *how* depends
    /// on what failed. The buffer is only reset **after** a successful append,
    /// so a failed flush leaves its text pending rather than dropping it.
    private func consume(
        _ signals: AsyncStream<GenerationSignal>,
        of generation: GenerationID,
        in conversation: ConversationID
    ) async -> (pending: String?, failure: (any Error)?) {
        var buffer = DeltaBuffer(policy: deltaFlush)
        for await signal in signals {
            do {
                switch signal {
                case .delta(let text):
                    buffer.append(text)
                    if buffer.isDue {
                        try await append(.deltaAppended(generation: generation, text: buffer.text), in: conversation)
                        buffer.reset()
                    }
                case .toolRecord(let record):
                    if !buffer.isEmpty {
                        try await append(.deltaAppended(generation: generation, text: buffer.text), in: conversation)
                        buffer.reset()
                    }
                    try await append(.toolInvocationRecorded(generation: generation, record: record), in: conversation)
                }
            } catch {
                return (buffer.isEmpty ? nil : buffer.text, error)
            }
        }
        return (buffer.isEmpty ? nil : buffer.text, nil)
    }

    /// What the driver needs to rebuild a session (§7.1), from reduction output
    /// rather than from the log (D21 constraint 4).
    private func rehydrationMaterial(
        upTo parent: MessageID,
        in conversation: ConversationID
    ) async throws -> GenerationRequest {
        let state = try await existingFold(of: conversation).state
        return GenerationRequest(
            conversation: conversation,
            instructions: state.instructions,
            context: ancestry(of: parent, in: state).map { Message($0, mapping: .default) }
        )
    }

    /// The chain from a root-level node down to `message`, in order.
    ///
    /// Iterative, with a visited set: I2's posture is that nothing may trap *or
    /// hang*, and tree depth tracks message count in a linear conversation, so
    /// recursing here is a stack-overflow risk on a long thread.
    private func ancestry(of message: MessageID, in state: FoldedState) -> [FoldedMessage] {
        var chain: [FoldedMessage] = []
        var seen: Set<MessageID> = []
        var cursor: MessageID? = message
        while let id = cursor, seen.insert(id).inserted, let node = state.messages[id] {
            chain.append(node)
            cursor = node.parent
        }
        return chain.reversed()
    }

    // MARK: - Writing

    /// Appends one event to an existing conversation and folds it forward.
    ///
    /// The eligibility check runs first and the mint runs after it, so a verb
    /// that throws consumes no identifier — identifiers are cheap, but a gap in
    /// the v7 run is a false signal to anyone reading a log by eye.
    private func record(_ payload: LedgerEvent.Payload, in conversation: ConversationID) async throws {
        _ = try await existingFold(of: conversation)
        try await append(payload, in: conversation)
    }

    /// Appends one already-validated event and folds it forward. The generation
    /// loop's unit of work, where re-checking existence per delta would be a
    /// round trip to confirm something that cannot have changed.
    private func append(_ payload: LedgerEvent.Payload, in conversation: ConversationID) async throws {
        let tail = try await commit([mint(payload, in: conversation)], to: conversation)
        foldForward(tail, in: conversation)

        let isTerminal = if case .generationEnded = payload { true } else { false }
        await refreshSnapshotIfDue(in: conversation, afterTerminal: isTerminal)
    }

    // MARK: - Snapshots

    /// §9's refresh policy, and M4 handoff 2 — the trigger nothing owned until
    /// now.
    ///
    /// After each `generationEnded`, because that is the natural quiescent point
    /// and generations dominate event volume, so a cold open replays at most one
    /// generation's suffix. Plus a floor, for logs that reach no terminal at all
    /// — a conversation of nothing but edits and branch switches would otherwise
    /// never checkpoint.
    ///
    /// **Awaited rather than detached**, which is a deliberate reading of §9's
    /// "best-effort async". Detaching would let a save land *after* a
    /// `deleteConversation` had erased the conversation, resurrecting a snapshot
    /// row for a log that no longer exists — the same race §9 takes care to
    /// close for terminals. The write is one small blob at a point the verb is
    /// already finishing, so sequencing it costs nothing worth a race.
    private func refreshSnapshotIfDue(in conversation: ConversationID, afterTerminal: Bool) async {
        guard let entry = folds[conversation] else { return }
        let due = (afterTerminal && snapshots.refreshesAfterEachGeneration)
            || entry.lastSequence - entry.snapshotAt >= Int64(snapshots.maximumEventsBetweenRefreshes)
        guard due else { return }

        // **`try?` belongs *here*, and nowhere below.** `saveSnapshot` throws so
        // that this layer can tell a checkpoint it chose to skip from one that
        // failed; §9's "best-effort" is a statement about *this* caller's
        // policy. A missed refresh costs replay time, never correctness — truth
        // is the log — so a failure is shrugged off and retried at the next
        // quiescent point.
        guard (try? await persistence.saveSnapshot(of: entry.state, upTo: entry.lastSequence)) != nil else { return }

        // Re-read rather than reusing `entry`: the save awaited, so the cache
        // may have advanced or been dropped underneath it (D29).
        if folds[conversation]?.lastSequence == entry.lastSequence {
            folds[conversation]?.snapshotAt = entry.lastSequence
        }
    }

    /// Mints one wire record — **the stamping site** (M4 handoff 1).
    ///
    /// Timestamps are canonicalized *here*, at birth, and nowhere else.
    /// `append` debug-asserts they arrive canonical and must never repair them:
    /// repairing at write time would give every event two identities depending
    /// on whether it had been to disk, which is the bug class ADR-001 R-5 and
    /// P1/P3 exist to catch. The wire form carries milliseconds while `Date` is
    /// a `Double` of seconds, so an unrounded stamp does not survive its own
    /// encoding.
    private func mint(_ payload: LedgerEvent.Payload, in conversation: ConversationID) -> LedgerEvent.Record {
        LedgerEvent.Record(
            id: identifiers.makeEventID(),
            conversationID: conversation,
            timestamp: WireDate.canonical(now()),
            payload: payload
        )
    }

    /// The seam boundary for writes: one transaction in, an assembled tail out,
    /// and no backend error type escaping (ADR-003 rule 1).
    ///
    /// `CancellationError` passes through as itself. It is not a persistence
    /// failure and must not be reported as one — §7.2 gives it its own meaning
    /// on this channel, and a caller distinguishing "the disk failed" from "I
    /// cancelled this" is the whole point of a typed error.
    private func commit(
        _ records: [LedgerEvent.Record],
        to conversation: ConversationID
    ) async throws -> [LedgerEvent] {
        do {
            return try await persistence.append(records, to: conversation)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw LedgerError.wrapping(error)
        }
    }
}

// MARK: - Identifier injection

/// The four mints the store needs, erased from ``IDGenerator``'s random-source
/// type parameter (M5-PLAN D27).
///
/// Erasure rather than generics because the alternative is a public
/// `ConversationStore<SystemRandomNumberGenerator>` — a type parameter every
/// consumer would have to write, or work around, to buy a capability only tests
/// use. `IDGenerator` already vends exactly these four, so the conformance is
/// empty; `mutating` is inherited from it and is load-bearing, since each mint
/// advances the v7 generator's monotonicity state.
protocol IdentifierSource: Sendable {
    mutating func makeEventID() -> EventID
    mutating func makeConversationID() -> ConversationID
    mutating func makeMessageID() -> MessageID
    mutating func makeGenerationID() -> GenerationID
}

extension IDGenerator: IdentifierSource {}

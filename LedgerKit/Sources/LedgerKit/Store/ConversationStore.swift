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
/// return value and the observed state answer *how did it end*.** A throw means
/// the log is untouched — nothing started, nothing recorded (``LedgerError``).
/// Once `generationStarted` is in the log, failures are `Outcome`s, and a
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
    }

    private let persistence: any PersistenceStore
    private let deltaFlush: DeltaFlushPolicy
    private let snapshots: SnapshotPolicy
    /// Mutating on every mint — each call advances the v7 generator's
    /// monotonicity state (``IDGenerator``).
    private var identifiers: any IdentifierSource
    private let now: @Sendable () -> Date
    private var folds: [ConversationID: CachedFold] = [:]

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
    //
    // Bodies still spelled `fatalError` belong to a later phase. This is the one
    // place in the package where that is permitted (M5-PLAN Phase 0): they are
    // compile scaffolding for a surface under review, and no test may reach one
    // — a test that does has found a missing implementation, which is exactly
    // what it should report.

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
        fatalError("ConversationStore.deleteConversation is M5 Phase 4")
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
        fatalError("ConversationStore.edit is M5 Phase 2")
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
        fatalError("ConversationStore.switchBranch is M5 Phase 2")
    }

    // MARK: - Generation

    /// Appends a user message and generates a response — the 95% path, one call.
    ///
    /// `userMessageAppended` + `generationStarted`, one transaction and nothing
    /// more: auto-extend is a fold rule, not an event (§6.4). Suspends until the
    /// generation reaches a terminal and the terminal is **durable**.
    ///
    /// Two channels (§7.2): this `throws` only when the generation never
    /// started, and then the log is untouched — a losing single-flight racer
    /// records nothing at all. Everything after the append is the returned
    /// `Outcome`, including zero-token request-time failures (auth, instant
    /// guardrail), which land as `.failed(partial: "", …)`; an empty failed
    /// bubble showing *how to recover* is the feature.
    ///
    /// - Throws: ``LedgerError/unknownConversation(_:)``,
    ///   ``LedgerError/generationInFlight(_:)``, a persistence failure, or
    ///   `CancellationError` if the task is cancelled before the append lands
    ///   (§7.2 — after it, cancellation *returns* `.cancelled`).
    public func send(
        _ text: String,
        in conversation: ConversationID,
        using driver: some GenerationDriving
    ) async throws -> Outcome {
        fatalError("ConversationStore.send is M5 Phase 3")
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
    /// Two channels (§7.2): `throws` only before the append; everything after is
    /// the returned `Outcome`.
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
        fatalError("ConversationStore.respond is M5 Phase 3")
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
        fatalError("ConversationStore.regenerate is M5 Phase 3")
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
        fatalError("ConversationStore.cancelGeneration is M5 Phase 4")
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

        let loaded: (state: FoldedState, lastSequence: Int64)
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

        let entry = CachedFold(state: loaded.state, lastSequence: loaded.lastSequence)
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

    // MARK: - Writing

    /// Appends one event to an existing conversation and folds it forward.
    ///
    /// The eligibility check runs first and the mint runs after it, so a verb
    /// that throws consumes no identifier — identifiers are cheap, but a gap in
    /// the v7 run is a false signal to anyone reading a log by eye.
    private func record(_ payload: LedgerEvent.Payload, in conversation: ConversationID) async throws {
        _ = try await existingFold(of: conversation)
        let tail = try await commit([mint(payload, in: conversation)], to: conversation)
        foldForward(tail, in: conversation)
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

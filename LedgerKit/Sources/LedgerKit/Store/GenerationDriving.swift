import Foundation

// The driver seam (SPEC §7; M5-PLAN D21) — what the `ConversationStore` asks of
// whatever actually runs inference.
//
// The seam exists because the store can take neither of the two obvious things.
// A concrete `GenerationDriver` does not exist until M6 and would drag the one
// OS-coupled module into every M5 test — including onto a dev machine that
// cannot execute a 27-only API. And `any LanguageModel` is forbidden outright:
// tenet 3 says the inference boundary is Apple's, and a durable-state engine has
// no business seeing a model. So M5 declares the contract, M6 supplies the one
// production conformance, and the test double conforms today.
//
// Five constraints shape everything below (D21). They are stated once here and
// enforced by the individual declarations:
//
// 1. **The store owns every append.** A driver produces *signals*; it never
//    touches persistence. §11's isolation sketch is unambiguous — the actor owns
//    all writes — and a driver that could write would make the healthy-log
//    property (M5-PLAN §1) unprovable, since the store could no longer account
//    for every event in the log it hands to the reducer.
// 2. **Signals cannot be skipped, structurally** (tenet 4). Exactly one terminal
//    per generation is the *grammar* of ``GenerationDriving/generate(_:streamingInto:)``,
//    not a runtime promise: the stream carries only non-terminal signals and the
//    terminal is the return value, so two terminals are unrepresentable and zero
//    terminals is a function that never returns.
// 3. **The driver exposes its requested `ModelDescriptor`** (§7.8), which the
//    store copies into `generationStarted`. The store never invents one.
// 4. **The store hands over reduction output, not the log** — rehydration
//    material (§7.1), already folded and classified. What a driver does with it
//    (build a `Transcript`, hit a per-conversation session cache, §7.8) is M6's
//    business and invisible here.
// 5. **Cancellation is bridged to the driver, never inherited by the
//    recording.** The store runs the driver in an *unstructured* task and
//    explicitly cancels it from both stop paths (§7.5) — deliberately outside
//    structured inheritance, because the wind-down that records the
//    cancellation must not run inside a cancelled scope (rev 8's finding: a
//    cancellation-aware backend would make the terminal append throw instead
//    of write). The driver's obligation is unchanged: wind down and return
//    `.cancelled`.

/// Runs one generation and reports how it ended.
///
/// Conformances: `Session/GenerationDriver` at M6, over `LanguageModelSession`;
/// a scripted double in LedgerKit's own tests from M5 Phase 3.
///
/// `Sendable` because the store actor calls across its isolation boundary — the
/// same reasoning as ``PersistenceStore``, and tenet 6 forbids buying it with
/// `@unchecked`.
public protocol GenerationDriving: Sendable {

    /// The **requested** provider/model/version this driver was configured with
    /// (SPEC §7.8), which the store copies onto `generationStarted`.
    ///
    /// Rev 7 closed OQ8's residual by reading the SDK: `LanguageModel` is two
    /// requirements wide — `capabilities` and an opaque `executorConfiguration`
    /// — and carries no model-identity key anywhere. There is nothing to derive
    /// a descriptor *from*, so it is app-supplied at driver init, and asking is
    /// the only correct design rather than a fallback.
    ///
    /// Non-`async` on purpose: a conforming actor must spell this
    /// `nonisolated let`, which is exactly right for a value fixed at init. A
    /// descriptor that could change between the store reading it and the
    /// generation running would put a lie in the ledger.
    var model: ModelDescriptor { get }

    /// Generates, streaming non-terminal signals into `channel`, and returns the
    /// one terminal outcome.
    ///
    /// **Does not throw, and that is the contract, not an omission.** The store
    /// appends `generationStarted` *before* this call (§7.2), so by the time a
    /// driver runs, the generation exists in the log and every failure after
    /// that point is an `Outcome` — including zero-token request-time failures
    /// like an auth rejection or an instant guardrail hit, which land as
    /// `.failed(partial: "", …)` and render as an empty failed bubble with a
    /// recovery affordance. Normalizing a provider's thrown error into a
    /// `GenerationError` (§8) is the M6 driver's job, on this side of the seam;
    /// what crosses the seam is already a terminal.
    ///
    /// **Cancellation returns, it does not throw** (§7.5). Swift convention
    /// would raise `CancellationError`; here the recording operation itself
    /// succeeded, so cancellation is a first-class ledger terminal and belongs
    /// in the same channel as every other ending. The non-throwing signature
    /// makes §11's documented deviation structural rather than merely
    /// documented — a driver *cannot* split "how it ended" across two channels.
    ///
    /// - Parameters:
    ///   - request: Rehydration material (§7.1) — see ``GenerationRequest``.
    ///   - channel: Where text deltas and tool records go as they arrive. The
    ///     store consumes them on the other side and decides when they reach
    ///     disk (§7.4, D25); a driver never waits for a flush.
    func generate(_ request: GenerationRequest, streamingInto channel: GenerationChannel) async -> Outcome
}

// MARK: - What crosses the seam

/// Everything a driver needs to rebuild a session, and nothing else (SPEC §7.1).
///
/// **Reduction output, not the log** (D21 constraint 4). Handing over events
/// would oblige every driver to re-implement the fold — and to get quarantine,
/// clamping and I5 right — to answer a question the store has already answered.
/// It would also make the seam a second reduction path, which is precisely the
/// mistake §9's snapshot fast-path made in rev 3 and P3 exists to prevent.
///
/// The initializer is **internal**, consistent with the rest of derived state
/// (M4 Phase 0): a request describes a reduction that happened, and only the
/// store performs reductions. It costs driver authors nothing they can actually
/// use, since ``Message`` cannot be hand-built either; the way to obtain test
/// material is to reduce a log — `Conversation(reducing:loadedFrom:)` — which
/// exercises the real semantics anyway.
public struct GenerationRequest: Sendable {

    /// The conversation this generation belongs to.
    ///
    /// Present because §7.8's cardinality rule needs it: one driver may serve
    /// many conversations, and its session cache is keyed by exactly this — one
    /// session per conversation, never one shared across them, because Apple's
    /// sessions are single-flight (§6.5, §7.2).
    public var conversation: ConversationID

    /// The current instructions (latest `instructionsChanged`; nil ⇒ none).
    ///
    /// In the ledger rather than on the driver because a ledger that cannot
    /// rebuild the session is not the truth (§7.1's ownership rule).
    public var instructions: String?

    /// The active path from its root-level node through the generation's parent,
    /// in order — what the model should see.
    ///
    /// Carries partials deliberately: a `.failed`, `.cancelled` or `.interrupted`
    /// message the user kept on the path contributes its text, because what the
    /// user saw is what the model sees (§7.1). Tool calls and outputs are *not*
    /// reconstructable from this — v0.1 records them as audit, not rebuild
    /// material, so a rebuilt session no longer sees prior tool results (§7.1
    /// fidelity classes, N11).
    public var context: [Message]

    /// Store-side assembly (see the type note).
    ///
    /// Deliberately carries no `GenerationID`: the store stamps identity onto
    /// every event it writes, so a driver has nothing to correlate and giving it
    /// the ID would invite it to try.
    init(conversation: ConversationID, instructions: String?, context: [Message]) {
        self.conversation = conversation
        self.instructions = instructions
        self.context = context
    }
}

/// One non-terminal thing that happened during a generation (SPEC §7.3, §7.6).
///
/// Non-terminal is the whole inventory: terminals are ``Outcome``, returned
/// rather than streamed (D21 constraint 2). Adding a terminal case here would
/// re-admit the two-terminals bug this split exists to make unrepresentable.
public enum GenerationSignal: Sendable, Equatable {

    /// New text — the *suffix*, not the accumulated whole.
    ///
    /// The framework hands consumers cumulative snapshots and the driver
    /// subtracts (§7.3), so what crosses the seam is already the fragment the
    /// provider originally sent. `deltaAppended` is append-only by construction,
    /// which is why a non-prefix snapshot must fail the generation loudly
    /// (`unrecognized("driver: non-prefix snapshot")`) rather than emit a
    /// reconstructed delta: a wrong transcript is worse than a dead one. Rev 7
    /// made that path load-bearing rather than defensive — `replaceTextSegment`
    /// is a legal provider action this version does not model.
    case delta(String)

    /// A completed tool invocation (§7.6). Record, don't orchestrate — the
    /// framework executes tools inside the session; the driver observes.
    case toolRecord(ToolRecord)
}

/// Where a driver puts its signals while it runs.
///
/// A named type rather than a bare `AsyncStream.Continuation` because a
/// continuation would hand the driver `finish()`, and a driver finishing the
/// stream would end the store's consumption loop while the driver is still
/// producing — a silently truncated generation. **Only the store terminates the
/// stream**, when `generate` returns, which is the same fact as "the terminal is
/// the return value" seen from the other side. Narrowing to ``emit(_:)``
/// additionally keeps the buffering strategy an implementation detail: swapping
/// `AsyncStream` for a back-pressured channel later is then not an API change.
///
/// Shaped after Apple's own provider seam, which is not a coincidence worth
/// hiding: `LanguageModelExecutor.respond(to:model:streamingInto:)` takes a
/// request and a channel exactly like this, one layer down. LedgerKit's driver
/// is a channel-shaped thing in the same sense — signals in flight, one ending.
///
/// **Both construction and termination are internal**, matching
/// ``GenerationRequest``: a driver receives a channel, emits into it, and can do
/// nothing else with it. Publishing `makeStream()` would buy an outside driver
/// author nothing anyway, since `generate` also needs a `GenerationRequest` that
/// only a reduction produces.
public struct GenerationChannel: Sendable {

    private let continuation: AsyncStream<GenerationSignal>.Continuation

    private init(_ continuation: AsyncStream<GenerationSignal>.Continuation) {
        self.continuation = continuation
    }

    /// A signal stream and the channel that feeds it. The store calls this per
    /// generation and keeps the reading half.
    ///
    /// **Unbounded buffering, explicitly.** It is `AsyncStream`'s default, but
    /// naming it here records that the alternatives are wrong rather than
    /// untried: any bounded policy *drops* elements, and a dropped
    /// `.delta` is lost transcript text — the exact failure the flush cadence
    /// exists to bound (§7.4). A generation that outruns its consumer should
    /// cost memory, which is recoverable, not words, which are not.
    static func makeStream() -> (signals: AsyncStream<GenerationSignal>, channel: GenerationChannel) {
        let (stream, continuation) = AsyncStream<GenerationSignal>.makeStream(bufferingPolicy: .unbounded)
        return (stream, GenerationChannel(continuation))
    }

    /// Hands a signal to the store. Never suspends, and never fails: a signal
    /// emitted after the store stopped reading is dropped, not an error, because
    /// the only way that happens is a driver still talking after it returned a
    /// terminal — a driver defect, and one whose blast radius must stay inside
    /// the driver.
    public func emit(_ signal: GenerationSignal) {
        continuation.yield(signal)
    }

    /// Ends the stream. The store's, and only the store's — called once
    /// ``GenerationDriving/generate(_:streamingInto:)`` has returned, so the
    /// consumption loop terminates whether or not the driver was well-behaved.
    func finish() {
        continuation.finish()
    }
}

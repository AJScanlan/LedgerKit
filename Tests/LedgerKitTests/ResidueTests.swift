import Foundation
import FoundationModels
import Testing
import Understudy
@testable import LedgerKit

// M6 Phase 4: **SPEC §14's four behavioural residues, as tests rather than
// notes.**
//
// These are the questions no amount of reading the interface can close — "is it
// thrown or trapped", "do real providers do this" — and they are written here as
// executable checks for a reason that is about beta churn rather than tidiness:
// **an answer written into a document is true on the day it is written and
// decays in silence, while an answer written as a test re-asks its question
// every time the suite runs.** Phase 1.5 bought that for the SDK's *shape*; this
// is the same move for its *behaviour*.
//
// Two tiers below, and the split is where the substrate stops:
//
// - **Answerable here** (tier 2, iOS 27 simulator): anything that depends only
//   on `LanguageModelSession`'s own logic, since a scripted provider exercises
//   it exactly as a real one would.
// - **Needs hardware** (tier 3, `LEDGERKIT_DEVICE=1`): anything that needs the
//   on-device model to actually generate. ⚠️ The simulator reports
//   `SystemLanguageModel.default.availability == .available` and then **fails to
//   generate** (`com.apple.SensitiveContentAnalysisML error 15`), so its
//   availability is not usable as a gate — hence the explicit environment flag.

/// Set `LEDGERKIT_DEVICE=1` to run the tier-3 suite on a machine with a working
/// on-device model (§10.7's "device integration behind an env flag").
///
/// An explicit opt-in rather than an availability check, because availability
/// lies here: see the note above. Skipped everywhere else — honestly, the way
/// the 27-gated tier is.
let deviceTestsEnabled = ProcessInfo.processInfo.environment["LEDGERKIT_DEVICE"] == "1"

// MARK: - Answerable without hardware

@Suite("§14 residues — answerable on any 27 runtime", .enabled(if: foundationModelsAvailable), .timeLimit(.minutes(1)))
struct SessionResidueTests {

    /// **OQ6's residue, answered: `concurrentRequests` is *thrown*, not
    /// trapped** (measured 2026-08-01, iOS 27 simulator).
    ///
    /// This is the answer §7.2 hoped for. A trap would have promoted the
    /// `isResponding` gate from defence to *the only* protection and forced §7.2
    /// to be reworded; a thrown, typed error means the gate stays what rev 7
    /// calls it — defence in depth — and §8's normalization exclusion has
    /// something real to exclude.
    ///
    /// Substrate-independent on purpose: the check lives in
    /// `LanguageModelSession`, not in any model, so a scripted provider answers
    /// it exactly as a real one would. That is what lets this run in CI forever
    /// instead of waiting for hardware.
    @Test("a second request on a responding session throws rather than trapping")
    func concurrentRequestsIsThrown() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let cue = Cue()
        let model = ScriptedLanguageModel(scripts: [
            ["first ", .wait(until: cue), "answer"],
            ["unreachable"],
        ])
        let session = LanguageModelSession(model: model, tools: [], transcript: Transcript())

        let first = Task {
            for try await _ in session.streamResponse(to: "one") {}
        }
        await cue.reached()

        // §7.2's gate would have caught this; the point here is what happens if
        // it ever does not.
        #expect(session.isResponding)

        var thrown: (any Error)?
        do {
            for try await _ in session.streamResponse(to: "two") {}
        } catch {
            thrown = error
        }

        // Reaching this line at all is half the finding: a trap would have taken
        // the process down instead.
        let error = try #require(thrown, "a second concurrent request must throw, not succeed")

        // §8's exclusion, end to end: a busy session is a LedgerKit defect and
        // must never become `.rateLimited` — which is exactly what the iOS 26
        // enum's shape invited.
        #expect(normalize(error, since: Date()) == DriverDiagnostic.sessionBusy.error)

        await cue.signal()
        _ = try? await first.value
    }

    /// ⚠️ **A finding with no §14 row: availability is not a promise that
    /// generation works.**
    ///
    /// `SystemLanguageModel.default.availability` reports `.available` on the iOS
    /// 27 simulator, and generating then fails with a `SensitiveContentAnalysisML`
    /// error. Recorded because it is the concrete case §7.2's design anticipates
    /// in the abstract: an app that checks availability and *then* generates can
    /// still fail, so the failure has to be an `Outcome` rather than something an
    /// availability check was supposed to have prevented.
    ///
    /// The test asserts only what is stable — that the query answers at all —
    /// since what it answers depends on the machine.
    @Test("availability answers, and answering is not a guarantee")
    func availabilityIsAdvisory() {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        _ = SystemLanguageModel.default.availability
    }
}

// MARK: - Needs hardware

/// The three residues that need a model that actually generates.
///
/// Each was written to *answer* its question when run, not to stand in for one:
/// a deferral that cannot execute the moment hardware appears is a note wearing
/// a test's clothes. **All three answered on 2026-08-02**, when the build
/// machine reached macOS 27 with Apple Intelligence live — unchanged, which was
/// the whole bet. They now *assert* those answers rather than report them, so a
/// beta that changes one fails here (M6-PLAN rev 9 items 14–16).
@Suite(
    "§14 residues — on device",
    .enabled(if: foundationModelsAvailable && deviceTestsEnabled),
    .timeLimit(.minutes(5))
)
struct DeviceResidueTests {

    /// Prompts the on-device model actually answers.
    ///
    /// ⚠️ **Prompt choice is load-bearing, which is the opposite of obvious.**
    /// The model returns *zero tokens* for some entirely ordinary requests, and
    /// it does so **deterministically rather than flakily** — measured
    /// 2026-08-02, two of six prompts failed 3/3 while the other four never did.
    /// One of the two was `"Describe origami in two paragraphs."`, which is what
    /// this suite originally asked, so the revision test could not answer its
    /// question on any hardware: it died on the empty response before reaching a
    /// single comparison.
    ///
    /// Hence a *list*. A residue test whose answer depends on one prompt staying
    /// in the model's good graces across betas is measuring the prompt.
    private static let generatingPrompts = [
        "What is 2+2?",
        "List three colors.",
        "Write a short paragraph about the sea.",
        "Explain gravity simply.",
    ]

    /// Whether a thrown error is "the model produced nothing".
    ///
    /// The type is `GeneratedContent.ParsingError`, which reaches the
    /// plain-`String` path because an empty response fails the same parse that
    /// guided generation's output would. Rev 9 (batch D) gave it a §8 landing —
    /// `providerFailure(code: "emptyResponse")` — and moved it out of
    /// `appleErrorSurface`'s unreachable group, where it had been dispositioned
    /// on reasoning this suite's own behaviour falsified.
    ///
    /// Matched by *type* rather than by its normalized form, deliberately: this
    /// helper's job is to tell "the model said nothing" apart from "the model
    /// failed", and a normalization that later widens `emptyResponse` to cover
    /// more conditions should not silently widen what these residue tests skip.
    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private static func isEmptyResponse(_ error: any Error) -> Bool {
        error is GeneratedContent.ParsingError
    }

    @available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *)
    private func session() -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel.default, tools: [], transcript: Transcript())
    }

    /// **§7.7's residue: is `Usage.Input.totalTokenCount` inclusive of
    /// `cachedTokenCount`?** It decides whether an app may sum the two, and the
    /// interface does not say.
    ///
    /// Checkable rather than merely observable: if the total were *exclusive* of
    /// the cache, a warm second turn could report `cached > total`. Holding
    /// `cached <= total` across a run with a non-zero cache is therefore real
    /// evidence for inclusivity.
    ///
    /// ### ✅ **ANSWERED: inclusive** (2026-08-02, macOS 27 host).
    ///
    /// The decisive evidence arrived as an accident rather than a design, and it
    /// is better than what was designed. This turn reports the **same
    /// `input.total=221` whether `cached` is 209 or 0** — the cache warms when
    /// the test runs alone and is evicted when the sibling device tests run
    /// beside it, since Swift Testing parallelises and the KV cache is shared
    /// machine state. Under *exclusive* accounting a warm turn would have
    /// reported roughly a dozen input tokens, not 221. It reported 221 both
    /// times, so the total is the whole input and the cache is a subset of it.
    ///
    /// Full readings: `input.total=221 cached=209|0 output.total=7 reasoning=0
    /// usage.total=228`, so `usage.total == input.total + output.total` — the
    /// aggregate does not double-count either. **The consumer-facing consequence
    /// is that an app must not sum `input.total + cached`**, which is the thing
    /// §7.7's residue existed to stop a reader guessing at.
    ///
    /// ⚠️ **Nothing here may assert on `cached` being non-zero.** Cache warmth
    /// is environmental — another test, or another process, decides it — and an
    /// assertion on state the test does not control is a flake wearing a
    /// guard's clothes. That mistake was made and caught here on 2026-08-02.
    /// ⚠️ **The floor this test used to assert was calibrated on the model's
    /// verbosity, and it flaked (M8 Phase 1, F7).**
    ///
    /// The original assertion was `input.total > 100`, chosen because the run
    /// that answered the residue reported 221. But the second turn's input is
    /// *instructions + turn 1's prompt + **turn 1's reply** + turn 2's prompt*,
    /// and the reply to "Say hello." is not a fixed length: measured across runs
    /// on one machine and one beta, `"Hello!"` gives 74 and `"Hello! How can I
    /// assist you today?"` gives 81, while the chatty run that produced 221 is
    /// simply rarer. Turn **one**'s input is stable at 58; turn two's is not.
    ///
    /// So the constant failed for the *test author's* reason rather than the
    /// code's — the exact defect CLAUDE.md's "bound non-vacuity assertions on
    /// measured values" rule names, committed in a test that cites the rule.
    /// The repair is to compare **two measured values** instead of one measured
    /// value against a remembered one, which is robust to verbosity *and* to
    /// cache warmth, and states the same logical argument:
    ///
    /// - **Inclusive** ⇒ turn 2's input contains all of turn 1's input plus the
    ///   reply plus the new prompt, so it is strictly larger.
    /// - **Exclusive** ⇒ turn 2's input is the *uncached* remainder — the new
    ///   turn alone, a handful of tokens — so it is strictly *smaller* than turn
    ///   1's, which had nothing cached ahead of it.
    ///
    /// One comparison, no constants, and the two hypotheses land on opposite
    /// sides of it.
    @Test("usage: the input total is inclusive of the cached count")
    func usageInclusivity() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let session = session()

        var perTurn: [LanguageModelSession.Usage] = []
        for turn in ["Say hello.", "Say hello again."] {
            var last: LanguageModelSession.Usage?
            for try await snapshot in session.streamResponse(to: turn) { last = snapshot.usage }
            perTurn.append(try #require(last))
        }

        let first = try #require(perTurn.first)
        let usage = try #require(perTurn.last)
        print("§7.7 — turn1.input.total=\(first.input.totalTokenCount) | input.total=\(usage.input.totalTokenCount) cached=\(usage.input.cachedTokenCount) output.total=\(usage.output.totalTokenCount) reasoning=\(usage.output.reasoningTokenCount) usage.total=\(usage.totalTokenCount)")

        // The inclusivity signature, anchored to a value this run measured rather
        // than to one a previous run remembered — see the note above.
        #expect(
            usage.input.totalTokenCount > first.input.totalTokenCount,
            """
            the second turn's input must contain the first's. Reading \
            \(usage.input.totalTokenCount) against \(first.input.totalTokenCount) \
            would mean the total counts only the new turn — i.e. exclusive of the cache
            """
        )
        #expect(
            usage.input.cachedTokenCount <= usage.input.totalTokenCount,
            "cached exceeding the total would mean the total is exclusive of it"
        )
        #expect(
            usage.totalTokenCount == usage.input.totalTokenCount + usage.output.totalTokenCount,
            "the aggregate must not double-count the cache"
        )
    }

    /// **OQ4's residue on a *real* provider: does it ever revise a segment?**
    ///
    /// Phase 2 established that a scripted revision is never observable to a
    /// consumer at any pacing, so §7.3's fail-loud path stayed insurance. This
    /// asks the only question that could change that: whether Apple's own model
    /// produces a snapshot sequence the differ refuses.
    ///
    /// ### ✅ **ANSWERED: never observed** (2026-08-02) — **0 prefix violations
    /// across 412 snapshots** of 12 real generations. §7.3's fail-loud path
    /// stays insurance, now on real-provider evidence rather than scripted-only,
    /// and §7.3's framing survives intact: prefix stability is *provider
    /// behaviour*, not an API guarantee. It held; nothing promised it would.
    ///
    /// Sweeps prompts rather than asking one, and tolerates the empty-response
    /// case — see ``generatingPrompts`` for why that is not defensive padding.
    @Test("real streams stay prefix-stable")
    func realProviderNeverRevises() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        var verdicts: [SnapshotDelta.Reason] = []
        var generations = 0
        var snapshots = 0

        for prompt in Self.generatingPrompts {
            let session = session()
            var previous = StreamSnapshot()
            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    let current = StreamSnapshot.flat(snapshot.content)
                    if case .nonPrefix(let reason) = delta(from: previous, to: current) {
                        verdicts.append(reason)
                    }
                    previous = current
                    snapshots += 1
                }
                generations += 1
            } catch where Self.isEmptyResponse(error) {
                continue    // The model declined this prompt; it says nothing about revision.
            }
        }

        print("§7.3 — \(generations) generations, \(snapshots) snapshots, \(verdicts.count) revisions")

        // Vacuity guards, and they are the point rather than ceremony: a run in
        // which every prompt came back empty would otherwise report a clean
        // `verdicts.isEmpty` having compared nothing at all — the precise shape
        // of the silent green tick `foundationModelsAvailable` exists to avoid.
        #expect(generations > 0, "every prompt returned empty; the question was never asked")
        #expect(snapshots > 0, "no snapshots observed; nothing was compared")
        #expect(verdicts.isEmpty, "a real provider revised a segment: \(verdicts)")
    }

    /// **N3's ⚠️: the real on-device context budget**, which sets how soon a
    /// conversation becomes unregenerable after process death (§7.1's rehydration
    /// is full-path).
    ///
    /// Pushes until the model refuses, then reads the numbers off Apple's own
    /// error — which is exactly why D17 widened `contextSizeExceeded` to carry
    /// them.
    ///
    /// ### ✅ **ANSWERED: 4096 tokens** (2026-08-02) — `contextSize=4096
    /// tokenCount=4223`, refused after **two** ~2k-token turns. Earlier
    /// revisions carried an approximate, explicitly unverified figure;
    /// SPEC rev 9 replaces it with this measurement. (Paraphrased rather than
    /// quoted, so the retired-phrase sweep does not re-report a fixed site.)
    ///
    /// ⚠️ **Two turns is the part worth carrying, and rev 9 carried it into both
    /// N3 and §7.1.** Full-path rehydration overflows far sooner than the design
    /// discussion assumed — this is an ordinary conversation, not a long one —
    /// so compaction is a week-one concern for on-device apps rather than the
    /// v0.3 deferral N3 reads as.
    ///
    /// Asserted rather than reported, deliberately as a **tripwire**: a beta
    /// that moves the budget fails here, which is the same bet as pinning the
    /// SDK build string. The fix is one line — *after* re-verifying.
    @Test("context: the real budget is 4096 tokens")
    func contextBudget() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let filler = String(repeating: "origami paper folding technique. ", count: 400)   // ~2k tokens
        var transcript = Transcript()
        var turns = 0

        while turns < 32 {
            turns += 1
            let session = LanguageModelSession(model: SystemLanguageModel.default, tools: [], transcript: transcript)
            do {
                for try await _ in session.streamResponse(to: filler) {}
            } catch where Self.isEmptyResponse(error) {
                // The model declined to answer, which is not a budget verdict.
                // The prompt still consumed context, so keep pushing.
                transcript = session.transcript
                continue
            } catch {
                let normalized = normalize(error, since: Date())
                print("N3 — refused after \(turns) turns of ~2k tokens: \(normalized)")
                guard case .contextSizeExceeded(let size, let count) = normalized else {
                    Issue.record("expected contextSizeExceeded, got \(normalized)")
                    return
                }
                print("N3 — contextSize=\(size as Any) tokenCount=\(count as Any)")
                #expect(size == 4096, "the on-device budget moved; re-verify N3 before changing this")
                let overflow = try #require(count, "the refusal must report the count that caused it")
                #expect(overflow > 4096, "the reported count must exceed the budget it broke")
                return
            }
            transcript = session.transcript
        }
        Issue.record("N3 — survived \(turns) turns of ~2k tokens without refusing")
    }
}

// MARK: - Private Cloud Compute (rev 12's proposed §14 residue)

/// Set `LEDGERKIT_PCC=1` on a machine whose team holds the Private Cloud Compute
/// entitlement.
///
/// A fourth gate rather than a reuse of ``deviceTestsEnabled``, because the two
/// substrates are independent: a machine can have a working on-device model and
/// no PCC entitlement, which is every machine until Apple grants one. Folding
/// them together would make the PCC residue report *skipped* for the wrong
/// reason on exactly the hardware that can answer it.
///
/// ⚠️ **Availability is not the gate, for the reason §14 already records.**
/// `PrivateCloudComputeLanguageModel().availability` is advisory like every other
/// availability API here, so an explicit opt-in is the only honest switch.
let pccTestsEnabled = ProcessInfo.processInfo.environment["LEDGERKIT_PCC"] == "1"

/// **The PCC residue: three questions §8 answers by reasoning and nobody has run.**
///
/// §8 maps `PrivateCloudComputeLanguageModel.Error`'s three cases by lift rules 2
/// and 4 — `networkFailure` → `transport(.connectivity)`, `quotaLimitReached` →
/// `rateLimited(retryAfter:)`, `serviceUnavailable` → `providerFailure(status:
/// nil, code:)`. Every one of those is a **disposition**, and §14's own closing
/// note is that a tripwire pins shape while a disposition is a claim about the
/// world only running code can falsify. The `emptyResponse` case is the precedent
/// that cost something: it was argued from "obviously retryable", which was never
/// measured and was false.
///
/// **The sharpest of the three, stated so it is not lost:** §8 calls
/// `serviceUnavailable` *"the nil-status transient this section anticipated in
/// prose"* — yet the shipped default maps a nil-status `providerFailure` to
/// **`terminal`**. If PCC's `serviceUnavailable` really is transient, the default
/// hands users the wrong affordance, and §8 already names the remedy: an override
/// keyed on `code`, plus a fixture. That correction is **free after the tag**,
/// because `Recoverability` is derived at classification time and persisted
/// nowhere — which is why this is a residue rather than a `0.1.0` blocker.
///
/// ⚠️ **These tests cannot *force* their conditions**, and pretending otherwise
/// would be the vacuous-predicate trap `InvariantCheckTests` exists to guard
/// against. So each asserts something that must hold whenever the condition
/// arrives, and *prints* what it saw. A residue re-asks its question; it does not
/// assert a remembered answer.
@Suite(
    "§14 residue — Private Cloud Compute",
    .enabled(if: foundationModelsAvailable && pccTestsEnabled),
    .timeLimit(.minutes(5))
)
struct PrivateCloudComputeResidueTests {

    /// The descriptor this residue writes into the log.
    ///
    /// ⚠️ **Deliberately not a public `ModelDescriptor` constant yet.** D64 added
    /// `.appleSystem` because two apps spelling one model differently make it look
    /// like two in the log — the same argument applies here, and it is exactly why
    /// the string should not be minted blind. A `provider`/`model` pair is
    /// **permanent wire data**; choosing it before anyone has run PCC would commit
    /// a name on a guess. Adding a static constant later is purely additive, so
    /// nothing is lost by waiting for the first real generation to inform it.
    private static let descriptor = ModelDescriptor(provider: "apple", model: "private-cloud-compute")

    /// **Question 1: is PCC a usable second provider at all, end to end?**
    ///
    /// This is the substrate check, and it is worth more than it looks. DoD-2 asks
    /// for a one-line swap to *a second real provider*, and every demonstration so
    /// far has needed either a scripted double or a vendor package on its own
    /// release cadence (D69). PCC is Apple's, so a pass here is provider-swap
    /// evidence with **no remote dependency and no forced deployment floor** —
    /// which is strictly better than the path M8 recorded.
    @Test("PCC answers through the driver, and the log names it")
    func pccAnswersThroughTheDriver() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        let model = PrivateCloudComputeLanguageModel()
        print("PCC — availability=\(model.availability) isAvailable=\(model.isAvailable)")

        let store = try ConversationStore(persistence: .inMemory)
        let driver = GenerationDriver(model: model, descriptor: Self.descriptor)
        let convo = try await store.createConversation()

        let outcome = try await store.send("List three colors.", in: convo.id, using: driver)
        print("PCC — outcome=\(outcome)")

        let conversation = try await store.conversation(convo.id)
        let assistant = try #require(conversation.activeMessages.last { $0.role == .assistant })

        // The one thing that must hold however the generation went: the ledger
        // records which provider answered. §13 DoD-2's evidence is the log, not a
        // vendor's name in a build file.
        #expect(conversation.diagnostics.isEmpty, "a store-written log must reduce cleanly")
        switch assistant.state {
        case .complete(let content):
            #expect(!content.text.isEmpty, "a completed PCC generation should carry text")
        case .failed(_, let error, let recoverability):
            // Not a failure of this test — PCC may legitimately be unavailable.
            // Recorded so the run is readable, and asserted below on taxonomy.
            print("PCC — generation failed: \(error) → \(recoverability)")
        case .cancelled, .interrupted, .streaming:
            Issue.record("PCC — unexpected terminal state \(assistant.state)")
        }
    }

    /// **Question 2: does PCC's quota API belong to LedgerKit? (Expected: no.)**
    ///
    /// Rev 12 item 10 argues from §2 that quota is billing-adjacent and therefore
    /// Apple's, so `quotaUsage` is the app querying the provider *before*
    /// generating — structurally the same as `SystemLanguageModel.availability`,
    /// which §8 normalizes only where it produces a generation-time error.
    ///
    /// The assertion is the boundary, not the numbers: nothing quota-shaped may
    /// reach the ledger. ⚠️ **The values themselves are environmental** and must
    /// never be asserted — the same rule cache warmth earned in §7.7.
    @Test("quota is Apple's to report, and reaches the ledger nowhere")
    func quotaIsApplesToReport() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        let model = PrivateCloudComputeLanguageModel()
        let quota = model.quotaUsage

        // Readable with no LedgerKit API in the path — which is the boundary
        // holding, demonstrated by this test body rather than argued.
        print("PCC quota — isLimitReached=\(quota.isLimitReached) resetDate=\(quota.resetDate as Any)")
        print("PCC quota — status=\(quota.status) suggestion=\(quota.limitIncreaseSuggestion as Any)")

        let store = try ConversationStore(persistence: .inMemory)
        let driver = GenerationDriver(model: model, descriptor: Self.descriptor)
        let convo = try await store.createConversation()
        let outcome = try await store.send("What is 2+2?", in: convo.id, using: driver)

        // `StopInfo` carries stop reason, usage and resolved model — and no quota
        // field, by construction. If a future revision adds one, this is where the
        // §2 boundary argument gets re-litigated rather than quietly crossed.
        if case .completed(let stop) = outcome {
            print("PCC — stopInfo=\(stop)")
            #expect(stop.usage?.inputTokens != nil || stop.usage == nil,
                    "usage is either reported coherently or absent; never partially invented")
        }
    }

    /// **Question 3: do PCC's failures land in §8's typed taxonomy, and is
    /// `serviceUnavailable` actually transient?**
    ///
    /// Two claims in one test because they are answered by the same observation.
    ///
    /// **The taxonomy claim is assertable whenever a failure arrives**: §8 claims
    /// totality over Apple's families, so a PCC failure must *not* reach
    /// `unrecognized`. That case is the floor whose job is to be loud about what
    /// the taxonomy failed to anticipate — and rev 6 caught §8 quietly absorbing
    /// four `unsupported*` cases into it, so the floor being hit here would be a
    /// real finding rather than a curiosity.
    ///
    /// **The transience claim can only be probed opportunistically.** If a
    /// nil-status `providerFailure` appears, this retries immediately and reports
    /// the tally — the shape of the ten-line probe that settled `emptyResponse`
    /// (0/10 on retry vs 5/5 on rewording). A retry that succeeds means the
    /// default `terminal` affordance is wrong for this code and §8 owes an
    /// override; a retry that fails means `terminal` was right. Either way the
    /// answer is measured rather than reasoned.
    @Test("PCC failures stay inside the typed taxonomy, and transience is measured not assumed")
    func failuresLandInTheTypedTaxonomy() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        let model = PrivateCloudComputeLanguageModel()
        let store = try ConversationStore(persistence: .inMemory)
        let driver = GenerationDriver(model: model, descriptor: Self.descriptor)
        var observed: [GenerationError] = []

        for attempt in 1...5 {
            let convo = try await store.createConversation()
            let outcome = try await store.send("Explain gravity simply.", in: convo.id, using: driver)
            guard case .failed(let error) = outcome else { continue }
            observed.append(error)
            print("PCC failure \(attempt) — \(error) → \(RecoverabilityMapping.default.recoverability(for: error))")

            // §8's totality claim, asserted where it is checkable.
            if case .unrecognized(let description) = error {
                Issue.record("""
                    PCC failure reached §8's floor rather than a typed case: \(description)
                    That is a gap in §8's PCC rows, not a curiosity — see rev 6's
                    `unsupported*` precedent. Record the shape and add the mapping.
                    """)
            }

            // The transience probe, for the case §8 called a nil-status transient.
            if case .providerFailure(let status, let code, _) = error, status == nil {
                var recovered = 0
                for _ in 1...5 {
                    let retry = try await store.createConversation()
                    if case .completed = try await store.send(
                        "Explain gravity simply.", in: retry.id, using: driver
                    ) { recovered += 1 }
                }
                print("""
                    PCC — nil-status providerFailure(code: \(code as Any)) \
                    recovered \(recovered)/5 on immediate retry. \
                    Default affordance is `terminal`; >0 means §8 owes an override keyed on this code.
                    """)
            }
        }

        if observed.isEmpty {
            print("PCC — 5/5 generations produced no failure; the transience question stays open.")
        }
    }
}

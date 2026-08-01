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
/// Each is written to *answer* its question when run, not to stand in for one:
/// a deferral that cannot execute the moment hardware appears is a note wearing
/// a test's clothes.
@Suite(
    "§14 residues — on device",
    .enabled(if: foundationModelsAvailable && deviceTestsEnabled),
    .timeLimit(.minutes(5))
)
struct DeviceResidueTests {

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
    /// evidence for inclusivity — and the numbers are surfaced either way, since
    /// this test exists to produce an answer for §7.7 to record.
    @Test("usage: is the input total inclusive of the cached count?")
    func usageInclusivity() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let session = session()

        var last: LanguageModelSession.Usage?
        for turn in ["Say hello.", "Say hello again."] {
            for try await snapshot in session.streamResponse(to: turn) { last = snapshot.usage }
        }

        let usage = try #require(last)
        Issue.record("§7.7 residue — input.total=\(usage.input.totalTokenCount) cached=\(usage.input.cachedTokenCount) output.total=\(usage.output.totalTokenCount) reasoning=\(usage.output.reasoningTokenCount) usage.total=\(usage.totalTokenCount)")
        #expect(
            usage.input.cachedTokenCount <= usage.input.totalTokenCount,
            "cached exceeding the total would mean the total is exclusive of it"
        )
    }

    /// **OQ4's residue on a *real* provider: does it ever revise a segment?**
    ///
    /// Phase 2 established that a scripted revision is never observable to a
    /// consumer at any pacing, so §7.3's fail-loud path stayed insurance. This
    /// asks the only question that could change that: whether Apple's own model
    /// produces a snapshot sequence the differ refuses.
    @Test("real streams stay prefix-stable")
    func realProviderNeverRevises() async throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }
        let session = session()
        var previous = StreamSnapshot()
        var verdicts: [SnapshotDelta.Reason] = []

        for try await snapshot in session.streamResponse(to: "Describe origami in two paragraphs.") {
            let current = StreamSnapshot.flat(snapshot.content)
            if case .nonPrefix(let reason) = delta(from: previous, to: current) { verdicts.append(reason) }
            previous = current
        }

        #expect(verdicts.isEmpty, "a real provider revised a segment: \(verdicts)")
    }

    /// **N3's ⚠️: the real on-device context budget**, which sets how soon a long
    /// conversation becomes unregenerable after process death (§7.1's rehydration
    /// is full-path).
    ///
    /// Pushes until the model refuses, then reads the numbers off Apple's own
    /// error — which is exactly why D17 widened `contextSizeExceeded` to carry
    /// them.
    @Test("context: what is the real budget?")
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
            } catch {
                let normalized = normalize(error, since: Date())
                Issue.record("N3 residue — refused after \(turns) turns of ~2k tokens: \(normalized)")
                guard case .contextSizeExceeded(let size, let count) = normalized else {
                    Issue.record("expected contextSizeExceeded, got \(normalized)")
                    return
                }
                Issue.record("N3 residue — contextSize=\(size as Any) tokenCount=\(count as Any)")
                return
            }
            transcript = session.transcript
        }
        Issue.record("N3 residue — survived \(turns) turns without refusing")
    }
}

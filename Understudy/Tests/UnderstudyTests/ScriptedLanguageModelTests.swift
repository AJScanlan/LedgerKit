import Foundation
import FoundationModels
import Testing
@testable import Understudy

// The Foundation Models conformance. These **compile** on the current toolchain
// (Xcode 27 / macOS 27 SDK) and **run** on macOS 27; on an older OS they report
// as *skipped* rather than passing. That distinction is the whole point of the
// trait below — a `guard #available … else { return }` would turn every one of
// these into a silent green tick on this machine, which is exactly the kind of
// test that certifies nothing.
//
// Compiling them is already the larger half of the value: it is what proves
// `ScriptedLanguageModel` satisfies Apple's real protocols rather than a
// hand-written imitation of them. The engine's behaviour — ordering,
// cancellation, exhaustion, determinism — lives in `ScriptPlayerTests`, which
// runs today.

/// Whether the running OS can execute Foundation Models' 27-era API.
let foundationModelsAvailable: Bool = {
    if #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) { true } else { false }
}()

@Suite("ScriptedLanguageModel — the conformance", .enabled(if: foundationModelsAvailable))
struct ScriptedLanguageModelTests {

    @Test("a model and its executor configuration share one playbook")
    func configurationCarriesIdentity() throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        // The framework builds executors from `Configuration`, so this identity
        // is what connects every executor back to one model's cursor and
        // recorded requests. If `Configuration` ever became a plain value, the
        // spy would silently record nothing.
        let model = ScriptedLanguageModel(script: "hello")
        let first = model.executorConfiguration
        let second = model.executorConfiguration

        #expect(first == second)
        #expect(first.hashValue == second.hashValue)

        let other = ScriptedLanguageModel(script: "hello")
        #expect(first != other.executorConfiguration, "two models are two playbooks")
    }

    @Test("a fresh model has answered nothing")
    func startsWithNoRequests() {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        let model = ScriptedLanguageModel(script: "hello")
        #expect(model.requests.isEmpty)
    }

    @Test("capabilities are empty unless the test asks for them")
    func capabilitiesAreOptIn() {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        // A double should not promise what it cannot honour; code branching on
        // capabilities should see "nothing supported" until a test says so.
        var model = ScriptedLanguageModel(script: "hello")
        #expect(model.capabilities.contains(.toolCalling) == false)

        model.capabilities = LanguageModelCapabilities([.toolCalling])
        #expect(model.capabilities.contains(.toolCalling))
    }

    @Test("the executor is constructible from the configuration, as the framework does it")
    func executorConstruction() throws {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        let model = ScriptedLanguageModel(script: "hello")
        let executor = try ScriptedLanguageModelExecutor(configuration: model.executorConfiguration)

        // Prewarming is a no-op but must not trap: Apple documents it as
        // best-effort and callable at any time.
        executor.prewarm(model: model, transcript: Transcript())
    }

    @Test("a scripted model is accepted wherever a real one is")
    func satisfiesTheProtocol() {
        guard #available(macOS 27.0, iOS 27.0, visionOS 27.0, watchOS 27.0, *) else { return }

        // The assertion is the compiler's. If `LanguageModel`'s requirements
        // change in a later beta, this stops building — the earliest and
        // cheapest possible warning.
        func accept(_ model: some LanguageModel) -> Bool { true }
        #expect(accept(ScriptedLanguageModel(script: "hello")))
    }
}

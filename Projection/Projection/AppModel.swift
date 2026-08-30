import Foundation
import FoundationModels
import LedgerKit
import Understudy

// M8 Phase 2 — the app's one piece of shared state (M8-PLAN D51).
//
// **What lives here and what deliberately does not.** This owns the
// `ConversationStore` — opened once, at launch — and the `driver()` factory,
// which is the only place in the app a provider is named. It owns **no
// conversation state**: screens create their own projections, because a
// projection is derived, rebuildable and deletable (tenet 2), and a facade
// holding one per conversation would keep projections alive for conversations
// nobody is looking at. That facade was considered and declined in the library
// too (M7-PLAN D42); declining it again here is the same argument one layer up.

/// The store, the provider line, and the error channel — everything a screen
/// needs that outlives the screen.
@available(macOS 27.0, iOS 27.0, *)
@MainActor
@Observable
final class AppModel {

    /// The durable ledger. `let`, so there is no setter for `@Observable` to
    /// invalidate on and no way for a screen to swap it.
    let store: ConversationStore

    /// The last error the throw channel produced, or `nil` (M8-PLAN D55).
    ///
    /// `LedgerError` is `Equatable`, so `@Observable`'s generated setter
    /// short-circuits when the same error is presented twice — which matters
    /// here because a user hammering a disabled-looking button would otherwise
    /// re-invalidate the whole screen per tap.
    var presentedError: LedgerError?

    /// Where the demo's database lives (M8-PLAN D52).
    ///
    /// Application Support, not Documents: this is app-managed state the user
    /// never browses. The library applies
    /// `.completeUntilFirstUserAuthentication` on the iOS family and the demo
    /// **adds nothing on top, deliberately** — a demo that layered its own
    /// encryption would imply the library needs it for ordinary use, which §9
    /// does not claim. Picking the directory is the app's job exactly as
    /// ADR-003 says it is.
    static func databaseURL() throws -> URL {
        // A UI test gets its own throwaway database, per launch. Two reasons,
        // and the second is the one that matters: a test that shared the real
        // store would leave conversations behind on the machine recording the
        // GIF, and — worse — would *start* from whatever the last run left, so
        // "the empty state appears" could pass or fail depending on history.
        let directory = isUITesting
            ? URL.temporaryDirectory.appending(path: "LedgerKitUITests/\(UUID().uuidString)",
                                               directoryHint: .isDirectory)
            : URL.applicationSupportDirectory.appending(path: "LedgerKit",
                                                        directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "demo.sqlite")
    }

    /// Whether this launch is being driven by `ProjectionUITests`.
    ///
    /// A launch argument rather than a build configuration, so the very same
    /// binary that ships is the one under test — a `#if DEBUG` fork would let
    /// the tested app and the real app drift.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest")
    }

    /// Opens the store. **`.sqlite(at:)`, from the very first run.**
    ///
    /// The M7 preview was `.inMemory` and therefore *could not* show recovery —
    /// swapping this one line is what makes DoD-1 demonstrable rather than
    /// described. Choosing it now rather than at Phase 3 is deliberate: a
    /// stale-state bug found while building is far cheaper than one found while
    /// recording, and in-memory is the configuration that hides exactly that
    /// class of bug.
    init() throws {
        store = try ConversationStore(persistence: .sqlite(at: Self.databaseURL()))
    }

    // MARK: - The provider line

    /// **DoD-2's one line, and the only place in this app a provider is named.**
    ///
    /// Swapping `ScriptedLanguageModel` for `SystemLanguageModel.default`,
    /// `ClaudeLanguageModel(name:auth:)` or `PrivateCloudComputeLanguageModel()`
    /// — plus the matching descriptor — is the entire provider swap. Everything
    /// else in the app is provider-agnostic because the library never lets a
    /// provider type reach it (tenet 3).
    ///
    /// Scripted for now (M8-PLAN D53, deferred to Phase 3): it needs no
    /// credentials, no network and no Apple Intelligence eligibility, so the
    /// whole app runs on any machine — which is tenet 5 paying out at the app
    /// layer rather than only in tests.
    ///
    /// ⚠️ **The `.wait` steps are load-bearing, not decoration.** Without them
    /// the framework coalesces the whole response into one or two snapshots
    /// (measured at M6), so the stream would land in a single frame and
    /// demonstrate nothing. Pacing is what makes streaming *visible*.
    func driver() -> GenerationDriver {
        GenerationDriver(model: language, descriptor: descriptor)
    }

    /// **The provider, chosen once.** Still one decision in one place — the
    /// driver above is still constructed exactly once, which is what guardrail 3
    /// greps for — but a UI test needs a provider that says the same thing every
    /// run, and asserting against a real model would be asserting the model.
    /// That is tenet 5 at the app layer: the double is first-class, so the test
    /// exercises every layer except which provider answered.
    private var language: any LanguageModel {
        Self.isUITesting ? ScriptedLanguageModel(script: Self.demoScript) : SystemLanguageModel.default
    }

    private var descriptor: ModelDescriptor {
        Self.isUITesting
            ? ModelDescriptor(provider: "understudy", model: "scripted")
            // What the `SystemLanguageModel` convenience initializer defaults to,
            // spelled out because this path no longer goes through it. Version
            // stays nil: which *build* answered is genuinely unknown, and a guess
            // would be a fabrication in an append-only log (§7.8).
            : ModelDescriptor(provider: "apple", model: "system")
    }

    /// ⚠️ **The chunk boundaries are the test, not the content.**
    ///
    /// Several of these split *inside* Markdown syntax — `"**Val"` before its
    /// closing `**`, a list marker arriving before its item text. That is the
    /// condition `SwiftStreamingMarkdown` exists for, and the condition a naïve
    /// renderer fails visibly: it flashes raw asterisks, then reflows when the
    /// delimiter closes. Splitting cleanly on word boundaries would make the
    /// spike look like it worked without testing anything.
    ///
    /// It is also honest about our own pipeline: real deltas do not respect
    /// syntax, because the framework coalesces snapshots on its own cadence and
    /// §7.4's flush policy reshapes them again.
    private static var demoScript: Script {
        Script(
            [
                "Three folds worth knowing:\n\n",
                "- **Val", "ley fold** — the paper ", "comes toward you, ",
                "forming a V.\n",
                "- **Moun", "tain fold** — the mirror ", "image, folding away.\n",
                "- **Squash ", "fold** — open a flap ", "and flatten it.\n\n",
                "Every model is ", "these three, repeated.",
            ]
            .flatMap { [Script.Step.emit($0), .wait(.milliseconds(280))] }
        )
    }

    // MARK: - Verbs

    /// Sends a turn. **Both halves of §11's two-channel contract are handled
    /// here** — which is the point of doing it in one place.
    ///
    /// The `try` guards *did it start*; the return value would say *how it
    /// ended*, and it is discarded on purpose: every state along the way already
    /// reached the screen through the projection, so rendering the terminal
    /// would be a second, competing copy of the truth.
    func send(_ text: String, in conversation: ConversationID) async {
        await recording { _ = try await store.send(text, in: conversation, using: driver()) }
    }

    func regenerate(_ message: MessageID, in conversation: ConversationID) async {
        await recording { _ = try await store.regenerate(message, in: conversation, using: driver()) }
    }

    func stop(in conversation: ConversationID) async {
        await store.cancelGeneration(in: conversation)
    }

    func createConversation() async -> ConversationID? {
        var created: ConversationID?
        await recording { created = try await store.createConversation().id }
        return created
    }

    func setTitle(_ title: String?, in conversation: ConversationID) async {
        await recording { try await store.setTitle(title, in: conversation) }
    }

    func delete(_ conversation: ConversationID) async {
        await recording { try await store.deleteConversation(conversation) }
    }

    func switchBranch(to endpoint: MessageID, in conversation: ConversationID) async {
        await recording { try await store.switchBranch(to: endpoint, in: conversation) }
    }

    // MARK: - The throw channel (D55)

    /// Runs a verb and **renders** what it could not record.
    ///
    /// The M7 preview wrote `try? await store.send(…)`, which is fine for a
    /// preview and wrong for the demo: §11's pitch is *one channel for "couldn't
    /// record", one for "recorded a failure"*, and swallowing the first leaves
    /// the app demonstrating half of it.
    private func recording(_ verb: () async throws -> Void) async {
        do {
            try await verb()
        } catch let error as LedgerError {
            present(error)
        } catch is CancellationError {
            // §7.2's near side: cancelled *before* the start append, so nothing
            // was recorded and there is nothing to say. Swift's own convention,
            // borrowed rather than re-spelled — which is why the library
            // deliberately has no `LedgerError` case for it.
        } catch {
            present(.persistenceFailure(description: String(describing: error)))
        }
    }

    /// D55's per-case table, as an exhaustive `switch` rather than a filter.
    ///
    /// No `default:`, for the same reason no screen has one: a new
    /// `LedgerError` case should stop this app compiling until someone decides
    /// whether the user needs to hear about it.
    private func present(_ error: LedgerError) {
        switch error {
        case .generationInFlight:
            // **Prevented, not failed.** The composer's send control is already
            // disabled while a generation runs, so an alert here would explain a
            // state the user cannot get into — and §6.5's whole argument for
            // throwing rather than queueing is that the app disables the button.
            break
        case .persistenceFailure:
            // The disk is the user's problem to know about.
            presentedError = error
        case .unknownConversation, .unknownMessage, .ineligibleTarget, .unsupportedTarget:
            // Unreachable through this UI — every target is picked from the tree
            // the projection just rendered. Rendered anyway, because **that is
            // how we find out if it ever stops being unreachable.**
            presentedError = error
        }
    }
}

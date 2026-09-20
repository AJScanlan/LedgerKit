import Foundation
import Testing
@testable import LedgerKit

// MARK: - The promise these tests enforce

// **The README's pre-1.0 caveat (D67, DoD-5) splits LedgerKit's public enums in
// two, and the split is a promise: the *stable* set may be switched exhaustively,
// with no `default`, and a minor version will not break those switches.**
//
// A promise nothing checks is an intention. This file is the check.
//
// **The mechanism is the `switch`, not the `#expect`.** Every function below
// switches one stable enum with no `default`, so **adding a case to any of them
// is a compile error in this file** — which is the failure a consumer would get,
// surfaced in the repo that caused it rather than in their app six months later.
// The assertions exist so the *promised case list* is written somewhere a human
// reads, and so the failure message can name the promise; they are not the
// tripwire.
//
// ⚠️ **Do not repair a failure here by adding `default:`.** That compiles, and it
// silently retires the only thing enforcing the README. If a stable enum genuinely
// must gain a case, that is a **breaking change to a documented promise**: move the
// enum to the README's *growable* list in the same change, and say so in the
// release notes. The whole point is that the decision cannot be made by accident.
//
// **⚠️ Mutation-tested, and the result changed what this file is for.** Two cases
// were injected and the build run each time (2026-09-20):
//
//   * `MessageState.paused` — caught **first** by `GenerationDriver.visibleText`,
//     then by `APISketchTests`' §11 showpiece, and only then here. Repairing the
//     first two made this file the one that failed, so it *is* the backstop —
//     but it is never the first line.
//   * `Outcome.abandoned` — caught **first** by `Outcome.encode(to:)`, because a
//     new case needs a wire tag.
//
// So the compiler already rejects an added case for all five, by routes that
// exist for other reasons. **This file adds no detection. It adds the reason.**
// Every incidental catch fails for a local cause — an encoder needs a tag, a
// helper needs a branch — and an author repairing them is never told they broke a
// *documented promise to consumers*; they will fix three switches and ship it.
// This is the only site whose failure says so, and the only one that does not
// quietly evaporate if a stable enum stops being `Codable` or a driver helper is
// refactored away. Recorded rather than dressed up: a mutation caught by
// something else is a result, and the honest response is to state what property
// is left rather than to claim the coverage.
//
// **Why this is not a second copy of `Wire` (M4 Phase 4's rule).** `Wire` is a
// list of instances, so naming every case makes *deletion* a compile error —
// that is the direction the wire cares about, because a removed tag is a log that
// stops reading. This file catches *addition*, which is the direction **source**
// compatibility cares about, and a list cannot catch it: appending a case to
// `Outcome` leaves `Wire.allOutcomes` compiling and passing. Opposite failure,
// opposite mechanism, so extending `Wire` would not have worked. Two of the five
// are not wire types at all — `MessageState` is deliberately **not** `Codable`
// (it is the public projection of the internal `FoldedMessageState`), and
// `Recoverability` is derived at classification time and persisted nowhere (§8).

// MARK: - Discriminators (the exhaustive switches — the actual tripwire)

private func promisedCase(of role: Role) -> String {
    switch role {
    case .user: "user"
    case .assistant: "assistant"
    }
}

private func promisedCase(of state: MessageState) -> String {
    switch state {
    case .complete: "complete"
    case .streaming: "streaming"
    case .failed: "failed"
    case .cancelled: "cancelled"
    case .interrupted: "interrupted"
    }
}

private func promisedCase(of recoverability: Recoverability) -> String {
    switch recoverability {
    case .retryable: "retryable"
    case .recoverableUpstream: "recoverableUpstream"
    case .terminal: "terminal"
    }
}

private func promisedCase(of outcome: Outcome) -> String {
    switch outcome {
    case .completed: "completed"
    case .failed: "failed"
    case .cancelled: "cancelled"
    }
}

private func promisedCase(of status: ToolRecord.Status) -> String {
    switch status {
    case .succeeded: "succeeded"
    case .failed: "failed"
    }
}

// MARK: - Tests

/// The five enums the README promises are exhaustively switchable.
///
/// One instance per case, so the promised list is stated rather than counted:
/// a reviewer can read what `0.1.0` committed to without running anything.
@Suite("Public API — the enums promised stable")
struct PublicAPIStabilityTests {

    @Test("Role's promised cases")
    func roleIsStable() {
        let all: [Role] = [.user, .assistant]
        #expect(all.map(promisedCase) == ["user", "assistant"], Self.brokenPromise)
    }

    @Test("MessageState's promised cases — the showpiece switch")
    func messageStateIsStable() {
        // The five-case switch §11 advertises and the README leads with. SPEC
        // keeps it this size on purpose: new information attaches to `Message`
        // (`stopInfo`, `terminalTimestamp`) or extends `MessageContent` (N8's
        // structured partials), never by adding a case here.
        let all: [MessageState] = [
            .complete(MessageContent(text: "done")),
            .streaming(partial: "partial"),
            .failed(partial: "partial", error: .refusal, recoverability: .terminal),
            .cancelled(partial: "partial"),
            .interrupted(partial: "partial"),
        ]
        #expect(
            all.map(promisedCase) == ["complete", "streaming", "failed", "cancelled", "interrupted"],
            Self.brokenPromise
        )
    }

    @Test("Recoverability's promised cases")
    func recoverabilityIsStable() {
        // Three affordances, not three conditions — §8 groups the four
        // `unsupported*` errors precisely so this stays proportional to what an
        // app can *do*. A fourth affordance is a real product decision, which is
        // why it should cost a broken build rather than a quiet addition.
        let all: [Recoverability] = [
            .retryable(after: nil),
            .recoverableUpstream(.reduceContext),
            .terminal,
        ]
        #expect(
            all.map(promisedCase) == ["retryable", "recoverableUpstream", "terminal"],
            Self.brokenPromise
        )
    }

    @Test("Outcome's promised cases — tenet 4's three endings")
    func outcomeIsStable() {
        // I7: every generation ends in exactly one of these, or is derivably
        // `.interrupted`. A fourth ending would not be an API addition so much
        // as a new invariant.
        let all: [Outcome] = [.completed(StopInfo()), .failed(.refusal), .cancelled]
        #expect(all.map(promisedCase) == ["completed", "failed", "cancelled"], Self.brokenPromise)
    }

    @Test("ToolRecord.Status's promised cases")
    func toolRecordStatusIsStable() {
        let all: [ToolRecord.Status] = [.succeeded, .failed]
        #expect(all.map(promisedCase) == ["succeeded", "failed"], Self.brokenPromise)
    }

    // MARK: Private

    // `Comment`, not `String`: `#expect`'s second parameter is `Comment?`, and a
    // stored `String` does not convert where a literal would.
    private static let brokenPromise: Comment = """
        A stable enum's cases changed. The README's pre-1.0 caveat promises this \
        enum can be switched exhaustively without a `default`, so this is a \
        **breaking change to a documented promise**, not a routine addition.

        If the case is genuinely needed: move the enum to the README's *growable* \
        list in the same change and note it in the release notes. Do **not** add a \
        `default:` to the switch in this file — that compiles, and it retires the \
        only thing enforcing the promise.
        """
}

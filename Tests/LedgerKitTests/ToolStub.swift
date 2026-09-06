import Foundation
import FoundationModels

// A minimal `Tool`, needed only because `LanguageModelSession.ToolCallError`
// carries an `any Tool` and Phase 1.5 found that error type unhandled.
//
// ✅ **The constraint this file was written under is gone as of M9's D62**, and
// the history is worth keeping because it is what bought the rename.
//
// Through M8, LedgerKit shipped a public `GenerationID` — and so does Foundation
// Models. `@Generable` expands to code referring to that name **unqualified**, so
// in any file importing both modules the macro failed to compile, with an error
// pointing into an expansion its author never wrote:
//
//     error: 'GenerationID' is ambiguous for type lookup in this context
//     error: cannot assign value of type 'GenerationID' to type 'ObjectIdentifier'
//
// That landed on **consumers**, not merely on this test: `@Generable` is the
// ordinary way to declare tool arguments. The workaround was to keep such types
// in a file that does not import LedgerKit — which is why this one still doesn't,
// though it no longer has to.
//
// D62 renamed the type to `GenerationAttemptID`, and the fix was verified the way
// the problem was found: from a throwaway *consumer* package importing both
// modules, with a `@Generable` struct and both identifiers named side by side.
// It compiles. **The file split is retained anyway** — this file has no need of
// LedgerKit, so importing it to prove a point would be the artificial half of the
// demonstration, and a `Tool` stub is exactly where a future reader would
// reintroduce the problem if the name ever drifted back.

/// Arguments for ``StubTool``. `Tool` with `Arguments == String` is explicitly
/// *unavailable* ("Use `@Generable` struct instead"), so this is the smallest
/// conformance the SDK permits.
@Generable
struct StubArguments {
    var value: String
}

/// A tool that exists so a `ToolCallError` has something to name.
struct StubTool: Tool {
    let description = "a tool that exists so an error can name it"

    func call(arguments: StubArguments) async throws -> String {
        arguments.value
    }
}

/// A tool that always throws — the other half of §7.6's `ToolRecord.Status`
/// (M7 Phase 0 A1).
///
/// Throws a **`URLError`** specifically, so the test can assert two things at
/// once: that a failed invocation reaches the ledger with `status: .failed`, and
/// that the *terminal* carries the error from **inside** the wrapper. §8's rule is
/// that a wrapper is transparent to normalization — "a tool whose network call
/// timed out must give the user `transport(.timeout)` and a Retry, not an opaque
/// tool-shaped mystery" — and a tool throwing something already unclassifiable
/// could not distinguish unwrapping from failing to unwrap.
struct FailingTool: Tool {
    let description = "a tool that always fails, so a failed invocation can be observed"

    func call(arguments: StubArguments) async throws -> String {
        throw URLError(.timedOut)
    }
}

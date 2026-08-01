import Foundation
import FoundationModels

// A minimal `Tool`, needed only because `LanguageModelSession.ToolCallError`
// carries an `any Tool` and Phase 1.5 found that error type unhandled.
//
// ⚠️ **This file deliberately does not import LedgerKit, and that is a finding
// rather than a style choice.**
//
// `@Generable` expands to code referring to `GenerationID` *unqualified* — and
// **LedgerKit ships a public `GenerationID` of its own** (ADR-002's identifier
// set). In any file importing both modules the name is ambiguous, so the macro
// fails to compile with an error pointing into an expansion the author never
// wrote:
//
//     error: 'GenerationID' is ambiguous for type lookup in this context
//     error: cannot assign value of type 'GenerationID' to type 'ObjectIdentifier'
//
// That lands on **consumers**, not just on this test: any app using `@Generable`
// — which is the ordinary way to declare tool arguments — in a file that also
// imports LedgerKit hits it. The workaround is exactly what this file does:
// keep `@Generable` types in a file that does not import LedgerKit. Recorded for
// rev 9 / M9's naming review, because the alternative is renaming a core public
// identifier type and that is not a decision to take in passing.

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

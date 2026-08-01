import Foundation
import Testing
@testable import LedgerKit

// Tenet 3 in its code form (M6-PLAN guardrail 2): **Foundation Models never
// leaks out of `Session/`.**
//
// The boundary is the whole design — §2's map says Apple owns inference and
// LedgerKit owns durable state, and §7 exists so all the beta risk sits in one
// module. That is easy to state and easy to erode one convenient import at a
// time, because each individual one always looks harmless. This test is the
// cheap mechanical check that it has not happened, in the same spirit as
// `Registry/tags.json`: a rule nobody can quietly break.
//
// It reads the source tree, which is a dev-only path — hence the trait. Anywhere
// the tree is unreachable the suite reports **skipped** rather than passing
// vacuously, which is the same honesty `.enabled(if: foundationModelsAvailable)`
// buys for the 27-gated suites.

/// The package's `Sources/` directory, if this run can see it.
private let sourceRoot: URL? = {
    // …/LedgerKit/Tests/LedgerKitTests/ImportBoundaryTests.swift → …/LedgerKit/Sources
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")
    return FileManager.default.fileExists(atPath: root.path) ? root : nil
}()

@Suite("Session — the Foundation Models boundary", .enabled(if: sourceRoot != nil))
struct ImportBoundaryTests {

    /// Every `.swift` file under `Sources/`, with its path relative to that root.
    private func sources() throws -> [(path: String, text: String)] {
        let root = try #require(sourceRoot)
        let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))

        return try enumerator.compactMap { entry in
            guard let relative = entry as? String, relative.hasSuffix(".swift") else { return nil }
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            return (relative, text)
        }
    }

    @Test("FoundationModels is imported only under Session/")
    func importsAreConfined() throws {
        let files = try sources()

        let importers = files.filter { $0.text.contains("import FoundationModels") }
        let offenders = importers.map(\.path).filter { !$0.contains("Session/") }.sorted()

        #expect(offenders.isEmpty, "Foundation Models must not be imported outside Session/: \(offenders)")

        // **The vacuity guards, which are the reason this test is worth having
        // rather than believing.** A walk that found nothing — a moved
        // directory, a renamed target — would satisfy the assertion above
        // perfectly while checking nothing at all, which is exactly the failure
        // mode `InvariantCheckTests` exists to prevent for the reducer's
        // predicates.
        #expect(files.count > 20, "the source walk found \(files.count) files, which cannot be right")
        #expect(!importers.isEmpty, "no file imports Foundation Models, so this test proved nothing")
    }

    /// The other half of the same rule: `Session/` is the only module that may
    /// name Apple's inference types at all, so no *other* directory should be
    /// referring to them even without an import (via a fully-qualified name, or
    /// a re-export).
    @Test("no module outside Session/ names Apple's inference types")
    func typesStayInsideTheSeam() throws {
        let names = ["LanguageModelSession", "SystemLanguageModel", "LanguageModelError", "Transcript("]
        var offenders: [String] = []

        for file in try sources() where !file.path.contains("Session/") {
            // Comments discuss these types constantly and must keep being able
            // to — §7's whole design is documented in prose that names them. Only
            // code counts.
            let code = file.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for name in names where code.contains(name) {
                offenders.append("\(file.path): \(name)")
            }
        }

        #expect(offenders.isEmpty, "Apple's inference types must stay inside Session/: \(offenders)")
    }
}

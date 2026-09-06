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
//
// ⚠️ **Scoped to `Sources/LedgerKit` at M9 Phase 2 (D61), and the reason is the
// rule rather than the layout.** Consolidating the two packages put `Understudy`
// under the same `Sources/` root, and `ScriptedLanguageModel` imports Foundation
// Models **legitimately** — conforming to Apple's real protocols instead of an
// imitation of them is the whole of M3's D11. An unscoped walk therefore
// reported it as a violation on the first run after the move. The confinement
// rule was always *LedgerKit's* ("all the beta risk sits in one module of this
// library"), so the walk now says so; a rule that has to be re-read to be
// applied to a sibling product was never stated precisely enough.

/// The package's `Sources/` directory, if this run can see it.
private let sourcesRoot: URL? = {
    // …/Tests/LedgerKitTests/ImportBoundaryTests.swift → …/Sources
    //
    // Three components up lands on the **package root**, which since D61 is also
    // the repo root — the same arithmetic as before the move, because the file's
    // depth below its package did not change.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")
    return FileManager.default.fileExists(atPath: root.path) ? root : nil
}()

/// The library's own sources — what the confinement rule is about.
private let sourceRoot: URL? = sourcesRoot.map { $0.appendingPathComponent("LedgerKit") }
    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

/// `Understudy`'s sources, for the reverse boundary below.
private let understudyRoot: URL? = sourcesRoot.map { $0.appendingPathComponent("Understudy") }
    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

/// Every `.swift` file under `root`, with its path relative to it.
private func swiftFiles(under root: URL) throws -> [(path: String, text: String)] {
    let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))
    return try enumerator.compactMap { entry in
        guard let relative = entry as? String, relative.hasSuffix(".swift") else { return nil }
        let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        return (relative, text)
    }
}

@Suite("Session — the Foundation Models boundary", .enabled(if: sourceRoot != nil))
struct ImportBoundaryTests {

    /// Every `.swift` file under `Sources/LedgerKit`, with its path relative to that root.
    private func sources() throws -> [(path: String, text: String)] {
        let root = try #require(sourceRoot)
        return try swiftFiles(under: root)
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

// MARK: - The reverse boundary (D61)

/// The other direction of the same discipline: **`Understudy` must never depend
/// on LedgerKit.**
///
/// SPM forbids dependency cycles and the direction actually needed is the
/// reverse — LedgerKit's *test* target imports `ScriptedLanguageModel` for its
/// store and driver suites (M5, M6), which is only possible if nothing in
/// `Understudy` points back. It is also the product's positioning: a
/// deterministic Foundation Models double is useful to any FM app (SPEC §10.1),
/// and one that drags in a conversation-ledger library is not.
///
/// ## Why this exists when the build already enforces it
///
/// Since D61 merged the two packages, `Understudy` is a sibling target with an
/// empty dependency list, so an `import LedgerKit` inside it fails to *resolve*.
/// That is strictly stronger than the two-package arrangement it replaced — but
/// it is not the whole rule, because it is one manifest line away from being
/// switched off. Adding `"LedgerKit"` to that target's `dependencies` would make
/// every such import compile, silently, and nothing else in the repo would
/// notice.
///
/// So this suite checks **both halves**: no import in the sources, and no
/// dependency in the manifest. The build covers the first today; only the second
/// survives someone deciding the first was inconvenient.
///
/// ## Mutation evidence (M9 Phase 2, D61), including one result worth keeping
///
/// - Adding `import LedgerKit` to `Sources/Understudy/Cue.swift` **alone** does
///   not fail this suite — it fails the *build*, with
///   `error: unable to resolve module dependency`, so no test runs at all. The
///   manifest comment's claim is therefore proven rather than asserted, and the
///   honest reading is that ``understudyDoesNotImportLedgerKit()`` cannot fire
///   in a repo where only the import was added.
/// - Which raises the question that matters — **is it dormant?** No. Adding the
///   manifest dependency *and* the import (the realistic shape: somebody wires
///   the dependency because they want the import) fails **both** tests. Checked,
///   because a test whose only reachable world is one that already fails to
///   compile would be exactly D36's dormancy wearing a green tick.
/// - Adding `"LedgerKit"` to the target's `dependencies` alone fails
///   ``manifestKeepsUnderstudyIndependent()``, which is the case the compiler
///   cannot see and the reason this second test exists.
@Suite("Understudy — the reverse boundary", .enabled(if: understudyRoot != nil))
struct UnderstudyBoundaryTests {

    @Test("Understudy never imports LedgerKit")
    func understudyDoesNotImportLedgerKit() throws {
        let root = try #require(understudyRoot)
        let files = try swiftFiles(under: root)

        let offenders = files
            .filter { $0.text.contains("import LedgerKit") }
            .map(\.path)
            .sorted()

        #expect(
            offenders.isEmpty,
            """
            Understudy must not depend on LedgerKit (SPEC §10.1): \(offenders).
            The dependency LedgerKit needs is the reverse one — its test target \
            imports Understudy — and SPM forbids the cycle.
            """
        )

        // The vacuity guard, for `ImportBoundaryTests`' reason: a walk that found
        // nothing would satisfy the assertion above perfectly while checking
        // nothing at all. Understudy is five files; pinned below that.
        #expect(files.count >= 4, "the Understudy walk found \(files.count) files, which cannot be right")
    }

    @Test("the manifest does not give Understudy a LedgerKit dependency")
    func manifestKeepsUnderstudyIndependent() throws {
        let root = try #require(understudyRoot)
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // package root
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)

        let understudy = Self.targetBlocks(in: manifest)
            .first { $0.contains(#"name: "Understudy""#) }

        let block = try #require(
            understudy,
            "the manifest no longer declares a `.target(name: \"Understudy\")`"
        )

        #expect(
            !block.contains(#""LedgerKit""#),
            """
            Package.swift gives the Understudy target a LedgerKit dependency. \
            That compiles, and it breaks SPEC §10.1's rule silently — which is \
            exactly the case the build cannot catch and this test exists for.
            """
        )
    }

    /// Every `.target(…)` call in a manifest, delimited by **balanced
    /// parentheses**.
    ///
    /// ⚠️ Worth recording, because the two ways this went wrong before it went
    /// right are both instructive and both cost exactly one run:
    ///
    /// 1. Delimiting on "the next `.target(`" ran to end-of-file, because
    ///    `.testTarget(` does **not** contain the substring `.target(` — the
    ///    capital `T` breaks it. The block then swallowed `LedgerKitTests`,
    ///    whose dependencies name `"LedgerKit"` perfectly legitimately.
    /// 2. Searching backwards from `name: "Understudy"` found nothing, because
    ///    the *first* occurrence of that string is in the **products** section
    ///    (`.library(name: "Understudy", …)`), which precedes every `.target(`.
    ///
    /// Both failed *closed* — a false alarm somebody investigates — rather than
    /// passing a manifest that violated the rule. That is the property a crude
    /// parse has to have to be worth shipping, and it is why this is a scan over
    /// all target blocks rather than a clever search for one.
    private static func targetBlocks(in manifest: String) -> [String] {
        var blocks: [String] = []
        var search = manifest.startIndex

        while let call = manifest.range(of: #".target("#, range: search..<manifest.endIndex) {
            var depth = 1
            var index = call.upperBound
            while index < manifest.endIndex, depth > 0 {
                switch manifest[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth > 0 { index = manifest.index(after: index) }
            }
            blocks.append(String(manifest[call.upperBound..<index]))
            search = call.upperBound
        }

        return blocks
    }
}

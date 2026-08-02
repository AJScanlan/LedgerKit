import Foundation
import Testing
@testable import LedgerKit

// **The SDK's error surface, as a checked-in manifest compared against the
// installed interface** (M6 Phase 1.5).
//
// §8 claims `GenerationError` is a *total* normalization of Apple's taxonomy,
// and states that claim as a table so it can be checked. This is the mechanism
// that keeps the claim true across betas.
//
// The gap it exists to close was real and was found the slow way. Rev 6 read
// `LanguageModelError` and answered "what are the built-in error cases?"
// correctly — but §8 makes a claim one size larger, and *that* needs the answer
// to "what can be thrown at a driver?". Nobody asked the larger question, so four
// families went unaccounted for until M6 Phase 1 stumbled on two of them by
// following a deprecation note. This suite asks the larger question, mechanically,
// on every run.
//
// It is the same move ADR-001 D-3 made for the wire format: a rule nobody can
// quietly break beats a rule somebody read once. **A beta that adds an error type
// now fails a test** rather than waiting to be discovered by luck.
//
// What it cannot do, stated so the limit is not mistaken for coverage: it sees
// *shape*, never *behaviour*. Whether `concurrentRequests` is thrown or trapped,
// whether real providers revise segments — those are §14's residues, they are
// empirical, and no amount of reading closes them.

// MARK: - The manifest

/// One error type Apple ships, and what LedgerKit does about it.
struct AppleErrorType: Equatable, Comparable, CustomStringConvertible {

    /// What LedgerKit does with this type — the half a bare name list would miss.
    enum Disposition: Equatable {
        /// Normalized in `Session/NormalizeAppleErrors.swift`.
        case normalized
        /// Cannot reach the driver, with the reason. **Recorded rather than
        /// omitted**: "we decided this one cannot arrive" and "we never noticed
        /// this one" look identical in a list that only holds what it handles,
        /// and telling them apart is the entire point of this file.
        case unreachable(why: String)
    }

    var type: String
    var cases: [String]
    var disposition: Disposition

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.type < rhs.type }

    /// Compared on name and cases only — the manifest's *disposition* is
    /// LedgerKit's opinion, and the SDK has none.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.type == rhs.type && lhs.cases == rhs.cases
    }

    var description: String {
        cases.isEmpty ? type : "\(type)(\(cases.joined(separator: ", ")))"
    }
}

/// **Every public `Error`-conforming type in `FoundationModels`, as of Xcode 27
/// Beta 4** — nine of them, five reachable by a driver and four not.
///
/// Update this when a beta changes the surface, and update it *deliberately*:
/// a new entry means §8 has a decision to make, and adding one here without
/// deciding is how the gap this file exists to catch would come back.
let appleErrorSurface: [AppleErrorType] = [
    // ── Reachable: the driver normalizes these ────────────────────────────────
    .init(
        type: "LanguageModelError",
        cases: ["contextSizeExceeded", "rateLimited", "guardrailViolation", "refusal",
                "unsupportedCapability", "unsupportedTranscriptContent",
                "unsupportedGenerationGuide", "unsupportedLanguageOrLocale", "timeout"],
        disposition: .normalized
    ),
    .init(
        type: "LanguageModelSession.Error",
        cases: ["concurrentRequests", "transcriptMutationWhileResponding"],
        disposition: .normalized
    ),
    .init(
        type: "LanguageModelSession.GenerationError",
        cases: ["exceededContextWindowSize", "assetsUnavailable", "guardrailViolation",
                "unsupportedGuide", "unsupportedLanguageOrLocale", "decodingFailure",
                "rateLimited", "concurrentRequests", "refusal"],
        disposition: .normalized
    ),
    .init(
        type: "LanguageModelSession.ToolCallError",
        cases: [],
        disposition: .normalized
    ),
    .init(
        type: "SystemLanguageModel.Error",
        cases: ["assetsUnavailable"],
        disposition: .normalized
    ),
    .init(
        type: "PrivateCloudComputeLanguageModel.Error",
        cases: ["networkFailure", "quotaLimitReached", "serviceUnavailable"],
        disposition: .normalized
    ),
    // ⚠️ **Moved out of the unreachable group at rev 9, by observation.** This
    // was dispositioned `.unreachable` on the reasoning that the parse belongs
    // to guided generation, which v0.1 never requests (N8). That reasoning is
    // *false*: a model returning zero tokens fails the same parse on the plain-
    // `String` path, measured on real hardware at M6. Normalizes by §8 rule 4 to
    // `providerFailure(code: "emptyResponse")`.
    //
    // Worth keeping as a caution about what this manifest can and cannot catch:
    // the surface tripwire pins the SDK's **shape**, and the shape was right all
    // along — `ParsingError` exists, spelled exactly as recorded. What was wrong
    // was the *prose* justifying a disposition, and no test can check prose. A
    // disposition of `.unreachable` is a claim about the world, not about the
    // SDK, and only running code can falsify one.
    .init(
        type: "GeneratedContent.ParsingError",
        cases: [],
        disposition: .normalized
    ),

    // ── Out of the driver's path, each for a stated reason ────────────────────
    .init(
        type: "SystemLanguageModel.Adapter.AssetError",
        cases: ["invalidAsset", "invalidAdapterName", "compatibleAdapterNotFound"],
        disposition: .unreachable(
            why: """
            Thrown while an app loads an adapter, which happens when it constructs \
            the model it hands to a driver — before any generation exists. §8's \
            floor catches it loudly if that assumption is ever wrong.
            """
        )
    ),
    .init(
        type: "GenerationSchema.SchemaError",
        cases: ["duplicateType", "duplicateProperty", "emptyTypeChoices", "undefinedReferences"],
        disposition: .unreachable(
            why: """
            Raised building a `GenerationSchema`, which is app-side and \
            guided-generation only (N8). LedgerKit never constructs one.
            """
        )
    ),
]

// MARK: - The surfaces Phase 2 consumes

/// A declaration whose *shape* LedgerKit reads, pinned so a beta that changes it
/// fails here rather than at the next verification evening — or, worse, in the
/// behaviour of a driver nobody re-read.
///
/// These are chosen, not exhaustive. Each is a surface a §7 obligation is
/// written against, so a change to it changes something LedgerKit promises.
struct PinnedDeclaration: Equatable {
    var type: String
    var members: [String]
}

/// The declarations §7 is written against.
///
/// `Transcript.Entry` earns its place by history: the M3 audit recorded that it
/// had gained a seventh case, and it had not — `Transcript.Segment` was what
/// grew. That misreading survived into a fact table and was caught while drafting
/// rev 7. Pinning both makes the same mistake a test failure instead of a
/// document someone has to re-check.
///
/// The channel's response actions matter for the opposite reason: they are what a
/// *provider* may send, and `replaceTextSegment` appearing there is precisely
/// what withdrew §7.3's prefix guarantee at rev 7. A new action is the same class
/// of event, so it should not arrive quietly.
let consumedSurface: [PinnedDeclaration] = [
    .init(
        type: "Transcript.Entry",
        members: ["instructions", "prompt", "toolCalls", "toolOutput", "response", "reasoning"]
    ),
    .init(
        type: "Transcript.Segment",
        members: ["text", "structure", "attachment", "custom"]
    ),
    .init(
        type: "LanguageModelExecutorGenerationChannel.Response.Action",
        members: ["addAttachmentSegment", "appendText", "removeAttachmentSegment",
                  "replaceTextSegment", "updateCustomSegment", "updateMetadata", "updateUsage"]
    ),
]

/// Every `case` and `public static func` the interface declares for `type`,
/// across its declaration *and* its extensions — which is one type in the
/// interface's eyes and several blocks in its text.
func members(ofType type: String, in interface: String) -> [String] {
    let lines = interface.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let blockOpener = /^(?<indent>\s*)(?:public )?(?:enum|struct|extension) (?<name>[\w:.]+)/
    let member = /^\s*(?:case|public static func) (?<name>\w+)/

    var found: Set<String> = []
    var index = 0
    while index < lines.count {
        defer { index += 1 }
        guard let opener = try? blockOpener.firstMatch(in: lines[index]),
              lines[index].hasSuffix("{")
        else { continue }

        // The interface spells nesting two ways: an `extension` names the type
        // in full, while a nested declaration is qualified by the extension
        // above it.
        var qualified = String(opener.output.name).replacingOccurrences(of: "FoundationModels::", with: "")
        if !opener.output.indent.isEmpty {
            for previous in lines[..<index].reversed() {
                if let outer = try? /^extension (?<name>[\w:.]+)\s*\{/.firstMatch(in: previous) {
                    qualified = String(outer.output.name)
                        .replacingOccurrences(of: "FoundationModels::", with: "") + "." + qualified
                    break
                }
            }
        }
        guard qualified == type else { continue }

        for following in lines[(index + 1)...] {
            if let match = try? member.firstMatch(in: following) {
                found.insert(String(match.output.name))
            } else if following == opener.output.indent + "}" {
                break
            }
        }
    }
    return found.sorted()
}

// MARK: - The interface

/// The installed macOS SDK's `FoundationModels.swiftinterface`, if this run can
/// reach it.
///
/// Located through `xcrun` rather than hardcoded, so an Xcode update does not
/// silently disable the check by moving the path — the failure mode a literal
/// `/Applications/Xcode-27.0.0-Beta.4.app/…` would have.
///
/// **`#if os(macOS)` because `Process` does not exist on iOS**, and this file
/// compiles for the simulator too. Caught by the simulator run rather than by
/// review, which is a use for that tier nobody planned: it is not only where
/// 27-gated tests execute, it is the only place host-only API in *test* code
/// fails to build.
private let interfaceSource: String? = {
    #if !os(macOS)
    // The interface is a macOS-toolchain artifact; this check belongs to the
    // host, and the suite reports skipped anywhere else.
    return nil
    #else
    let xcrun = Process()
    xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    xcrun.arguments = ["--show-sdk-path", "--sdk", "macosx"]
    let pipe = Pipe()
    xcrun.standardOutput = pipe
    xcrun.standardError = FileHandle.nullDevice

    guard (try? xcrun.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    xcrun.waitUntilExit()
    guard xcrun.terminationStatus == 0,
          let sdk = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !sdk.isEmpty
    else { return nil }

    let interface = URL(fileURLWithPath: sdk)
        .appendingPathComponent(
            "System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules"
                + "/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface"
        )
    return try? String(contentsOf: interface, encoding: .utf8)
    #endif
}()

/// The installed macOS SDK's build string, e.g. `26A5388f`.
private let sdkBuildVersion: String? = {
    #if !os(macOS)
    return nil
    #else
    let xcrun = Process()
    xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    xcrun.arguments = ["--show-sdk-build-version", "--sdk", "macosx"]
    let pipe = Pipe()
    xcrun.standardOutput = pipe
    xcrun.standardError = FileHandle.nullDevice

    guard (try? xcrun.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    xcrun.waitUntilExit()
    guard xcrun.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    #endif
}()

/// Parses the error surface out of a `.swiftinterface`.
///
/// A deliberately small parser over a generated, regularly-formatted file: it
/// looks for public `enum`/`struct` declarations whose inheritance clause names
/// an error protocol, qualifies them by the nearest enclosing `extension`, and
/// collects their cases. It is not a Swift parser and does not need to be — the
/// vacuity guard in the test is what stops a format change from turning this
/// into a check that silently passes.
func parseErrorSurface(_ interface: String) -> [AppleErrorType] {
    let lines = interface.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let declaration = /^(?<indent>\s*)public (enum|struct) (?<name>\w+)\s*:\s*(?<inherits>.*?)\s*\{/
    let extensionLine = /^extension (?<name>[\w:.]+)\s*\{/
    let caseLine = /^\s*case (?<name>\w+)/

    var found: [AppleErrorType] = []
    for (index, line) in lines.enumerated() {
        guard let match = try? declaration.wholeMatch(in: line) ?? declaration.firstMatch(in: line),
              match.output.inherits.contains("Error")
        else { continue }

        // Qualify by the nearest enclosing extension, which is how the interface
        // spells nesting.
        var qualified = String(match.output.name)
        if !match.output.indent.isEmpty {
            for previous in lines[..<index].reversed() {
                if let outer = try? extensionLine.firstMatch(in: previous) {
                    qualified = String(outer.output.name).replacingOccurrences(of: "FoundationModels::", with: "")
                        + "." + qualified
                    break
                }
            }
        }

        var cases: [String] = []
        for following in lines[(index + 1)...] {
            if let caseMatch = try? caseLine.firstMatch(in: following) {
                cases.append(String(caseMatch.output.name))
            } else if following == match.output.indent + "}" {
                break
            }
        }
        found.append(AppleErrorType(type: qualified, cases: cases, disposition: .normalized))
    }
    return found.sorted()
}

// MARK: - The check

/// Skipped where the SDK interface is unreachable — on the simulator, or on a
/// machine without Xcode — rather than passing vacuously there.
@Suite("Session — Apple's error surface", .enabled(if: interfaceSource != nil))
struct AppleErrorSurfaceTests {

    /// **The check the §8 gap would have failed.** A beta that adds an error
    /// type, adds a case, or renames one fails here, naming exactly what moved.
    @Test("the SDK's error surface matches the manifest")
    func surfaceMatchesManifest() throws {
        let interface = try #require(interfaceSource)
        let actual = parseErrorSurface(interface)
        let expected = appleErrorSurface.sorted()

        let appeared = actual.filter { entry in !expected.contains(entry) }
        let vanished = expected.filter { entry in !actual.contains(entry) }

        #expect(
            appeared.isEmpty,
            """
            Foundation Models grew error surface this manifest does not know about:
            \(appeared.map(\.description).joined(separator: "\n"))

            Each one needs a §8 decision — normalize it, or record why it cannot \
            reach the driver — and then an entry in `appleErrorSurface`.
            """
        )
        #expect(
            vanished.isEmpty,
            """
            The manifest expects error surface the SDK no longer has:
            \(vanished.map(\.description).joined(separator: "\n"))
            """
        )
    }

    /// The vacuity guard. A parser that silently stopped matching — a format
    /// change, a moved file — would report "no differences" forever, which is
    /// the failure mode this whole file exists to prevent one level up.
    @Test("the parser actually found the surface it claims to check")
    func parserIsNotVacuous() throws {
        let actual = parseErrorSurface(try #require(interfaceSource))

        #expect(actual.count >= 9, "found \(actual.count) error types, which cannot be right")
        #expect(
            actual.contains { $0.type == "LanguageModelError" && $0.cases.count == 9 },
            "the parser did not find `LanguageModelError`'s nine cases"
        )
    }

    /// Every type the manifest calls reachable is one `normalize` handles, and
    /// every type it calls unreachable carries a *reason*. Cheap, and it is what
    /// keeps `.unreachable` from becoming a shrug.
    @Test("every manifest entry states a disposition worth reading")
    func dispositionsAreStated() {
        for entry in appleErrorSurface {
            if case .unreachable(let why) = entry.disposition {
                #expect(why.count > 40, "\(entry.type)'s exemption needs a reason, not a label")
            }
        }
    }

    /// The other half of the sweep: the declarations §7's obligations are
    /// written against.
    @Test("the declarations §7 consumes have not changed shape", arguments: consumedSurface)
    func consumedDeclarationsAreStable(_ pinned: PinnedDeclaration) throws {
        let actual = members(ofType: pinned.type, in: try #require(interfaceSource))

        #expect(!actual.isEmpty, "found no members for \(pinned.type) — the parser, not Apple, is probably wrong")
        #expect(
            actual == pinned.members.sorted(),
            """
            \(pinned.type) changed shape.
              expected: \(pinned.members.sorted())
              found:    \(actual)
            A member appearing here is a §7 decision, not a manifest edit: it is \
            how `replaceTextSegment` withdrew §7.3's prefix guarantee at rev 7.
            """
        )
    }

    /// **The forcing function.** The ROADMAP promises "one verification evening
    /// per beta", which is a discipline — and a discipline is a thing that gets
    /// skipped in a busy week. Pinning the SDK build makes the *toolchain moving*
    /// the failing condition, so the evening is scheduled by CI rather than by
    /// memory.
    ///
    /// Fixing it is one line **after** re-running the checks above, which is the
    /// whole point: the update is trivial, the re-verification is not, and the
    /// two are deliberately bundled so the second cannot be skipped while the
    /// first is done.
    @Test("the SDK this manifest was verified against is the SDK installed")
    func sdkBuildIsPinned() throws {
        let verified = "26A5388f"
        let installed = try #require(sdkBuildVersion)

        #expect(
            installed == verified,
            """
            The macOS SDK moved: \(verified) → \(installed).
            Re-run M6-PLAN §2a's checks against the new interface, update anything \
            that moved, then set `verified` to \(installed). A green suite after a \
            toolchain bump means nothing until someone has looked.
            """
        )
    }
}

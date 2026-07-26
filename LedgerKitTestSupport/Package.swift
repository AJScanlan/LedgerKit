// swift-tools-version: 6.3

import PackageDescription

// **This package deliberately does not depend on LedgerKit.** An earlier note
// here assumed the opposite; it was wrong twice over. SPM forbids dependency
// cycles, and the direction actually needed is the reverse — LedgerKit's *test*
// target imports `ScriptedLanguageModel` for its store and driver suites (M5,
// M6), which is only possible if nothing here points back. It also keeps the
// product honest: a deterministic Foundation Models double is useful to any FM
// app, and one that drags in a conversation-ledger library is not.
//
// The floor stays at 26 even though `ScriptedLanguageModel` needs 27. The
// script vocabulary and the playback engine carry no Foundation Models types at
// all, so they run anywhere; only the conformance is `@available(macOS 27)`.
// That split is what preserves "verifiable on any Mac" while still conforming
// to Apple's real protocols rather than an imitation of them.
let package = Package(
    name: "LedgerKitTestSupport",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "LedgerKitTestSupport",
            targets: ["LedgerKitTestSupport"]
        ),
    ],
    targets: [
        .target(
            name: "LedgerKitTestSupport"
        ),
        .testTarget(
            name: "LedgerKitTestSupportTests",
            dependencies: ["LedgerKitTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

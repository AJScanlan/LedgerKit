// swift-tools-version: 6.3

import PackageDescription

// Platform floor is 26, not the 27 the spec targets (SPEC header): the core is
// pure Swift and must stay verifiable on any Mac with no Apple Intelligence
// eligibility.
//
// **The floor does not move at M6, and an earlier note here saying it would was
// wrong** (M6-PLAN D31). `Session/` is availability-gated instead — every
// declaration `@available(macOS 27, iOS 27, …)`, byte-for-byte the pattern
// `Understudy` already ships for `ScriptedLanguageModel`. A 27 floor would make
// the *entire* test binary unlaunchable on a macOS 26 host — all of it, not just
// the driver's — and force every consumer to 27 for a library whose core is
// deliberately 26-clean. Gating costs one attribute per declaration; bumping
// costs the suite.
//
// The 27-only tests still execute here, on the iOS 27 simulator runtime, which is
// what keeps them honest rather than dormant (M6-PLAN Phase 0, substrate spike):
//
//     xcodebuild test -workspace LedgerKit.xcworkspace -scheme LedgerKit \
//       -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'
//
// The deployment target stays 26 there, so the same sources serve both.
let package = Package(
    name: "LedgerKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "LedgerKit",
            targets: ["LedgerKit"]
        ),
    ],
    // GRDB is the only external dependency, chosen at ADR-003 and wired at M4.
    // `from:` rather than `.exact(_:)` deliberately: an exact pin in a *library*
    // manifest forces a resolution conflict on any consumer who also depends on
    // GRDB, which is a cost paid by other people to buy us nothing —
    // `Package.resolved` already pins the exact version for our own CI. The
    // supply-chain exposure this accepts is priced in ADR-003 ("Costs accepted"),
    // and the seam is what keeps the raw-sqlite3 fallback (§12 cut line) cheap.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
        // **Test target only — the library must never depend on this** (M6-PLAN
        // D37). `Understudy` deliberately does not depend on LedgerKit, and this
        // is the reverse direction: LedgerKit's driver suites need a
        // deterministic `LanguageModel` to run a real `LanguageModelSession`
        // against, and writing a second one here is the "internal imitation" M3's
        // D11 retired.
        //
        // ⚠️ **A path dependency is local-only**, and that is priced rather than
        // overlooked: it works in this repo and the workspace and would break any
        // consumer resolving LedgerKit remotely — survivable only because the
        // repo root has no `Package.swift`, so neither package is remotely
        // consumable today anyway. M9 must dissolve this into whatever 0.1.0
        // ships (a root manifest exposing both products, or split repos); the
        // path dep is the forcing function.
        .package(path: "../Understudy"),
    ],
    targets: [
        .target(
            name: "LedgerKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // `Corpus/` holds the on-disk fixture corpus (SPEC §10.2): logs as wire
        // JSON plus their expected reduced state. Declared as a resource so the
        // runner reads it from `Bundle.module`; record mode writes back to the
        // source tree via `#filePath`, which is a dev-only path.
        //
        // `Registry/` holds `tags.json`, the discriminator registry (ADR-001 D-3,
        // M4 Phase 4). Separate from the corpus on purpose: the corpus is a set of
        // example logs, this is the *inventory* of every tag and field key those
        // logs may legally contain. Hand-edited, never recorded — there is no
        // record-mode branch that can rewrite it, which is the same reasoning that
        // keeps `frozen/` unwritable.
        .testTarget(
            name: "LedgerKitTests",
            dependencies: [
                "LedgerKit",
                .product(name: "Understudy", package: "Understudy"),
            ],
            resources: [.copy("Corpus"), .copy("Registry")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

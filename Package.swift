// swift-tools-version: 6.3

import PackageDescription

// **One package, two products, one repo** (M9-PLAN D61).
//
// Through M8 this repo held two *independent* packages in subdirectories, with
// LedgerKit's test target reaching `Understudy` through `.package(path:
// "../Understudy")`. That arrangement worked here and nowhere else: a path
// dependency cannot be resolved by a remote consumer, and — more decisively —
// there was **no `Package.swift` at the repo root at all**, so
// `.package(url: "…/LedgerKit.git")` did not resolve to a degraded package, it
// resolved to nothing. A `0.1.0` tagged on that layout would have been a tag
// nobody could depend on, which is a DoD-5 failure rather than an untidiness.
//
// **Why one package rather than two repos.** They move together and are pre-1.0;
// split repos would double the release ceremony and introduce a
// version-compatibility question between two things that are always tagged on
// the same day. `Understudy`'s only consumer today is LedgerKit's test target.
// A monorepo → split move stays available and is mechanical; the reverse is a
// dependency-graph change.
//
// ⚠️ **What this does *not* buy, stated because the draft of D61 overstated it.**
// A consumer who wants only the test double does not *link* LedgerKit — no
// LedgerKit code, no GRDB — but they must still **name** it:
//
//     .package(url: "https://github.com/AJScanlan/LedgerKit.git", from: "0.1.0"),
//     .product(name: "Understudy", package: "LedgerKit")
//
// That is a real cost to §10.1's "gateway drug" positioning and it is accepted,
// not hidden. The README says "you don't link LedgerKit", never "you don't
// depend on it".
let package = Package(
    name: "LedgerKit",

    // Floor stays **26** for both targets, and the rule outlived its original
    // reason (M6-PLAN D31). It first existed because the build host was on 26;
    // the host reached 27 and the floor did not move, because it now stands on
    // portability: the floor is a promise to consumers on 26, CI runners may not
    // be on 27, and the iOS tier still deploys to 26. `Session/` and
    // `ScriptedLanguageModel` are availability-gated instead, which costs one
    // attribute per declaration where a floor bump would cost the whole suite —
    // a 27 floor makes the entire test binary unlaunchable on a 26 host, driver
    // tests and pure-reducer tests alike.
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],

    products: [
        .library(
            name: "LedgerKit",
            targets: ["LedgerKit"]
        ),
        // Shipped as its own product deliberately (SPEC §10.1): a deterministic
        // Foundation Models double is useful to any FM app, and one that drags
        // in a conversation-ledger library is not.
        .library(
            name: "Understudy",
            targets: ["Understudy"]
        ),
    ],

    // GRDB is the only external dependency, chosen at ADR-003 and wired at M4.
    // `from:` rather than `.exact(_:)` deliberately: an exact pin in a *library*
    // manifest forces a resolution conflict on any consumer who also depends on
    // GRDB, which is a cost paid by other people to buy us nothing —
    // `Package.resolved` already pins the exact version for our own CI. The
    // supply-chain exposure this accepts is priced in ADR-003 ("Costs
    // accepted"), and the seam is what keeps the raw-sqlite3 fallback (§12 cut
    // line) cheap.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],

    targets: [
        .target(
            name: "LedgerKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),

        // ⚠️ **This target has no dependencies, and that is the rule rather than
        // a coincidence.** `Understudy` must never depend on LedgerKit: SPM
        // forbids dependency cycles and the direction actually needed is the
        // reverse — LedgerKit's *test* target imports `ScriptedLanguageModel`
        // for its store and driver suites (M5, M6), which is only possible if
        // nothing here points back.
        //
        // Consolidating the two packages made this **stronger, not weaker**: as
        // a sibling target with an empty dependency list, an `import LedgerKit`
        // inside `Sources/Understudy` now fails to *resolve*, where previously
        // it was prevented only by the two packages being separate. The build
        // catches what used to be convention. `UnderstudyBoundaryTests` covers
        // the one case the build cannot — somebody adding the dependency to
        // this list, which would compile fine and break the rule silently.
        .target(
            name: "Understudy"
        ),

        // `Corpus/` holds the on-disk fixture corpus (SPEC §10.2): logs as wire
        // JSON plus their expected reduced state. Declared as a resource so the
        // runner reads it from `Bundle.module`; record mode writes back to the
        // source tree via `#filePath`, which is a dev-only path.
        //
        // `Registry/` holds `tags.json`, the discriminator registry (ADR-001
        // D-3, M4 Phase 4). Separate from the corpus on purpose: the corpus is a
        // set of example logs, this is the *inventory* of every tag and field
        // key those logs may legally contain. Hand-edited, never recorded —
        // there is no record-mode branch that can rewrite it, which is the same
        // reasoning that keeps `frozen/` unwritable.
        .testTarget(
            name: "LedgerKitTests",
            dependencies: [
                "LedgerKit",
                "Understudy",
            ],
            resources: [.copy("Corpus"), .copy("Registry")]
        ),

        .testTarget(
            name: "UnderstudyTests",
            dependencies: ["Understudy"]
        ),
    ],

    swiftLanguageModes: [.v6]
)

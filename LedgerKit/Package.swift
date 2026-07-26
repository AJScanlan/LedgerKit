// swift-tools-version: 6.3

import PackageDescription

// Platform floor is 26, not the 27 the spec targets (SPEC header): M1–M5 are pure
// Swift and must stay verifiable on any Mac with no Apple Intelligence
// eligibility. Bump to 27 at M6, when `Session/` first touches Foundation Models.
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
        .testTarget(
            name: "LedgerKitTests",
            dependencies: ["LedgerKit"],
            resources: [.copy("Corpus")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

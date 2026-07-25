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
    targets: [
        .target(
            name: "LedgerKit"
        ),
        .testTarget(
            name: "LedgerKitTests",
            dependencies: ["LedgerKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

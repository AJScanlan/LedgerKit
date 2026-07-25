// swift-tools-version: 6.3

import PackageDescription

// Platforms track LedgerKit's floor: M3 makes this package depend on it, and a
// lower floor here would fail to resolve. Bump both together at M6.
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

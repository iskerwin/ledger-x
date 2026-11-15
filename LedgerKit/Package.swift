// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LedgerKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LedgerKit", targets: ["LedgerKit"])],
    targets: [
        // Sendable and actor checks where code opts into concurrency, as the apps' SWIFT_STRICT_CONCURRENCY: targeted
        .target(name: "LedgerKit", swiftSettings: [.unsafeFlags(["-strict-concurrency=targeted"])]),
        .testTarget(name: "LedgerKitTests", dependencies: ["LedgerKit"], resources: [.copy("Fixtures")]),
    ]
)

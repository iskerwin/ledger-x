// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LedgerKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LedgerKit", targets: ["LedgerKit"])],
    targets: [
        .target(name: "LedgerKit"),
        .testTarget(name: "LedgerKitTests", dependencies: ["LedgerKit"], resources: [.copy("Fixtures")]),
    ]
)

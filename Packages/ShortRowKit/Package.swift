// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShortRowKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ShortRowKit", targets: ["ShortRowKit"])],
    targets: [
        .target(name: "ShortRowKit", resources: [.process("Resources")]),
        .testTarget(name: "ShortRowKitTests", dependencies: ["ShortRowKit"])
    ]
)

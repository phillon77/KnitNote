// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KnitNoteCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)],
    products: [.library(name: "KnitNoteCore", targets: ["KnitNoteCore"])],
    targets: [
        .target(name: "KnitNoteCore", resources: [.process("Resources")]),
        .testTarget(name: "KnitNoteCoreTests", dependencies: ["KnitNoteCore"])
    ]
)

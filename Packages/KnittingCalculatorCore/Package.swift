// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KnittingCalculatorCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
    ],
    products: [
        .library(
            name: "KnittingCalculatorCore",
            targets: ["KnittingCalculatorCore"]
        ),
    ],
    targets: [
        .target(name: "KnittingCalculatorCore", resources: [.process("Resources")]),
        .testTarget(
            name: "KnittingCalculatorCoreTests",
            dependencies: ["KnittingCalculatorCore"]
        ),
    ]
)

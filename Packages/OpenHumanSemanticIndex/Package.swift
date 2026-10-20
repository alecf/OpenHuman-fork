// swift-tools-version: 6.4
import PackageDescription

let ai: Target.Dependency = .product(name: "OpenHumanAI", package: "OpenHumanAI")

let package = Package(
    name: "OpenHumanSemanticIndex",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanSemanticIndex", targets: ["OpenHumanSemanticIndex"]),
        .library(name: "OpenHumanSemanticIndexTesting", targets: ["OpenHumanSemanticIndexTesting"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(path: "../OpenHumanAI"),
    ],
    targets: [
        .target(name: "OpenHumanSemanticIndex", dependencies: ["OpenHumanCore", ai]),
        .target(name: "OpenHumanSemanticIndexTesting", dependencies: ["OpenHumanSemanticIndex", "OpenHumanCore", ai]),
        .testTarget(name: "OpenHumanSemanticIndexTests",
                    dependencies: ["OpenHumanSemanticIndex", "OpenHumanSemanticIndexTesting", "OpenHumanCore", ai,
                                   .product(name: "OpenHumanAITesting", package: "OpenHumanAI")]),
    ],
    swiftLanguageModes: [.v6]
)

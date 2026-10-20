// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanAI",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanAI", targets: ["OpenHumanAI"]),
        .library(name: "OpenHumanAITesting", targets: ["OpenHumanAITesting"]),
        .library(name: "OpenHumanAIAgentCLI", targets: ["OpenHumanAIAgentCLI"]),
        .library(name: "OpenHumanAIModelStore", targets: ["OpenHumanAIModelStore"]),
        .library(name: "OpenHumanAIApple", targets: ["OpenHumanAIApple"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
    ],
    targets: [
        .target(name: "OpenHumanAI", resources: [.copy("Prompts")]),
        .target(name: "OpenHumanAITesting", dependencies: ["OpenHumanAI"]),
        .target(name: "OpenHumanAIAgentCLI", dependencies: ["OpenHumanAI"]),
        .target(name: "OpenHumanAIModelStore", dependencies: ["OpenHumanAI"]),
        .target(name: "OpenHumanAIApple", dependencies: [
            "OpenHumanAI", .target(name: "OpenHumanAIAgentCLI", condition: .when(platforms: [.macOS])), "OpenHumanAIModelStore",
        ]),
        .testTarget(name: "OpenHumanAITests", dependencies: ["OpenHumanAI", "OpenHumanAITesting",
                                                            .product(name: "OpenHumanCore", package: "OpenHumanCore")]),
        .testTarget(
            name: "OpenHumanAIAgentCLITests",
            dependencies: ["OpenHumanAIAgentCLI", "OpenHumanAITesting"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "OpenHumanAIModelStoreTests", dependencies: ["OpenHumanAIModelStore", "OpenHumanAITesting"]),
        .testTarget(name: "OpenHumanAIAppleTests", dependencies: ["OpenHumanAIApple", "OpenHumanAIModelStore", "OpenHumanAITesting"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AIEval",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "ai-eval", targets: ["ai-eval"]),
        .executable(name: "ai-render", targets: ["ai-render"]),
    ],
    dependencies: [
        .package(path: "../../Packages/OpenHumanAI")
    ],
    targets: [
        .target(
            name: "AIEvalKit",
            dependencies: [
                .product(name: "OpenHumanAI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
            ],
            resources: [.copy("Resources/corpus.jsonl")]),
        .executableTarget(
            name: "ai-eval",
            dependencies: [
                "AIEvalKit",
                .product(name: "OpenHumanAI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAIApple", package: "OpenHumanAI"),
                .product(name: "OpenHumanAIAgentCLI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
            ]),
        .executableTarget(
            name: "ai-render",
            dependencies: [
                .product(name: "OpenHumanAI", package: "OpenHumanAI")
            ]),
        .testTarget(
            name: "AIEvalTests",
            dependencies: [
                "AIEvalKit",
                .product(name: "OpenHumanAI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)

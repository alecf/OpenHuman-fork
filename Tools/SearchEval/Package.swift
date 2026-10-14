// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SearchEval",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "search-eval", targets: ["search-eval"]),
    ],
    dependencies: [
        .package(path: "../../Packages/OpenHumanCore"),
        .package(path: "../../Packages/OpenHumanStore"),
        .package(path: "../../Packages/OpenHumanAI"),
    ],
    targets: [
        .target(
            name: "SearchEvalKit",
            dependencies: [
                .product(name: "OpenHumanCore", package: "OpenHumanCore"),
                .product(name: "OpenHumanStore", package: "OpenHumanStore"),
                .product(name: "OpenHumanAI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
            ],
            resources: [.copy("Resources/retrieval-corpus.jsonl"), .copy("Resources/queries.jsonl")]),
        .executableTarget(
            name: "search-eval",
            dependencies: [
                "SearchEvalKit",
                .product(name: "OpenHumanCore", package: "OpenHumanCore"),
                .product(name: "OpenHumanStore", package: "OpenHumanStore"),
                .product(name: "OpenHumanAI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAIApple", package: "OpenHumanAI"),
                .product(name: "OpenHumanAIModelStore", package: "OpenHumanAI"),
                .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
            ]),
        .testTarget(
            name: "SearchEvalTests",
            dependencies: [
                "SearchEvalKit",
                .product(name: "OpenHumanCore", package: "OpenHumanCore"),
                .product(name: "OpenHumanStore", package: "OpenHumanStore"),
                .product(name: "OpenHumanAI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)

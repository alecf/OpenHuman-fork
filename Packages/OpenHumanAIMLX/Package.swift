// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanAIMLX",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanAIMLX", targets: ["OpenHumanAIMLX"]),
        .library(name: "OpenHumanAIMLXRuntime", targets: ["OpenHumanAIMLXRuntime"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanAI"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    ],
    targets: [
        .target(
            name: "OpenHumanAIMLX",
            dependencies: [
                .product(name: "OpenHumanAI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAIModelStore", package: "OpenHumanAI"),
            ]),
        .target(
            name: "OpenHumanAIMLXRuntime",
            dependencies: [
                "OpenHumanAIMLX",
                .product(name: "OpenHumanAI", package: "OpenHumanAI"),
                .product(name: "OpenHumanAIModelStore", package: "OpenHumanAI"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]),
        .testTarget(
            name: "OpenHumanAIMLXTests",
            dependencies: [
                "OpenHumanAIMLX",
                .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)

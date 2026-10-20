// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanCLI",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "openhuman", targets: ["openhuman"]),
        .library(name: "OpenHumanCLIKit", targets: ["OpenHumanCLIKit"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(path: "../OpenHumanLinks"),
        .package(path: "../OpenHumanStore"),
        .package(path: "../OpenHumanGmail"),
        .package(path: "../OpenHumanSync"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        .executableTarget(name: "openhuman", dependencies: ["OpenHumanCLIKit"]),
        .target(name: "OpenHumanCLIKit", dependencies: [
            "OpenHumanCore",
            .product(name: "OpenHumanLinks", package: "OpenHumanLinks"),
            .product(name: "OpenHumanStore", package: "OpenHumanStore"),
            .product(name: "OpenHumanGmail", package: "OpenHumanGmail"),
            .product(name: "OpenHumanMIME", package: "OpenHumanGmail"),
            .product(name: "OpenHumanSync", package: "OpenHumanSync"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "OpenHumanCLIKitTests", dependencies: [
            "OpenHumanCLIKit", "OpenHumanCore",
            .product(name: "OpenHumanLinks", package: "OpenHumanLinks"),
            .product(name: "OpenHumanStore", package: "OpenHumanStore"),
            .product(name: "OpenHumanStoreTesting", package: "OpenHumanStore"),
            .product(name: "OpenHumanSync", package: "OpenHumanSync"),
            .product(name: "OpenHumanGmail", package: "OpenHumanGmail"),
            .product(name: "OpenHumanGmailTesting", package: "OpenHumanGmail"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

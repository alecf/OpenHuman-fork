// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanSync",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanSync", targets: ["OpenHumanSync"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(path: "../OpenHumanStore"),
        .package(path: "../OpenHumanGmail"),
    ],
    targets: [
        .target(name: "OpenHumanSync", dependencies: [
            "OpenHumanCore",
            .product(name: "OpenHumanStore", package: "OpenHumanStore"),
            .product(name: "OpenHumanGmail", package: "OpenHumanGmail"),
            .product(name: "OpenHumanMIME", package: "OpenHumanGmail"),
        ]),
        .testTarget(name: "OpenHumanSyncTests", dependencies: [
            "OpenHumanSync", "OpenHumanCore",
            .product(name: "OpenHumanStore", package: "OpenHumanStore"),
            .product(name: "OpenHumanStoreTesting", package: "OpenHumanStore"),
            .product(name: "OpenHumanGmail", package: "OpenHumanGmail"),
            .product(name: "OpenHumanGmailTesting", package: "OpenHumanGmail"),
            .product(name: "OpenHumanMIME", package: "OpenHumanGmail"),
        ]),
        .testTarget(name: "OpenHumanSyncContractsTests", dependencies: [
            "OpenHumanSync", "OpenHumanCore",
            .product(name: "OpenHumanStore", package: "OpenHumanStore"),
            .product(name: "OpenHumanGmail", package: "OpenHumanGmail"),
            .product(name: "OpenHumanMIME", package: "OpenHumanGmail"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

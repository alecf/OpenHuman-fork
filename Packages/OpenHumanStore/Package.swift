// swift-tools-version: 6.4
import PackageDescription

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")

let package = Package(
    name: "OpenHumanStore",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanStore", targets: ["OpenHumanStore"]),
        .library(name: "OpenHumanStoreTesting", targets: ["OpenHumanStoreTesting"]),
        .executable(name: "ohstore-helper", targets: ["ohstore-helper"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "OpenHumanStore", dependencies: ["OpenHumanCore", grdb]),
        .target(name: "OpenHumanStoreTesting", dependencies: ["OpenHumanStore", "OpenHumanCore", grdb]),
        .executableTarget(name: "ohstore-helper", dependencies: ["OpenHumanStore", "OpenHumanCore", grdb]),
        .testTarget(name: "OpenHumanStoreTests",
                    dependencies: ["OpenHumanStore", "OpenHumanStoreTesting", "OpenHumanCore", grdb]),
        .testTarget(name: "OpenHumanStorePerfTests",
                    dependencies: ["OpenHumanStore", "OpenHumanStoreTesting", "OpenHumanCore", grdb]),
        .testTarget(name: "OpenHumanStoreContractsTests", dependencies: ["OpenHumanStore", "OpenHumanCore"]),
    ],
    swiftLanguageModes: [.v6]
)

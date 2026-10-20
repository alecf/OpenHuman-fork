// swift-tools-version: 6.4
import PackageDescription

let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")

let package = Package(
    name: "OpenHumanCloudSync",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanCloudSync", targets: ["OpenHumanCloudSync"]),
        .library(name: "OpenHumanCloudSyncTesting", targets: ["OpenHumanCloudSyncTesting"]),
        .library(name: "OpenHumanCloudSyncApple", targets: ["OpenHumanCloudSyncApple"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(url: "https://github.com/apple/swift-crypto", exact: "3.15.1"),
    ],
    targets: [
        .target(name: "OpenHumanCloudSync", dependencies: ["OpenHumanCore", crypto]),
        .target(name: "OpenHumanCloudSyncTesting", dependencies: ["OpenHumanCloudSync", "OpenHumanCore"]),
        .target(name: "OpenHumanCloudSyncApple", dependencies: ["OpenHumanCloudSync"]),
        .testTarget(name: "OpenHumanCloudSyncTests",
                    dependencies: ["OpenHumanCloudSync", "OpenHumanCloudSyncApple", "OpenHumanCloudSyncTesting",
                                   "OpenHumanCore"]),
        .testTarget(name: "OpenHumanCloudSyncAppleTests", dependencies: ["OpenHumanCloudSyncApple", "OpenHumanCloudSync"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanCore",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanCore", targets: ["OpenHumanCore"]),
    ],
    targets: [
        .target(name: "OpenHumanCore"),
        .testTarget(name: "OpenHumanCoreTests", dependencies: ["OpenHumanCore"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanLinks",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanLinks", targets: ["OpenHumanLinks"]),
    ],
    targets: [
        .target(name: "OpenHumanLinks"),
        .testTarget(name: "OpenHumanLinksTests", dependencies: ["OpenHumanLinks"]),
    ],
    swiftLanguageModes: [.v6]
)

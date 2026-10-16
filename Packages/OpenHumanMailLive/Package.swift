// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanMailLive",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "MailSystem", targets: ["MailSystem"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(path: "../OpenHumanMailCore"),
    ],
    targets: [
        .target(name: "MailSystem", dependencies: [
            "OpenHumanCore", .product(name: "MailModel", package: "OpenHumanMailCore"),
        ]),
        .testTarget(name: "MailSystemTests", dependencies: [
            "MailSystem", .product(name: "MailModel", package: "OpenHumanMailCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

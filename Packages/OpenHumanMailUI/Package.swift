// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanMailUI",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "MailUI", targets: ["MailUI"]),
        .library(name: "MailUIMac", targets: ["MailUIMac"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanMailCore"),
        .package(path: "../OpenHumanAI"),
    ],
    targets: [
        .target(name: "MailUI", dependencies: [.product(name: "MailFeatures", package: "OpenHumanMailCore")]),
        .testTarget(name: "MailUITests", dependencies: [
            "MailUI", .product(name: "OpenHumanAI", package: "OpenHumanAI"),
            .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
        ]),
        .target(name: "MailUIMac", dependencies: ["MailUI"]),
        .testTarget(name: "MailUIMacTests", dependencies: [
            "MailUIMac", .product(name: "MailFakes", package: "OpenHumanMailCore"),
            .product(name: "MailRender", package: "OpenHumanMailCore"),
            .product(name: "OpenHumanAI", package: "OpenHumanAI"), .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

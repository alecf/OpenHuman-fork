// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanMailLive",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanMailLive", targets: ["OpenHumanMailLive"]),
        .library(name: "MailSystem", targets: ["MailSystem"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(path: "../OpenHumanStore"),
        .package(path: "../OpenHumanGmail"),
        .package(path: "../OpenHumanSync"),
        .package(path: "../OpenHumanMailCore"),
        .package(path: "../OpenHumanMailUI"),
        .package(path: "../OpenHumanAI"),
        .package(path: "../OpenHumanAIMLX"),
        .package(path: "../OpenHumanSemanticIndex"),
    ],
    targets: [
        .target(name: "OpenHumanMailLive", dependencies: [
            "MailSystem", "OpenHumanCore",
            .product(name: "MailModel", package: "OpenHumanMailCore"),
            .product(name: "MailFeatures", package: "OpenHumanMailCore"),
            .product(name: "MailFakes", package: "OpenHumanMailCore"),
            .product(name: "MailUI", package: "OpenHumanMailUI"),
            .product(name: "OpenHumanStore", package: "OpenHumanStore"),
            .product(name: "OpenHumanGmail", package: "OpenHumanGmail"),
            .product(name: "OpenHumanGmailApple", package: "OpenHumanGmail"),
            .product(name: "OpenHumanSync", package: "OpenHumanSync"),
            .product(name: "OpenHumanAI", package: "OpenHumanAI"),
            .product(name: "OpenHumanAIApple", package: "OpenHumanAI"),
            .product(name: "OpenHumanAIModelStore", package: "OpenHumanAI"),
            .product(name: "OpenHumanAITesting", package: "OpenHumanAI"),
            .product(name: "OpenHumanAIAgentCLI", package: "OpenHumanAI", condition: .when(platforms: [.macOS])),
            .product(name: "OpenHumanAIMLX", package: "OpenHumanAIMLX"),
            .product(name: "OpenHumanAIMLXRuntime", package: "OpenHumanAIMLX"),
            .product(name: "OpenHumanSemanticIndex", package: "OpenHumanSemanticIndex"),
        ]),
        .testTarget(name: "OpenHumanMailLiveTests", dependencies: [
            "OpenHumanMailLive", "OpenHumanCore",
            .product(name: "MailModel", package: "OpenHumanMailCore"),
            .product(name: "MailFeatures", package: "OpenHumanMailCore"),
            .product(name: "OpenHumanStore", package: "OpenHumanStore"),
            .product(name: "OpenHumanGmail", package: "OpenHumanGmail"),
            .product(name: "OpenHumanGmailTesting", package: "OpenHumanGmail"),
            .product(name: "OpenHumanAI", package: "OpenHumanAI"),
            .product(name: "OpenHumanAIMLX", package: "OpenHumanAIMLX"),
            .product(name: "OpenHumanSemanticIndex", package: "OpenHumanSemanticIndex"),
        ]),
        .target(name: "MailSystem", dependencies: [
            "OpenHumanCore", .product(name: "MailModel", package: "OpenHumanMailCore"),
        ]),
        .testTarget(name: "MailSystemTests", dependencies: [
            "MailSystem", .product(name: "MailModel", package: "OpenHumanMailCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

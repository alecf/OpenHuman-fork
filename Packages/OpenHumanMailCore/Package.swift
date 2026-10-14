// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanMailCore",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [
        .library(name: "MailModel", targets: ["MailModel"]),
        .library(name: "MailActions", targets: ["MailActions"]),
        .library(name: "MailFeatures", targets: ["MailFeatures"]),
        .library(name: "MailRender", targets: ["MailRender"]),
        .library(name: "MailTheme", targets: ["MailTheme"]),
        .library(name: "MailFakes", targets: ["MailFakes"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(path: "../OpenHumanLinks"),
        .package(path: "../OpenHumanAI"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.1"),
    ],
    targets: [
        .target(name: "MailModel", dependencies: ["OpenHumanCore"]),
        .testTarget(name: "MailModelTests", dependencies: ["MailModel"]),
        .target(name: "MailActions", dependencies: ["MailModel"]),
        .testTarget(name: "MailActionsTests", dependencies: ["MailActions"]),
        .target(name: "MailFeatures", dependencies: ["MailModel", "MailActions", "MailTheme", "MailRender", "MailFakes", "OpenHumanLinks",
                                                   .product(name: "OpenHumanAI", package: "OpenHumanAI")]),
        .testTarget(name: "MailFeaturesTests", dependencies: ["MailFeatures",
                                                             .product(name: "OpenHumanAITesting", package: "OpenHumanAI")]),
        .target(name: "MailRender", dependencies: ["MailModel", "MailTheme", "OpenHumanLinks", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .testTarget(name: "MailRenderTests", dependencies: ["MailRender", "MailFakes", "OpenHumanLinks", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "MailTheme", dependencies: [], exclude: ["Schema", "Themes"]),
        .testTarget(name: "MailThemeTests", dependencies: ["MailTheme"], exclude: ["Fixtures"]),
        .target(name: "MailFakes", dependencies: ["MailModel"]),
        .testTarget(name: "MailFakesTests", dependencies: ["MailFakes", "MailRender"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenHumanGmail",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "OpenHumanGmail", targets: ["OpenHumanGmail"]),
        .library(name: "OpenHumanMIME", targets: ["OpenHumanMIME"]),
        .library(name: "OpenHumanGmailApple", targets: ["OpenHumanGmailApple"]),
        .library(name: "OpenHumanGmailTesting", targets: ["OpenHumanGmailTesting"]),
        .executable(name: "gmail-fixture-recorder", targets: ["gmail-fixture-recorder"]),
    ],
    dependencies: [
        .package(path: "../OpenHumanCore"),
        .package(url: "https://github.com/apple/swift-crypto", exact: "3.15.1"),
    ],
    targets: [
        .target(name: "OpenHumanGmail", dependencies: ["OpenHumanCore", .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "OpenHumanMIME", dependencies: ["OpenHumanCore"]),
        .target(name: "OpenHumanGmailApple", dependencies: ["OpenHumanGmail", "OpenHumanCore"]),
        .target(name: "OpenHumanGmailTesting", dependencies: ["OpenHumanGmail", "OpenHumanMIME", "OpenHumanCore"]),
        .executableTarget(name: "gmail-fixture-recorder",
                          dependencies: ["OpenHumanGmail", "OpenHumanGmailTesting", "OpenHumanMIME", "OpenHumanCore"]),
        .testTarget(name: "OpenHumanGmailTests",
                    dependencies: ["OpenHumanGmail", "OpenHumanGmailTesting", "OpenHumanMIME", "OpenHumanCore"]),
        .testTarget(name: "OpenHumanMIMETests", dependencies: ["OpenHumanMIME", "OpenHumanCore"]),
        .testTarget(name: "OpenHumanGmailAppleTests", dependencies: ["OpenHumanGmailApple", "OpenHumanGmail", "OpenHumanCore"]),
        .testTarget(name: "OpenHumanGmailContractsTests", dependencies: ["OpenHumanGmail", "OpenHumanMIME", "OpenHumanCore"]),
    ],
    swiftLanguageModes: [.v6]
)

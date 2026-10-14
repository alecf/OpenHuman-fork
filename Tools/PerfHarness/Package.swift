// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PerfHarness",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "perf-harness", targets: ["perf-harness"]),
    ],
    dependencies: [
        .package(path: "../../Packages/OpenHumanMailUI"),
        .package(path: "../../Packages/OpenHumanMailCore"),
    ],
    targets: [
        .target(
            name: "PerfHarnessKit",
            dependencies: [
                .product(name: "MailUIMac", package: "OpenHumanMailUI"),
                .product(name: "MailFakes", package: "OpenHumanMailCore"),
                .product(name: "MailFeatures", package: "OpenHumanMailCore"),
            ]),
        .executableTarget(name: "perf-harness", dependencies: ["PerfHarnessKit"]),
        .testTarget(name: "PerfHarnessTests", dependencies: ["PerfHarnessKit"]),
    ],
    swiftLanguageModes: [.v6]
)

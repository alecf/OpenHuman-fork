import Foundation
import MailFakes
import MailFeatures
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

@MainActor
struct BuildFlavorTests {
    private static let appFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func text(_ relative: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func conditions(_ xcconfig: String) -> Set<String> {
        let line = xcconfig.components(separatedBy: "\n").first { $0.hasPrefix("SWIFT_ACTIVE_COMPILATION_CONDITIONS") }
        guard let value = line?.split(separator: "=", maxSplits: 1).dropFirst().first else { return [] }
        return Set(value.split(separator: " ").map(String.init))
    }

    @Test func eachFlavourCompilesItsOwnConditions() throws {
        #expect(Self.conditions(try Self.text("Config/Debug.xcconfig")) == ["DEBUG", "OH_DEV_TOOLS"])
        #expect(Self.conditions(try Self.text("Config/DevTools.xcconfig")) == ["OH_DEV_TOOLS"])
        #expect(Self.conditions(try Self.text("Config/Release.xcconfig")).isEmpty, "a release build has no developer code")
        let devTools = try Self.text("Config/DevTools.xcconfig")
        #expect(devTools.contains("SWIFT_OPTIMIZATION_LEVEL = -O"))
        #expect(!devTools.contains("dev-test-checklist"), "the dev-tools build keeps the test checklist")
        let project = try Self.text("project.yml")
        #expect(project.contains("DevTools: Config/DevTools.xcconfig"))
        #expect(project.contains("commandLineArguments: { \"-UseFakeGmail\": true }"), "Run starts on fake mail")
    }

    @Test func theTestHostIsADebugBuildWithTheDevTools() {
        #expect(BuildFlavor.name == "Debug")
        #expect(BuildFlavor.hasDevTools)
        #expect(DevFeedbackRuntime.availability == .devTools)
        #expect(CompositionRoot.dataMode(arguments: ["-UseFakeGmail"], environment: [:]) == .fakeGmail)
    }

    @Test func developerVariablesCountOnlyWhenSet() {
        #expect(BuildFlavor.home([:]) == nil && BuildFlavor.home(["OPENHUMAN_HOME": " "]) == nil)
        #expect(BuildFlavor.home(["OPENHUMAN_HOME": "/tmp/oh-home"]) == "/tmp/oh-home")
        #expect(BuildFlavor.oauthClientFile([:]) == nil)
        #expect(BuildFlavor.oauthClientFile(["OPENHUMAN_OAUTH_CLIENT_JSON": "/tmp/client.json"]) == "/tmp/client.json")
        #expect(BuildFlavor.storePollOnly(["OPENHUMAN_STORE_POLL_ONLY": "1"]))
        #expect(!BuildFlavor.storePollOnly(["OPENHUMAN_STORE_POLL_ONLY": "yes"]) && !BuildFlavor.storePollOnly([:]))
        #expect(BuildFlavor.feedbackDirectory(["OPENHUMAN_FEEDBACK_DIR": "/tmp/fb"]) == "/tmp/fb")
        #expect(BuildFlavor.feedbackDirectory(["OPENHUMAN_FEEDBACK_DIR": ""]) == nil)
    }

    @Test func theDebuggingToolsFollowTheirSwitch() throws {
        let suite = "debugging-tools-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 1, now: Date(timeIntervalSince1970: 1_791_000_000)))
        #expect(!environment.system.showsDebuggingTools(), "hidden until a dev-tools build installs the switch")
        let devTools = DeveloperOptions(devFeedback: .devTools, defaults: defaults)
        DebuggingTools.install(in: environment, options: devTools)
        #expect(!environment.system.showsDebuggingTools(), "off by default")
        devTools.debuggingTools = true
        #expect(environment.system.showsDebuggingTools())
        DebuggingTools.install(in: environment, options: DeveloperOptions(devFeedback: .off, defaults: defaults))
        #expect(!environment.system.showsDebuggingTools(), "a public build never shows them, whatever was stored")
        #expect(DeveloperOptionsSection.debuggingToolsTitle == "Show debugging tools")
        #expect(DeveloperOptionsSection.debuggingToolsDetail.contains("Copy debug info for this conversation"))
        #expect(!DeveloperOptionsSection.detail.contains("OPENHUMAN_"), "no variable turns developer options on")
    }

    @Test func theDeveloperEntryPointsAreCompiledOnlyIntoDevToolsBuilds() throws {
        let app = try Self.text("Sources/MailApp.swift")
        for entry in ["DeveloperCommands(center:", "Window(\"Test checklist\"", ".devFeedbackSheet(", "takeChecklistReopen()"] {
            let at = try #require(app.range(of: entry), "\(entry)")
            let before = app[..<at.lowerBound]
            let opened = before.components(separatedBy: "#if OH_DEV_TOOLS").count - 1
            let closed = before.components(separatedBy: "#endif").count - 1
            #expect(opened > closed, "\(entry) sits inside #if OH_DEV_TOOLS")
        }
        let settings = try Self.text("Sources/Settings/SettingsRoot.swift")
        let advanced = try #require(settings.range(of: "private var advanced: some View {"))
        #expect(settings[advanced.upperBound...].prefix(120).contains("#if OH_DEV_TOOLS"))
        #expect(try Self.text("Sources/DevFeedback/DeveloperCommands.swift").hasPrefix("#if OH_DEV_TOOLS\n"))
    }
}

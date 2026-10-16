import Foundation
import OpenHumanCore
import Testing
@testable import MailFeatures

@Suite struct DevFeedbackRedactorTests {
    let redactor = DevFeedbackRedactor(denylist: ["Quarterly numbers for Robin", "Dana Ruiz", "ab"])

    @Test(arguments: [
        ("token ya29.a0AfH6SMBx-y_zQQ end", "ya29."),
        ("refresh 1//0gAbCdEf_123456 ok", "1//0g"),
        ("Authorization: Bearer abc.def.ghi", "abc.def"),
        ("from dana@example.com to sam%40example.org", "example.com"),
        ("paste http://127.0.0.1:53682/?state=s7&code=4/0Abc-SECRET&scope=x", "SECRET"),
        ("{\"installed\":{\"client_id\":\"1234-abc.apps.googleusercontent.com\",\"client_secret\":\"GOCSPX-abcDEF123\"}}", "GOCSPX"),
        ("client_secret=GOCSPX-abcDEF123 client_id=1234-abc.apps.googleusercontent.com", "googleusercontent"),
        ("opened subject=Quarterly numbers for Robin now", "Quarterly"),
        ("sender DANA RUIZ wrote", "DANA"),
        ("code=4/0AdQt8qh-abcdefghijk state=xyz123", "AdQt8"),
        ("path /Users/someone/Library/Application Support/x", "someone/Library"),
        ("body: \"Hi Robin, the numbers are attached\"", "numbers are attached"),
    ])
    func removesSecretsAndContent(input: String, mustNotContain: String) {
        let out = redactor.scrub(input)
        #expect(!out.contains(mustNotContain), "\(out)")
    }

    @Test func keepsIdsCountsAndCodes() {
        let line = "account 3: synced 50 threads in 812 ms (history 123456, code server_503, phase inboxReady)"
        #expect(redactor.scrub(line) == line)
        #expect(redactor.scrub("thread 18f2a9c0d1e2b3a4 opened") == "thread 18f2a9c0d1e2b3a4 opened")
    }

    @Test func shortDenylistEntriesAreIgnoredAndOutputIsCapped() {
        #expect(redactor.scrub("tab label") == "tab label")
        #expect(redactor.scrub(String(repeating: "word ", count: 500)).count <= DevFeedbackRedactor.maxOutputLength + 1)
    }
}

@Suite struct DevFeedbackLogBufferTests {
    @Test func keepsTheLastTenMinutesAndTheCapacity() {
        let buffer = DevFeedbackLogBuffer(capacity: 3, window: 600)
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        buffer.append(.init(at: now.addingTimeInterval(-700), category: "sync", level: "info", message: "old"))
        buffer.append(.init(at: now.addingTimeInterval(-30), category: "sync", level: "info", message: "a"))
        buffer.append(.init(at: now.addingTimeInterval(-20), category: "sync", level: "error", message: "b"))
        #expect(buffer.lines(now: now).map(\.message) == ["a", "b"])
        buffer.append(.init(at: now.addingTimeInterval(-10), category: "app", level: "info", message: "c"))
        buffer.append(.init(at: now, category: "app", level: "info", message: String(repeating: "x", count: 5_000)))
        #expect(buffer.count == 3)
        #expect(buffer.lines(now: now).map(\.message.count) == [1, 1, DevFeedbackLogBuffer.maxLineLength + 1])
    }

    @Test func diagnosticLinesKeepTheNewestCappedAndSkipDebug() {
        let buffer = DevFeedbackLogBuffer()
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        buffer.append(.init(at: now.addingTimeInterval(-3), category: "sync", level: "debug", message: "noise"))
        for n in 1...4 { buffer.append(.init(at: now.addingTimeInterval(Double(-n)), category: "sync", level: "info", message: "m\(n)")) }
        let lines = buffer.diagnosticLines(now: now, limit: 2)
        #expect(lines.count == 2 && lines.allSatisfy { $0.contains(" info sync m") })
        #expect(!buffer.diagnosticLines(now: now).joined().contains("noise"))
        #expect(lines.first?.hasSuffix(" m3") == true && lines.last?.hasSuffix(" m4") == true, "the newest two, oldest first")
    }

    @Test func mirrorSinkReceivesRedactedLines() {
        let buffer = DevFeedbackLogBuffer()
        buffer.sink(Log.Record(date: Date(), category: .oauth, level: "error", message: Log.redact("ya29.abcdefgh")))
        #expect(buffer.lines(now: Date()).first?.message == "<redacted>")
        #expect(buffer.lines(now: Date()).first?.category == "oauth")
    }
}

@Suite struct DevFeedbackCommandsTests {
    func shellEcho(_ quoted: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test(arguments: [
        "/Users/a b/Library/Application Support/OpenHuman/Mail/feedback/feedback-20261010T120000Z-a1b2c3.json",
        "/tmp/it's \"quoted\" $(touch /tmp/oh-pwned) `id` ; rm -rf ~ & | > < * ? [x] {a,b} ~ # !",
        "/tmp/new\nline\tand tab",
    ])
    func quotedPathsReachTheShellAsOneLiteralArgument(_ path: String) throws {
        #expect(try shellEcho(DevFeedbackCommands.shellQuote(path)) == path)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/oh-pwned"))
    }

    @Test func sendCommandQuotesEveryFileAndUsesAValidTarget() throws {
        let files = [URL(fileURLWithPath: "/tmp/dir with space/feedback-x.json"), URL(fileURLWithPath: "/tmp/it's/feedback-x.png")]
        let command = DevFeedbackCommands.send(files: files, target: "mac-mini")
        #expect(command == "tailscale file cp '/tmp/dir with space/feedback-x.json' '/tmp/it'\\''s/feedback-x.png' mac-mini:")
        #expect(DevFeedbackCommands.send(files: files, target: "").hasSuffix(" <device-name>:"))
        #expect(DevFeedbackCommands.send(files: files, target: "mini; rm -rf ~").hasSuffix(" <device-name>:"))
        #expect(DevFeedbackCommands.send(files: files, target: "-oops").hasSuffix(" <device-name>:"))
        #expect(DevFeedbackCommands.send(files: files, target: " 100.101.102.103 ").hasSuffix(" 100.101.102.103:"))
        #expect(DevFeedbackCommands.receive == "mkdir -p ~/Downloads/OpenHuman-feedback/ && tailscale file get ~/Downloads/OpenHuman-feedback/")
    }
}

@Suite struct DevFeedbackGateTests {
    @Test func availability() {
        #expect(DevFeedbackAvailability.devTools.isAvailable)
        #expect(!DevFeedbackAvailability.off.isAvailable)
        #expect(DevFeedbackAvailability(rawValue: "environment") == nil, "no variable turns it on")
    }

    @Test func pathsFollowTheGivenFolders() {
        let paths = DevFeedbackPaths.resolve(home: "/tmp/oh home", feedbackDirectory: "/tmp/fb dir")
        #expect(paths.support.path == "/tmp/oh home")
        #expect(paths.feedbackDirectory.path == "/tmp/fb dir")
        #expect(paths.answers.lastPathComponent == "dev-checklist-answers.json")
        #expect(paths.checklistOverride.lastPathComponent == "dev-test-checklist.json")
        for (home, feedback) in [(nil, nil), ("", "")] as [(String?, String?)] {
            let fallback = DevFeedbackPaths.resolve(home: home, feedbackDirectory: feedback)
            #expect(fallback.feedbackDirectory.path.hasSuffix("Library/Application Support/OpenHuman/Mail/feedback"))
        }
    }

    @MainActor
    @Test func settingsPersistInDefaults() throws {
        let suite = "dev.openhuman.tests.devfeedback.settings"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DevFeedbackSettings(defaults: defaults)
        #expect(settings.isEnabled)
        #expect(settings.taildropTarget.isEmpty)
        settings.isEnabled = false
        settings.taildropTarget = "mac-mini"
        let again = DevFeedbackSettings(defaults: defaults)
        #expect(!again.isEnabled)
        #expect(again.taildropTarget == "mac-mini")
    }

    @Test func historyKeepsShortAsciiIdentifiersOnly() async {
        await MainActor.run {
            let history = DevFeedbackHistory()
            history.record("nav.nextThread")
            history.record("key:cmd+opt+f")
            history.record("key:é")
            history.record("typed some words")
            history.record(String(repeating: "x", count: 100))
            #expect(history.commands.map(\.id) == ["nav.nextThread", "key:cmd+opt+f", "other", "other", "other"])
            for i in 0..<100 { history.record("k\(i)") }
            #expect(history.commands.count == DevFeedbackHistory.capacity)
        }
    }

    @Test func bundleNamesAreUTCAndSafe() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(DevFeedbackExporter.baseName(createdAt: date, id: "a1b2c3") == "feedback-20261003T040000Z-a1b2c3")
        let id = DevFeedbackExporter.makeID()
        #expect(id.count == 6 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

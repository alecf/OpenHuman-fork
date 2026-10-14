import Foundation
import MailModel
import Testing
@testable import MailFeatures

struct FeedbackBundlerTests {
    static let now = Date(timeIntervalSince1970: 1_791_800_000)
    static let app = DiagnosticsAppInfo(version: "1.2", build: "345", gitCommit: "a1b2c3d", os: "Version 27.0 (Build 27A1)", dataMode: "live")

    func entries(_ bundle: FeedbackBundle) throws -> [String: Data] { try #require(ZipArchive.read(bundle.data)) }

    @Test func namesTheFileAndFolderByUTCDate() throws {
        let bundle = try FeedbackBundler.build(FeedbackInput(note: "hi", app: Self.app, accountCount: 2, now: Self.now))
        #expect(bundle.fileName == "OpenHuman-feedback-\(FeedbackBundler.stamp(Self.now)).zip")
        #expect(bundle.fileName.hasPrefix("OpenHuman-feedback-2026"))
        let names = try entries(bundle).keys.sorted()
        let folder = bundle.fileName.replacingOccurrences(of: ".zip", with: "")
        #expect(names == ["\(folder)/manifest.json", "\(folder)/note.txt"])
    }

    @Test func manifestHasVersionsAndOnlyTheAccountCount() throws {
        let bundle = try FeedbackBundler.build(FeedbackInput(note: "n", app: Self.app, accountCount: 3, now: Self.now))
        let manifest = bundle.manifest
        #expect(manifest.appVersion == "1.2" && manifest.build == "345" && manifest.commit == "a1b2c3d")
        #expect(manifest.macOS == "Version 27.0 (Build 27A1)")
        #expect(manifest.accountCount == 3)
        #expect(!manifest.includes.diagnostics && !manifest.includes.screenshot && !manifest.includes.threadSubjectAndSender)
        let raw = try #require(try entries(bundle).first { $0.key.hasSuffix("manifest.json") }?.value)
        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(Set(object.keys) == ["format", "formatVersion", "createdAt", "appVersion", "build", "commit", "macOS", "accountCount", "includes"])
    }

    @Test func adversarialAppStringsNeverReachTheManifest() throws {
        let evil = ["person@example.com", "Re: Quarterly plan for Acme", "ya29.A0ARrdaM-token", "123-abc.apps.googleusercontent.com",
                    "GOCSPX-secret", "https://example.com/?code=1", "a\"b", "<script>", String(repeating: "x", count: 65), "", "line\nbreak"]
        for string in evil {
            let info = DiagnosticsAppInfo(version: string, build: string, gitCommit: string, os: string, dataMode: string)
            let bundle = try FeedbackBundler.build(FeedbackInput(note: "", app: info, accountCount: 1, now: Self.now))
            let raw = try #require(try entries(bundle).first { $0.key.hasSuffix("manifest.json") }?.value)
            let text = String(decoding: raw, as: UTF8.self)
            for marker in ["example.com", "Quarterly", "Acme", "ya29", "googleusercontent", "GOCSPX", "script", "\\n"] {
                #expect(!text.contains(marker), "\(marker) leaked from \(string.prefix(20))")
            }
            #expect(bundle.manifest.appVersion == "<redacted>")
        }
    }

    @Test func ordinaryVersionSpellingsSurvive() throws {
        for version in ["1.2.3", "1.2-beta1", "345", "10"] {
            let info = DiagnosticsAppInfo(version: version, build: version, gitCommit: "unknown", os: "Version 27.0", dataMode: "live")
            let bundle = try FeedbackBundler.build(FeedbackInput(note: "", app: info, accountCount: 1, now: Self.now))
            #expect(bundle.manifest.appVersion == version && bundle.manifest.commit == "unknown" && bundle.manifest.macOS == "Version 27.0")
        }
        let dirty = DiagnosticsAppInfo(version: "1", build: "1", gitCommit: "a1b2c3d4-dirty", os: "x", dataMode: "live")
        #expect(try FeedbackBundler.build(FeedbackInput(note: "", app: dirty, accountCount: 1, now: Self.now)).manifest.commit == "a1b2c3d4-dirty")
    }

    @Test func diagnosticsTextIsScrubbedAgainstAdversarialLines() throws {
        let log = """
        sync ok
        failed for someone@example.com
        opened "Secret subject line" from https://mail.example.com/u/0/#inbox/abc
        token=ya29.verysecretvalue client_id=1234-abcd.apps.googleusercontent.com
        path /Users/someone/Library/Application%20Support/OpenHuman/Mail/store.sqlite3
        """
        let diagnostics: [String: Data] = ["log.txt": Data(log.utf8), "diagnostics.json": Data("{\"a\":1}".utf8), "../../evil.txt": Data("x".utf8)]
        let bundle = try FeedbackBundler.build(FeedbackInput(note: "", app: Self.app, accountCount: 0, diagnostics: diagnostics, now: Self.now))
        let files = try entries(bundle)
        let all = files.values.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        for leak in ["someone@example.com", "Secret subject", "mail.example.com", "ya29", "googleusercontent", "store.sqlite3"] {
            #expect(!all.contains(leak), "\(leak) leaked")
        }
        #expect(all.contains("sync ok"))
        #expect(files.keys.allSatisfy { !$0.contains("..") })
        #expect(files.keys.contains { $0.hasSuffix("diagnostics/evil.txt") })
        #expect(bundle.manifest.includes.diagnostics)
    }

    @Test func optionalPartsAreOnlyPresentWhenGiven() throws {
        let thread = FeedbackThreadHeader(subject: "Lunch plans", senderName: "Sam")
        let bundle = try FeedbackBundler.build(FeedbackInput(note: "n", app: Self.app, accountCount: 1, screenshotPNG: Data([1, 2, 3]),
                                                             thread: thread, now: Self.now))
        let names = try entries(bundle).keys
        #expect(names.contains { $0.hasSuffix("/screenshot.png") })
        let threadFile = try #require(try entries(bundle).first { $0.key.hasSuffix("/thread.txt") }?.value)
        #expect(String(decoding: threadFile, as: UTF8.self).contains("Lunch plans"))
        #expect(bundle.manifest.includes.screenshot && bundle.manifest.includes.threadSubjectAndSender)

        let without = try FeedbackBundler.build(FeedbackInput(note: "n", app: Self.app, accountCount: 1, now: Self.now))
        let joined = try entries(without).values.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!joined.contains("Lunch") && !joined.contains("Sam"))
        #expect(try !entries(without).keys.contains { $0.hasSuffix("screenshot.png") || $0.hasSuffix("thread.txt") })
    }

    @Test func extraFilesKeepToTheirFolderWithSafeNames() throws {
        let extras = ["conversationDebug": [FeedbackAttachment(name: "../../etc/passwd", data: Data("d".utf8)),
                                             FeedbackAttachment(name: "debug info.txt", data: Data("e".utf8))],
                      "../up": [FeedbackAttachment(name: "", data: Data("f".utf8))]]
        let bundle = try FeedbackBundler.build(FeedbackInput(note: "", app: Self.app, accountCount: 1, extras: extras, now: Self.now))
        let names = try entries(bundle).keys.sorted()
        #expect(names.allSatisfy { !$0.contains("..") && !$0.contains(" ") })
        #expect(names.contains { $0.hasSuffix("/extra/conversationDebug/passwd") })
        #expect(names.contains { $0.hasSuffix("/extra/conversationDebug/debuginfo.txt") })
        #expect(names.contains { $0.hasSuffix("/extra/up/file") })
        #expect(bundle.manifest.includes.extras == ["conversationDebug", "up"])
    }

    @Test func aLongNoteIsCapped() throws {
        let bundle = try FeedbackBundler.build(FeedbackInput(note: String(repeating: "a", count: 50_000), app: Self.app, accountCount: 1, now: Self.now))
        let note = try #require(try entries(bundle).first { $0.key.hasSuffix("note.txt") }?.value)
        #expect(note.count <= FeedbackBundler.maxNoteLength + 1)
    }
}

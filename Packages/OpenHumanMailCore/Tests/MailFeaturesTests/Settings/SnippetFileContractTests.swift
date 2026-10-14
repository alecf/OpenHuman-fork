import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SnippetFileContractTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("OpenHumanCore/Tests/OpenHumanCoreTests/Fixtures/snippets-v2.json")
    static let guide = Data("Synthetic onboarding guide.\n".utf8)

    private func mac() -> SettingsFixture {
        SettingsFixture(corpus: FakeCorpus(mailboxes: FakeCorpus.rich(threadCount: 4, now: fixedNow).mailboxes))
    }

    @Test func theAppWritesTheSharedFileByteForByte() async throws {
        let expected = try Data(contentsOf: Self.fixture)
        let hash = try #require(try SnippetsFile.decode(expected).snippets.first?.files?.first?.contentHash)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let guideURL = folder.appendingPathComponent("guide.txt")
        try Self.guide.write(to: guideURL)

        let f = mac()
        _ = try await f.store.upsertSnippet(SnippetInfo(
            name: "Onboarding", shortcut: "onb", subject: "Welcome aboard",
            bodyHTML: "<p>Welcome, {{first_name}}. Your guide is attached.</p><p>{{team}}</p>",
            variables: [SnippetVariableInfo(name: "team", defaultValue: "The Example team")],
            to: [EmailAddress(name: "Dana Ruiz", email: "dana@example.com")], cc: [EmailAddress(email: "team@example.com")],
            bcc: [EmailAddress(email: "records@example.com")],
            attachments: [SnippetAttachmentInfo(contentHash: hash, filename: "guide.txt", mimeType: "text/plain",
                                                size: Self.guide.count, fileURL: guideURL)]))
        _ = try await f.store.upsertSnippet(SnippetInfo(name: "Sign-off", shortcut: "so", bodyHTML: "<p>Best,<br>Sam</p>"))
        let exported = try await SnippetTransferModel(environment: f.env).export()
        #expect(exported == expected, "\(String(decoding: exported, as: UTF8.self))")
    }

    @Test func theAppReadsTheSharedFileWithBccAndFiles() async throws {
        let f = mac()
        let model = SnippetTransferModel(environment: f.env)
        let preview = try await model.prepareImport(try Data(contentsOf: Self.fixture))
        #expect(preview.toAdd == 2 && preview.withRecipients == 1 && preview.files == 1 && preview.filesDropped == 0)
        #expect(await model.applyImport() == "Imported 2 snippets.")
        let onboarding = try #require(try await f.snippets().first { $0.name == "Onboarding" })
        #expect(onboarding.to == [EmailAddress(name: "Dana Ruiz", email: "dana@example.com")])
        #expect(onboarding.cc == [EmailAddress(email: "team@example.com")] && onboarding.bcc == [EmailAddress(email: "records@example.com")])
        #expect(onboarding.variables == [SnippetVariableInfo(name: "team", defaultValue: "The Example team")])
        let file = try #require(onboarding.attachments.first)
        #expect(file.filename == "guide.txt" && file.mimeType == "text/plain")
        #expect(try Data(contentsOf: try #require(file.fileURL)) == Self.guide)
    }
}

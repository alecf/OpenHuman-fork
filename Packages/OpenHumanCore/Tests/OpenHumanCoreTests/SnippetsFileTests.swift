import Foundation
import Testing
@testable import OpenHumanCore

@Suite struct SnippetsFileTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/snippets-v2.json")

    @Test func theSharedFixtureReadsAndWritesBackUnchanged() throws {
        let bytes = try Data(contentsOf: Self.fixture)
        let file = try SnippetsFile.decode(bytes)
        #expect(file.version == 2 && file.snippets.map(\.name) == ["Onboarding", "Sign-off"])
        let onboarding = file.snippets[0]
        #expect(onboarding.bcc == [EmailAddress(email: "records@example.com")] && onboarding.hasRecipients)
        #expect(onboarding.files?.first?.data == Data("Synthetic onboarding guide.\n".utf8))
        #expect(try file.encoded() == bytes)
        #expect(try SnippetsFile(snippets: file.snippets).encoded() == bytes)
    }

    @Test func aFileWithoutRecipientsOrFilesIsVersion1() throws {
        let plain = SnippetsFile.Snippet(name: "Thanks", shortcut: "ty", subject: nil, bodyHTML: "<p>Thanks!</p>", variables: [])
        #expect(SnippetsFile(snippets: [plain]).version == 1)
        var withBcc = plain
        withBcc.bcc = [EmailAddress(email: "records@example.com")]
        #expect(SnippetsFile(snippets: [plain, withBcc]).version == 2)
        var empty = plain
        empty.to = []
        empty.files = []
        #expect(SnippetsFile(snippets: [empty]).version == 1)
        let text = String(decoding: try SnippetsFile(snippets: [plain]).encoded(), as: UTF8.self)
        #expect(!text.contains("null") && !text.contains("\"to\""))
    }

    @Test func otherFilesAndNewerVersionsAreRefused() {
        #expect(throws: SnippetsFile.ReadError.notASnippetsFile) { try SnippetsFile.decode(Data("garbage".utf8)) }
        #expect(throws: SnippetsFile.ReadError.notASnippetsFile) {
            try SnippetsFile.decode(Data(#"{"format":"openhuman-settings","version":1,"snippets":[]}"#.utf8))
        }
        #expect(throws: SnippetsFile.ReadError.newerVersion) {
            try SnippetsFile.decode(Data(#"{"format":"openhuman-snippets","version":3,"snippets":[]}"#.utf8))
        }
        #expect(throws: Never.self) { try SnippetsFile.decode(Data(#"{"format":"openhuman-snippets","version":1,"snippets":[]}"#.utf8)) }
    }

    @Test func importsUseNamedSnippetsWithABodyOncePerName() {
        let file = SnippetsFile(snippets: [
            .init(name: "  Thanks ", shortcut: nil, subject: nil, bodyHTML: "a", variables: []),
            .init(name: "thanks", shortcut: nil, subject: nil, bodyHTML: "second of a name", variables: []),
            .init(name: " ", shortcut: nil, subject: nil, bodyHTML: "no name", variables: []),
            .init(name: "Empty", shortcut: nil, subject: nil, bodyHTML: " \n", variables: []),
        ])
        #expect(file.usableSnippets.map(\.name) == ["Thanks"])
        let many = SnippetsFile(snippets: (0..<600).map { .init(name: "s\($0)", shortcut: nil, subject: nil, bodyHTML: "x", variables: []) })
        #expect(many.usableSnippets.count == SnippetsFile.maxSnippets)
    }

    @Test func filesOverTheCapsOrDamagedAreLeftOut() {
        func file(_ name: String, size: Int, bytes: Int? = nil) -> SnippetsFile.File {
            SnippetsFile.File(filename: name, mimeType: "text/plain", size: size, data: Data(count: bytes ?? size))
        }
        let accepted = SnippetsFile.acceptedFiles([file("a.txt", size: 4), file("lying.txt", size: 9, bytes: 3), file("big.bin", size: 11),
                                                   file(" ", size: 1), file("b.txt", size: 5), file("c.txt", size: 2)],
                                                  maxFiles: 2, maxFileBytes: 10, maxTotalBytes: 20)
        #expect(accepted.map(\.filename) == ["a.txt", "b.txt"])
        let total = SnippetsFile.acceptedFiles([file("a", size: 8), file("b", size: 8), file("c", size: 4)],
                                               maxFiles: 10, maxFileBytes: 10, maxTotalBytes: 12)
        #expect(total.map(\.filename) == ["a", "c"])
    }
}

import Foundation
import Testing
@testable import MailFeatures

struct ServiceInputTests {
    @Test func lineBreaksAreUnifiedAndControlCharactersRemovedExceptNewlineAndTab() {
        #expect(ServiceInput.clean("one\r\ntwo\rthree\nfour") == "one\ntwo\nthree\nfour")
        #expect(ServiceInput.clean("a\u{0}b\u{7}c\td\u{1B}e") == "abc\tde")
        #expect(ServiceInput.clean("\n\n  \n first\n\nlast  \n \n") == " first\n\nlast  ", "blank lines at either end go")
    }

    @Test func emptyAndWhitespaceOnlySelectionsAreRefused() {
        #expect(ServiceInput.clean("") == nil)
        #expect(ServiceInput.clean(" \n\t\r\n ") == nil)
        #expect(ServiceInput.body("\u{0}\u{1}") == nil)
        #expect(ServiceInput.searchQuery("\n\t \n") == nil)
    }

    @Test func htmlLookingTextIsKeptLiterally() {
        let raw = "<b>bold</b> <img src=\"https://tracker.example/x.gif\">"
        #expect(ServiceInput.body(raw)?.text == raw)
    }

    @Test func theBodyIsCutAt32KBOnACharacterBoundary() throws {
        let small = try #require(ServiceInput.body("hello"))
        #expect(small.text == "hello" && !small.wasCut)
        for unit in ["😀", "語", "e\u{301}\u{302}"] {
            let raw = String(repeating: unit, count: ServiceInput.maxBodyBytes / unit.utf8.count + 3)
            let body = try #require(ServiceInput.body(raw))
            #expect(body.wasCut)
            #expect(body.text.utf8.count <= ServiceInput.maxBodyBytes)
            #expect(body.text.utf8.count > ServiceInput.maxBodyBytes - unit.utf8.count)
            #expect(body.text.allSatisfy { String($0) == unit }, "no character is split")
        }
        let exact = String(repeating: "a", count: ServiceInput.maxBodyBytes)
        #expect(ServiceInput.body(exact)?.wasCut == false)
    }

    @Test func aSearchIsOneCollapsedLineOfAtMost512Characters() throws {
        #expect(ServiceInput.searchQuery("  invoice\n\n 2026-0042\tpaid  ") == "invoice 2026-0042 paid")
        let long = String(repeating: "ab ", count: 400)
        let query = try #require(ServiceInput.searchQuery(long))
        #expect(query.count <= ServiceInput.maxSearchCharacters)
        #expect(!query.hasSuffix(" "))
        #expect(ServiceInput.searchQuery("from:dana subject:(q3 plan)") == "from:dana subject:(q3 plan)", "the Store's syntax is kept")
    }

    @Test func onlyRegularReadableFilesAreKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("services-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let inner = folder.appendingPathComponent("Folder", isDirectory: true)
        let package = folder.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.txt")
        try Data("synthetic".utf8).write(to: file)
        let missing = folder.appendingPathComponent("gone.pdf")
        let selection = ServiceInput.files([file, inner, package, missing, URL(string: "https://example.com/a.pdf")!])
        #expect(selection.files.map(\.lastPathComponent) == ["notes.txt"])
        #expect(selection.foldersSkipped == 2)
        #expect(selection.unreadableSkipped == 2)
    }
}

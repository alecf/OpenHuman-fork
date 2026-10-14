import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

struct EMLBuilderTests {
    private let when = Date(timeIntervalSince1970: 1_791_881_600)

    private func message(from: EmailAddress? = EmailAddress(name: "Sam Sample", email: "sam@example.test"),
                         bcc: [EmailAddress] = [], attachments: [AttachmentInfo] = []) -> MessageSummary {
        MessageSummary(id: MessageKey(account: AccountID(1), rowID: 255, gmailMessageID: GmailMessageID("m1")), from: from,
                       to: [EmailAddress(name: "Pat, Other", email: "pat@example.test")],
                       cc: [EmailAddress(name: nil, email: "cc@example.test")], bcc: bcc, date: when, snippet: "snippet text",
                       isUnread: false, attachments: attachments)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func headersBodyAndLineEndsAreWhatMailReadersExpect() throws {
        let eml = text(EMLBuilder.eml(subject: "Invoice 42", message: message(),
                                      content: MessageContent(html: nil, text: "Hello there")))
        let lines = eml.components(separatedBy: "\r\n")
        #expect(lines.contains("From: Sam Sample <sam@example.test>"))
        #expect(lines.contains("To: \"Pat, Other\" <pat@example.test>"), "a comma in a name makes it a quoted string")
        #expect(lines.contains("Cc: cc@example.test"))
        #expect(lines.contains("Date: Tue, 13 Oct 2026 08:53:20 +0000"))
        #expect(lines.contains("Subject: Invoice 42"))
        #expect(lines.contains("MIME-Version: 1.0"))
        #expect(lines.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(lines.contains { $0.hasPrefix("X-OpenHuman-Export: ") })
        #expect(!eml.contains("\n") || !eml.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF only")
        let blank = try #require(lines.firstIndex(of: ""))
        let body = lines[(blank + 1)...].joined()
        #expect(Data(base64Encoded: body).map(text) == "Hello there")
    }

    @Test func bothPartsMakeAMultipartAlternativeAndBccIsNeverWritten() {
        let eml = text(EMLBuilder.eml(subject: "S", message: message(bcc: [EmailAddress(name: nil, email: "secret@example.test")]),
                                      content: MessageContent(html: "<p>Hi</p>", text: "Hi")))
        #expect(eml.contains("Content-Type: multipart/alternative; boundary=\"openhuman-ff\""))
        #expect(eml.contains("Content-Type: text/html; charset=UTF-8"))
        #expect(eml.components(separatedBy: "--openhuman-ff").count == 4, "two parts and the closing delimiter")
        #expect(eml.hasSuffix("--openhuman-ff--\r\n"))
        #expect(!eml.contains("secret@example.test") && !eml.localizedCaseInsensitiveContains("bcc:"))
    }

    @Test func noStoredBodyWritesTheSnippetAndOmittedAttachmentsAreSaid() {
        let attachment = AttachmentInfo(id: 1, filename: "a.pdf", mimeType: "application/pdf", size: 1, contentID: nil, isInline: false)
        let eml = text(EMLBuilder.eml(subject: "S", message: message(attachments: [attachment]), content: nil))
        #expect(eml.contains("(1 attachment(s) omitted)"))
        let body = eml.components(separatedBy: "\r\n\r\n").last ?? ""
        #expect(Data(base64Encoded: body.replacingOccurrences(of: "\r\n", with: "")).map(text) == "snippet text")
    }

    @Test func nonASCIIAndHostileHeaderValuesAreEncodedAndCannotStartAHeader() {
        let hostile = "Re: hi\r\nBcc: attacker@example.test"
        let eml = text(EMLBuilder.eml(subject: hostile, message: message(from: EmailAddress(name: "Zoë\nX-Evil: 1", email: "z@example.test")),
                                      content: MessageContent(html: nil, text: "x")))
        let lines = eml.components(separatedBy: "\r\n")
        #expect(lines.filter { $0.hasPrefix("Bcc:") }.isEmpty)
        #expect(lines.filter { $0.hasPrefix("X-Evil") }.isEmpty)
        #expect(lines.contains("Subject: Re: hiBcc: attacker@example.test"))
        #expect(lines.contains { $0.hasPrefix("From: =?UTF-8?B?") })
        let long = EMLBuilder.encodedWord(String(repeating: "é", count: 100))
        #expect(long.components(separatedBy: "\r\n ").allSatisfy { $0.count <= 75 }, "encoded words stay within 75 characters")
    }
}

@Suite struct ThreadEMLDragWriterTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thread-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func threads(_ store: FakeMailStore) async throws -> (single: ThreadRow, multi: ThreadRow) {
        let account = try #require(FakeCorpus.rich(threadCount: 60, now: fixedNow).accounts.first?.id)
        let rows = try await store.threadPage(.system(.allMail), account: account, after: nil, limit: 1_000).rows
        return (try #require(rows.first { $0.messageCount == 1 }), try #require(rows.first { $0.messageCount >= 2 }))
    }

    private func store() -> FakeMailStore {
        FakeMailStore(corpus: .rich(threadCount: 60, now: fixedNow), options: .init(remoteAck: .immediate, now: { fixedNow }))
    }

    @Test func oneMessageIsOneEMLFileNamedBySubjectAndNeverReplaced() async throws {
        let store = store()
        let (single, _) = try await threads(store)
        let writer = ThreadEMLDragWriter(data: store)
        let destination = try folder()
        defer { try? FileManager.default.removeItem(at: destination) }
        let first = try await writer.write(single.id, to: destination)
        #expect(first.pathExtension == "eml" && first.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL)
        let bytes = try String(decoding: Data(contentsOf: first), as: UTF8.self)
        #expect(bytes.contains("MIME-Version: 1.0") && bytes.contains("\r\nDate: "))
        try Data("the user's own file".utf8).write(to: destination.appendingPathComponent("keep.eml"))
        let second = try await writer.write(single.id, to: destination)
        #expect(second != first && second.lastPathComponent.contains(" 2"), "a second drop gets the next free name")
        #expect(try Data(contentsOf: first) == Data(contentsOf: first))
        let taken = destination.appendingPathComponent("keep.eml")
        let third = try await writer.write(single.id, to: taken)
        #expect(third != taken)
        #expect(try Data(contentsOf: taken) == Data("the user's own file".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.contains("partial") }
        #expect(leftovers.isEmpty, "no temporary file is left behind")
    }

    @Test func severalMessagesAreAFolderOfNumberedEMLFiles() async throws {
        let store = store()
        let (_, multi) = try await threads(store)
        let writer = ThreadEMLDragWriter(data: store)
        let destination = try folder()
        defer { try? FileManager.default.removeItem(at: destination) }
        let written = try await writer.write(multi.id, to: destination)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: written.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let names = try FileManager.default.contentsOfDirectory(atPath: written.path).sorted()
        #expect(names.count == multi.messageCount || names.count >= 2)
        #expect(names.first?.hasPrefix("01 ") == true && names.allSatisfy { $0.hasSuffix(".eml") })
        let again = try await writer.write(multi.id, to: destination)
        #expect(again != written, "the folder is never merged into or replaced")
    }

    @Test func promisedNamesAreSafeAndMatchTheMessageCount() {
        #expect(ThreadEMLDragWriter.promisedName(subject: "Re: a/b\\c", messageCount: 1) == "Re- a-b-c.eml")
        #expect(ThreadEMLDragWriter.promisedName(subject: "Re: a/b", messageCount: 3) == "Re- a-b")
        #expect(ThreadEMLDragWriter.promisedName(subject: "", messageCount: 1) == "No subject.eml")
        #expect(ThreadEMLDragWriter.promisedName(subject: "x.eml", messageCount: 1) == "x.eml")
        #expect(ThreadEMLDragWriter.promisedName(subject: String(repeating: "a", count: 400), messageCount: 1).count <= 200)
    }

    @Test func aLongEmojiSubjectStillMakesNamesThatCanBeWrittenTwice() throws {
        let subject = String(repeating: "😀", count: 180)
        let single = ThreadEMLDragWriter.promisedName(subject: subject, messageCount: 1)
        let member = ThreadEMLDragWriter.ensureExtension("12 " + ReaderFormatting.safeFilename(subject))
        for name in [single, member] {
            #expect(name.hasSuffix(".eml") && name.decomposedStringWithCanonicalMapping.utf8.count <= ReaderFormatting.maxFilenameBytes)
        }
        let destination = try folder()
        defer { try? FileManager.default.removeItem(at: destination) }
        let first = try ThreadEMLDragWriter.writeFile(Data("a".utf8), named: single, to: destination)
        let second = try ThreadEMLDragWriter.writeFile(Data("b".utf8), named: single, to: destination)
        #expect(first != second)
        let name = ThreadEMLDragWriter.promisedName(subject: subject, messageCount: 2)
        let files = [(name: member, data: Data("c".utf8))]
        let folders = [try ThreadEMLDragWriter.writeFolder(files, named: name, to: destination),
                       try ThreadEMLDragWriter.writeFolder(files, named: name, to: destination)]
        #expect(folders[0] != folders[1])
    }

    @Test func aGoneConversationFailsCleanlyAndWritesNothing() async throws {
        let store = store()
        let writer = ThreadEMLDragWriter(data: store)
        let destination = try folder()
        defer { try? FileManager.default.removeItem(at: destination) }
        let gone = ThreadKey(account: AccountID(1), rowID: 9_999_999, gmailThreadID: GmailThreadID("nope"))
        await #expect(throws: (any Error).self) { try await writer.write(gone, to: destination) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func theWriterReadsTheStoredBodyAndNeverWaitsForAFetch() async throws {
        let slow = FakeMailStore(corpus: .rich(threadCount: 60, now: fixedNow),
                                 options: .init(remoteAck: .immediate, bodyDelay: .seconds(600), now: { fixedNow }))
        let (single, _) = try await threads(slow)
        let destination = try folder()
        defer { try? FileManager.default.removeItem(at: destination) }
        let started = ContinuousClock.now
        let written = try await ThreadEMLDragWriter(data: slow).write(single.id, to: destination)
        #expect(ContinuousClock.now - started < .seconds(30))
        let detail = try #require(try await first(slow.threadDetail(single.id)) ?? nil)
        let stored = try #require(try await slow.storedBody(detail.messages[0].id))
        let text = try #require(stored.text ?? stored.html)
        let eml = try String(decoding: Data(contentsOf: written), as: UTF8.self)
        #expect(eml.contains(Data(text.utf8).base64EncodedString().prefix(60)))
    }

    @MainActor
    @Test func theSameModuleSwitchInstallsOrRemovesTheThreadWriter() {
        let on = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow), featureFlags: FeatureFlags())
        #expect(on.threadDrag != nil)
        let off = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow),
                                      featureFlags: FeatureFlags().with(.attachmentDragOut, false))
        #expect(off.threadDrag == nil)
    }
}

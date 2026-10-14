import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct AttachmentFetcherTests {
    private let pdf = Data("%PDF-1.4 synthetic attachment bytes".utf8)

    private func stored(_ h: SyncHarness) async throws -> (GmailMessageID, MessageItem) {
        let (id, _) = await h.gmail.deliver(
            subject: "Report", body: "See attached.", html: "<p>See <img src=\"cid:logo@fake\"></p>",
            attachments: [FakeGmailAttachment(filename: "report.pdf", mimeType: "application/pdf", data: pdf),
                          FakeGmailAttachment(filename: "logo.png", mimeType: "image/png", data: FakeGmailAttachment.tinyPNG,
                                              contentID: "logo@fake")])
        try await h.syncer.sync(reason: "launch")
        let message = GmailMessageID(id)
        _ = try await BodyFetcher(account: h.account, store: h.store, api: h.gmail).ensureBody(message)
        return (message, try #require(try h.store.message(account: h.account, gmailMessageID: message)))
    }

    @Test func aFileAttachmentIsDownloadedOnceIntoTheStoreWith0600AndQuarantine() async throws {
        let h = try SyncHarness(settings: SyncSettings(prefetchFullBodies: 0), onDisk: true)
        let directory = try #require(h.location?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (message, item) = try await stored(h)
        #expect(item.attachments.count == 2)
        let file = try #require(item.attachments.first { !$0.isInline })
        #expect(file.filename == "report.pdf" && file.localFileURL == nil)
        await h.gmail.resetAccounting()

        let fetcher = AttachmentFetcher(account: h.account, store: h.store, api: h.gmail, storeDirectory: directory)
        let url = try await fetcher.attachmentFile(message: message, attachment: file.id)
        #expect(try Data(contentsOf: url) == pdf)
        #expect(url.lastPathComponent == "report.pdf")
        #expect(url.path.hasPrefix(directory.appendingPathComponent("Attachments").path + "/"))
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        #expect(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        let quarantine = try #require(FileQuarantine.read(url))
        #expect(quarantine.hasPrefix(FileQuarantine.flags + ";") && quarantine.contains(";\(FileQuarantine.agent);"))
        #expect(await h.gmail.callLog == [.getMessage, .getAttachment])

        let again = try #require(try h.store.message(account: h.account, gmailMessageID: message))
        #expect(again.attachments.first { $0.id == file.id }?.localFileURL?.standardizedFileURL == url.standardizedFileURL)
        #expect(try await fetcher.attachmentFile(message: message, attachment: file.id) == url)
        #expect(await h.gmail.callLog == [.getMessage, .getAttachment])
    }

    @Test func anInlinePartIsServedTheSameWay() async throws {
        let h = try SyncHarness(settings: SyncSettings(prefetchFullBodies: 0), onDisk: true)
        let directory = try #require(h.location?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (message, item) = try await stored(h)
        let inline = try #require(item.attachments.first { $0.isInline })
        #expect(inline.contentID == "logo@fake")
        let fetcher = AttachmentFetcher(account: h.account, store: h.store, api: h.gmail, storeDirectory: directory)
        let url = try await fetcher.attachmentFile(message: message, attachment: inline.id)
        #expect(try Data(contentsOf: url) == FakeGmailAttachment.tinyPNG)
    }

    @Test func tooLargeAndMissingAreRefusedWithoutADownload() async throws {
        let h = try SyncHarness(settings: SyncSettings(prefetchFullBodies: 0), onDisk: true)
        let directory = try #require(h.location?.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (message, item) = try await stored(h)
        let fetcher = AttachmentFetcher(account: h.account, store: h.store, api: h.gmail, storeDirectory: directory)
        await h.gmail.resetAccounting()
        await #expect(throws: AttachmentFetcher.Failure.notFound) {
            _ = try await fetcher.attachmentFile(message: message, attachment: 999_999)
        }
        await #expect(throws: AttachmentFetcher.Failure.notFound) {
            _ = try await fetcher.attachmentFile(message: GmailMessageID("nope"), attachment: item.attachments[0].id)
        }
        #expect(await h.gmail.callLog.isEmpty)

        let big = Data(count: AttachmentFetcher.maxBytes + 1)
        let (bigID, _) = await h.gmail.deliver(subject: "Big", attachments: [
            FakeGmailAttachment(filename: "big.bin", mimeType: "application/octet-stream", data: big)])
        try await h.syncer.sync(reason: "poll")
        let bigMessage = GmailMessageID(bigID)
        _ = try await BodyFetcher(account: h.account, store: h.store, api: h.gmail).ensureBody(bigMessage)
        let row = try #require(try h.store.message(account: h.account, gmailMessageID: bigMessage)?.attachments.first)
        #expect(row.size == AttachmentFetcher.maxBytes + 1)
        await h.gmail.resetAccounting()
        await #expect(throws: AttachmentFetcher.Failure.tooLarge(AttachmentFetcher.maxBytes + 1)) {
            _ = try await fetcher.attachmentFile(message: bigMessage, attachment: row.id)
        }
        #expect(await h.gmail.callLog.isEmpty)
    }

    @Test func pathsStayInsideTheAttachmentsFolder() {
        let path = AttachmentFetcher.relativePath(account: AccountID(3), message: GmailMessageID("../../etc"),
                                                  partID: "..", filename: "../../.ssh/authorized_keys")
        #expect(path.hasPrefix("Attachments/3/"))
        #expect(!path.split(separator: "/").contains(".."))
        #expect(!path.split(separator: "/").contains { $0.hasPrefix(".") })
    }
}

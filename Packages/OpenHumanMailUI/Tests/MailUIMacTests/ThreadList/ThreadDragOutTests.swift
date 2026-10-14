import AppKit
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import Testing
import UniformTypeIdentifiers
@testable import MailUIMac

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
@Suite(.serialized)
struct ThreadDragOutTests {
    @Test func aRowDragsOutAFilePromiseNamedBySubjectWhileTheWriterIsSet() async throws {
        let (controller, model, store, _) = try await ThreadListViewTests.list(threads: 12)
        let tableView = controller.tableView
        #expect(controller.tableView(tableView, pasteboardWriterForRow: 0) == nil, "no writer: no drag")
        controller.threadDragWriter = { ThreadEMLDragWriter(data: store) }
        let row = try #require(model.rows.first)
        let writer = try #require(controller.tableView(tableView, pasteboardWriterForRow: 0) as? NSFilePromiseProvider)
        let delegate = try #require(writer.userInfo as? ThreadPromiseDelegate)
        #expect(delegate.thread == row.id)
        #expect(writer.fileType == (row.messageCount == 1 ? ThreadPromiseDelegate.emailType : UTType.folder).identifier)
        #expect(delegate.filePromiseProvider(writer, fileNameForType: writer.fileType)
            == ThreadEMLDragWriter.promisedName(subject: row.subject, messageCount: row.messageCount))
        #expect(delegate.operationQueue(for: writer) === AttachmentPromiseDelegate.queue, "written off the main queue")
    }

    @Test func theEmailTypeIsOneTheFilePromiseAcceptsAndConformsToData() {
        #expect(ThreadPromiseDelegate.emailType.conforms(to: .data))
        let delegate = ThreadPromiseDelegate(thread: ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t")),
                                             subject: "S", messageCount: 1, writer: ThreadEMLDragWriter(data: FakeMailStore(corpus: .make(threadCount: 1, now: now))),
                                             failed: {})
        _ = NSFilePromiseProvider(fileType: delegate.fileType.identifier, delegate: delegate)
        _ = NSFilePromiseProvider(fileType: UTType.folder.identifier, delegate: delegate)
    }

    @Test func theFileIsWrittenAtTheDropAndAFailedWriteIsReported() async throws {
        let (controller, model, store, _) = try await ThreadListViewTests.list(threads: 12)
        controller.threadDragWriter = { ThreadEMLDragWriter(data: store) }
        let reported = Reported()
        controller.dragFailed = { reported.count += 1 }
        let tableView = controller.tableView
        let index = try #require(model.rows.firstIndex { $0.messageCount == 1 })
        let provider = try #require(controller.tableView(tableView, pasteboardWriterForRow: index) as? NSFilePromiseProvider)
        let delegate = try #require(provider.userInfo as? ThreadPromiseDelegate)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("thread-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent(delegate.promisedName)
        let error: (any Error)? = await Task.detached { ThreadPromiseDelegate.waitForWrite(delegate.writer, delegate.thread, to: target) }.value
        #expect(error == nil && FileManager.default.fileExists(atPath: target.path))
        #expect(target.pathExtension == "eml")

        let gone = ThreadPromiseDelegate(thread: ThreadKey(account: AccountID(1), rowID: 9_999_999, gmailThreadID: GmailThreadID("x")),
                                         subject: "Gone", messageCount: 1, writer: ThreadEMLDragWriter(data: store),
                                         failed: { reported.count += 1 })
        nonisolated(unsafe) let promise = provider
        let goneURL = folder.appendingPathComponent("Gone.eml")
        let waiter = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                gone.filePromiseProvider(promise, writePromiseTo: goneURL) { continuation.resume(returning: $0 != nil) }
            }
        }
        #expect(waiter)
        try await until { reported.count == 1 }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Gone.eml").path))
    }
}

@MainActor
private final class Reported { var count = 0 }

import AppKit
import MailFeatures
import MailModel
import UniformTypeIdentifiers

final class ThreadPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let thread: ThreadKey
    let subject: String
    let messageCount: Int
    let writer: ThreadEMLDragWriter
    let failed: @MainActor @Sendable () -> Void

    init(thread: ThreadKey, subject: String, messageCount: Int, writer: ThreadEMLDragWriter,
         failed: @escaping @MainActor @Sendable () -> Void) {
        self.thread = thread
        self.subject = subject
        self.messageCount = messageCount
        self.writer = writer
        self.failed = failed
        super.init()
    }

    var fileType: UTType { messageCount == 1 ? Self.emailType : .folder }

    static let emailType: UTType = UTType(filenameExtension: "eml", conformingTo: .data) ?? .data

    var promisedName: String { ThreadEMLDragWriter.promisedName(subject: subject, messageCount: messageCount) }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        promisedName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        AttachmentPromiseDelegate.queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let error = Self.waitForWrite(writer, thread, to: url)
        completionHandler(error)
        if error != nil {
            let failed = self.failed
            Task { @MainActor in failed() }
        }
    }

    static func waitForWrite(_ writer: ThreadEMLDragWriter, _ thread: ThreadKey, to url: URL) -> (any Error)? {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                try await writer.write(thread, to: url)
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        done.wait()
        return outcome.error
    }
}

private final class Outcome: @unchecked Sendable {
    var error: (any Error)?
}

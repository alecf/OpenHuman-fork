// Why: the file is written on a serial background queue, never main, so a running fetch cannot stall the window
import AppKit
import MailFeatures
import MailModel

final class AttachmentPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let attachment: AttachmentInfo
    let message: MessageKey
    let writer: AttachmentDragWriter
    let failed: @MainActor @Sendable (AttachmentInfo) -> Void

    nonisolated(unsafe) static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.openhuman.mail.attachment-drag"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(attachment: AttachmentInfo, message: MessageKey, writer: AttachmentDragWriter,
         failed: @escaping @MainActor @Sendable (AttachmentInfo) -> Void) {
        self.attachment = attachment
        self.message = message
        self.writer = writer
        self.failed = failed
        super.init()
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        AttachmentDragWriter.fileName(for: attachment)
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let error = Self.waitForWrite(writer, attachment, message, to: url)
        completionHandler(error)
        if error != nil {
            let failed = self.failed
            let attachment = self.attachment
            Task { @MainActor in failed(attachment) }
        }
    }

    static func waitForWrite(_ writer: AttachmentDragWriter, _ attachment: AttachmentInfo, _ message: MessageKey,
                             to url: URL) -> (any Error)? {
        let outcome = WriteOutcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                try await writer.write(attachment, of: message, to: url)
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        done.wait()
        return outcome.error
    }
}

private final class WriteOutcome: @unchecked Sendable {
    var error: (any Error)?
}

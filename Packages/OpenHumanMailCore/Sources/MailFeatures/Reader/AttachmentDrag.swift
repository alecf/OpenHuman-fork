import Foundation
import MailModel
import OpenHumanCore

public final class AttachmentDragWriter: Sendable {
    public typealias Fetch = @Sendable (MessageKey, AttachmentInfo) async throws -> URL

    private let fetcher: Fetcher
    private let log = Log(.app)

    public init(fetch: @escaping Fetch) {
        fetcher = Fetcher(fetch: fetch)
    }

    public convenience init(data: any MailDataSource) {
        self.init(fetch: { key, attachment in
            let url = try await data.attachmentData(key, attachment: attachment)
            try AttachmentFiles.ensureQuarantine(url)
            return url
        })
    }

    public static func fileName(for attachment: AttachmentInfo) -> String {
        ReaderFormatting.safeFilename(attachment.filename)
    }

    public func prepare(_ attachment: AttachmentInfo, of key: MessageKey) {
        let fetcher = self.fetcher
        Task.detached(priority: .userInitiated) { _ = try? await fetcher.file(attachment, of: key) }
    }

    public func file(_ attachment: AttachmentInfo, of key: MessageKey) async throws -> URL {
        try await fetcher.file(attachment, of: key)
    }

    @discardableResult
    public func write(_ attachment: AttachmentInfo, of key: MessageKey, to destination: URL) async throws -> URL {
        do {
            let source = try await fetcher.file(attachment, of: key)
            try Task.checkCancellation()
            let written = try Self.copy(source, named: Self.fileName(for: attachment), to: destination)
            log.info("attachment drag: written")
            return written
        } catch {
            log.info("attachment drag: failed (\(error is CancellationError ? "cancelled" : "error"))")
            throw error
        }
    }

    public static func target(for destination: URL, filename: String) -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return destination }
        if isDirectory.boolValue { return AttachmentFiles.uniqueURL(in: destination, filename: filename) }
        return AttachmentFiles.uniqueURL(in: destination.deletingLastPathComponent(), filename: destination.lastPathComponent)
    }

    static func copy(_ source: URL, named filename: String, to destination: URL) throws -> URL {
        let manager = FileManager.default
        var target = target(for: destination, filename: filename)
        let name = target.lastPathComponent
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).openhuman-partial")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        try AttachmentFiles.setQuarantine(AttachmentFiles.quarantine(of: source) ?? AttachmentFiles.newQuarantineValue(),
                                          on: temporary)
        try Task.checkCancellation()
        for _ in 0..<100 {
            if try moveExclusively(temporary, to: target) { return target }
            target = AttachmentFiles.uniqueURL(in: folder, filename: name)
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func moveExclusively(_ source: URL, to target: URL) throws -> Bool {
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let error = errno
        if error == EEXIST { return false }
        guard error == ENOTSUP || error == EINVAL else { throw posixError(error, target) }
        let placeholder = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard placeholder >= 0 else {
            let error = errno
            if error == EEXIST { return false }
            throw posixError(error, target)
        }
        close(placeholder)
        if rename(source.path, target.path) == 0 { return true }
        let renameError = errno
        unlink(target.path)
        throw posixError(renameError, target)
    }

    private static func posixError(_ code: Int32, _ url: URL) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSURLErrorKey: url])
    }
}

private actor Fetcher {
    private struct Key: Hashable {
        let message: MessageKey
        let attachment: Int64
    }

    private let fetch: AttachmentDragWriter.Fetch
    private var tasks: [Key: Task<URL, Error>] = [:]

    init(fetch: @escaping AttachmentDragWriter.Fetch) { self.fetch = fetch }

    func file(_ attachment: AttachmentInfo, of key: MessageKey) async throws -> URL {
        let id = Key(message: key, attachment: attachment.id)
        if let task = tasks[id] {
            if let url = try? await task.value, FileManager.default.fileExists(atPath: url.path) { return url }
            if tasks[id] == task { tasks[id] = nil }
        }
        if let task = tasks[id] { return try await task.value }
        let fetch = self.fetch
        let task = Task { try await fetch(key, attachment) }
        tasks[id] = task
        do {
            return try await task.value
        } catch {
            if tasks[id] == task { tasks[id] = nil }
            throw error
        }
    }
}

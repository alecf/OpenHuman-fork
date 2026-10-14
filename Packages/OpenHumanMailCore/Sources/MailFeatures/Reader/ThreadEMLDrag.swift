import Foundation
import MailModel
import OpenHumanCore

public final class ThreadEMLDragWriter: Sendable {
    private let data: any MailDataSource
    private let log = Log(.app)

    public init(data: any MailDataSource) { self.data = data }

    public static func promisedName(subject: String, messageCount: Int) -> String {
        let base = ReaderFormatting.safeFilename(subject.isEmpty ? "No subject" : subject)
        return messageCount == 1 ? ensureExtension(base) : base
    }

    static func ensureExtension(_ name: String) -> String {
        let trimmed = String(name.prefix(190))
        return ReaderFormatting.fittingFilename(trimmed.lowercased().hasSuffix(".eml") ? trimmed : trimmed + ".eml")
    }

    public func files(for thread: ThreadKey) async throws -> (subject: String, files: [(name: String, data: Data)]) {
        var detail: ConversationDetail?
        for try await value in data.threadDetail(thread) {
            detail = value
            break
        }
        guard let detail, !detail.messages.isEmpty else { throw MailPortError.notFound("conversation") }
        var files: [(String, Data)] = []
        let subject = detail.subject
        for (index, message) in detail.messages.enumerated() {
            try Task.checkCancellation()
            let content = try await data.storedBody(message.id)
            let bytes = EMLBuilder.eml(subject: subject, message: message, content: content)
            let name = detail.messages.count == 1
                ? Self.promisedName(subject: subject, messageCount: 1)
                : Self.ensureExtension(String(format: "%02d ", index + 1) + ReaderFormatting.safeFilename(subject.isEmpty ? "No subject" : subject))
            files.append((name, bytes))
        }
        return (subject, files)
    }

    @discardableResult
    public func write(_ thread: ThreadKey, to destination: URL) async throws -> URL {
        do {
            let (subject, files) = try await files(for: thread)
            try Task.checkCancellation()
            let written: URL
            if files.count == 1, let file = files.first {
                written = try Self.writeFile(file.data, named: file.name, to: destination)
            } else {
                written = try Self.writeFolder(files, named: Self.promisedName(subject: subject, messageCount: files.count),
                                               to: destination)
            }
            log.info("thread drag: written")
            return written
        } catch {
            log.info("thread drag: failed (\(error is CancellationError ? "cancelled" : "error"))")
            throw error
        }
    }

    static func writeFile(_ bytes: Data, named name: String, to destination: URL) throws -> URL {
        let manager = FileManager.default
        var target = AttachmentDragWriter.target(for: destination, filename: name)
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).openhuman-partial")
        defer { try? manager.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: [.atomic])
        try Task.checkCancellation()
        let base = target.lastPathComponent
        for _ in 0..<100 {
            if try AttachmentDragWriter.moveExclusively(temporary, to: target) { return target }
            target = AttachmentFiles.uniqueURL(in: folder, filename: base)
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func writeFolder(_ files: [(name: String, data: Data)], named name: String, to destination: URL) throws -> URL {
        let manager = FileManager.default
        var target = AttachmentDragWriter.target(for: destination, filename: name)
        let parent = target.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).openhuman-partial")
        defer { try? manager.removeItem(at: temporary) }
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        for file in files {
            try file.data.write(to: temporary.appendingPathComponent(file.name), options: [.atomic])
        }
        try Task.checkCancellation()
        let base = target.lastPathComponent
        for _ in 0..<100 {
            if try AttachmentDragWriter.moveExclusively(temporary, to: target) { return target }
            target = AttachmentFiles.uniqueURL(in: parent, filename: base)
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

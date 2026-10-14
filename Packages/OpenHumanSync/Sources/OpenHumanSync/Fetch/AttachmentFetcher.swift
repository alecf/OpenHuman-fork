import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public struct AttachmentFetcher: Sendable {
    public static let maxBytes = 30 * 1024 * 1024

    public enum Failure: Error, Equatable, Sendable {
        case notFound
        case tooLarge(Int)
        case noContent
    }

    public let account: AccountID
    let store: any SyncStore
    let api: any GmailAPI
    let directory: URL
    let log = Log(.sync)

    public init(account: AccountID, store: any SyncStore, api: any GmailAPI, storeDirectory: URL) {
        self.account = account
        self.store = store
        self.api = api
        self.directory = storeDirectory
    }

    public func attachmentFile(message: GmailMessageID, attachment aid: Int64,
                               priority: RequestPriority = .interactive) async throws -> URL {
        guard let stored = try store.message(account: account, gmailMessageID: message),
              let item = stored.attachments.first(where: { $0.id == aid }) else { throw Failure.notFound }
        if let cached = item.localFileURL, FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard item.size <= Self.maxBytes else { throw Failure.tooLarge(item.size) }

        let full: GmailMessage
        do {
            full = try await api.getMessage(id: message.rawValue, format: .full, metadataHeaders: [], priority: priority)
        } catch GmailError.notFound {
            throw Failure.notFound
        }
        guard let part = full.payload.flatMap({ Self.part(item.partID, in: $0) }) else { throw Failure.notFound }
        let data: Data
        if let attachmentID = part.body?.attachmentId {
            if let declared = part.body?.size, declared > Self.maxBytes { throw Failure.tooLarge(declared) }
            do {
                data = try await api.getAttachment(messageID: message.rawValue, attachmentID: attachmentID)
            } catch GmailError.notFound {
                throw Failure.notFound
            }
        } else if let inline = part.body?.data, let decoded = Base64URL.decode(inline) {
            data = decoded
        } else {
            throw Failure.noContent
        }
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge(data.count) }

        let relative = Self.relativePath(account: account, message: message, partID: item.partID,
                                         filename: item.filename)
        let file = directory.appendingPathComponent(relative)
        try Self.write(data, to: file)
        try store.setAttachmentDownloaded(aid: aid, relativePath: relative)
        log.notice("account \(account.rawValue): attachment \(aid) cached (\(data.count) bytes)")
        return file
    }

    static func relativePath(account: AccountID, message: GmailMessageID, partID: String, filename: String) -> String {
        ["Attachments", String(account.rawValue), safeComponent(message.rawValue, fallback: "message"),
         safeComponent(partID, fallback: "part"), StoreLocation.sanitizedFilename(filename, partID: partID)]
            .joined(separator: "/")
    }

    static func safeComponent(_ raw: String, fallback: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")
        let cleaned = String(raw.filter { allowed.contains($0) }.drop { $0 == "." }.prefix(64))
        return cleaned.isEmpty ? fallback : cleaned
    }

    static func part(_ id: String, in root: GmailMessagePart) -> GmailMessagePart? {
        if root.partId == id { return root }
        for child in root.parts ?? [] {
            if let found = part(id, in: child) { return found }
        }
        return nil
    }

    static func write(_ data: Data, to file: URL) throws {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try setQuarantine(on: file)
    }

    static func setQuarantine(on file: URL, now: Date = Date()) throws {
        #if os(macOS)
        try FileQuarantine.write(FileQuarantine.value(now: now), to: file)
        #endif
    }
}

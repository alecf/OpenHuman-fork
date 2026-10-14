import Foundation
import MailModel
import MailRender
import OpenHumanCore

public struct ComposeTiming: Sendable {
    public var autosaveDelay: Duration
    public var discardWindow: Duration
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(autosaveDelay: Duration = .seconds(1), discardWindow: Duration = .seconds(6),
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.autosaveDelay = autosaveDelay
        self.discardWindow = discardWindow
        self.now = now
        self.sleep = sleep
    }
}

public struct DraftRecoveryRecord: Codable, Hashable, Sendable {
    public var draftID: String
    public var version: Int
    public var document: RichTextDocument
    public var quotedText: String
    public var includeSignature: Bool

    public init(draftID: String, version: Int, document: RichTextDocument, quotedText: String, includeSignature: Bool) {
        self.draftID = draftID
        self.version = version
        self.document = document
        self.quotedText = quotedText
        self.includeSignature = includeSignature
    }
}

public protocol DraftRecoveryStoring: Sendable {
    func save(_ record: DraftRecoveryRecord)
    func load(_ draft: DraftKey, version: Int) -> DraftRecoveryRecord?
    func remove(_ draft: DraftKey)
}

public final class InMemoryDraftRecovery: DraftRecoveryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: DraftRecoveryRecord] = [:]

    public init() {}

    public func save(_ record: DraftRecoveryRecord) {
        lock.withLock { records[record.draftID] = record }
    }

    public func load(_ draft: DraftKey, version: Int) -> DraftRecoveryRecord? {
        lock.withLock {
            guard let record = records[draft.rawValue] else { return nil }
            guard record.version == version else {
                records[draft.rawValue] = nil
                return nil
            }
            return record
        }
    }

    public func remove(_ draft: DraftKey) {
        lock.withLock { records[draft.rawValue] = nil }
    }
}

public final class FileDraftRecovery: DraftRecoveryStoring, Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    func url(_ draftID: String) -> URL? {
        guard !draftID.isEmpty, draftID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return directory.appendingPathComponent(draftID, isDirectory: true).appendingPathComponent("draft.json")
    }

    public func save(_ record: DraftRecoveryRecord) {
        guard let url = url(record.draftID), let data = try? JSONEncoder().encode(record) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let temp = url.deletingLastPathComponent().appendingPathComponent(".draft.json.tmp")
            try data.write(to: temp, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            Log(.app).error("draft.json could not be written (\(String(describing: type(of: error))))")
        }
    }

    public func load(_ draft: DraftKey, version: Int) -> DraftRecoveryRecord? {
        guard let url = url(draft.rawValue), let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: data) else { return nil }
        guard record.version == version, record.draftID == draft.rawValue else {
            remove(draft)
            return nil
        }
        return record
    }

    public func remove(_ draft: DraftKey) {
        guard let url = url(draft.rawValue) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

public protocol AttachmentStaging: Sendable {
    func stage(_ file: URL, draft: String) throws -> DraftAttachmentInfo
    func fileURL(forLocalPath localPath: String) -> URL?
}

extension AttachmentStaging {
    public func fileURL(forLocalPath localPath: String) -> URL? { nil }
}

public struct DirectoryAttachmentStaging: AttachmentStaging {
    public let directory: URL
    public let relativePrefix: String

    public init(directory: URL, relativePrefix: String = "Drafts") {
        self.directory = directory
        self.relativePrefix = relativePrefix
    }

    public func stage(_ file: URL, draft: String) throws -> DraftAttachmentInfo {
        let fm = FileManager.default
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .nameKey])
        guard values.isDirectory != true else { throw MailPortError.unsupported("attaching a folder") }
        let folder = directory.appendingPathComponent(draft, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = Self.safeName(values.name ?? file.lastPathComponent)
        var target = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try fm.copyItem(at: file, to: target)
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? values.fileSize ?? 0
        return DraftAttachmentInfo(localPath: "\(relativePrefix)/\(draft)/\(target.lastPathComponent)",
                                   filename: target.lastPathComponent, mimeType: Self.mimeType(for: target),
                                   size: size)
    }

    public func fileURL(forLocalPath localPath: String) -> URL? {
        let prefix = relativePrefix + "/"
        guard localPath.hasPrefix(prefix) else { return nil }
        let parts = localPath.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return directory.appendingPathComponent(String(parts[0]), isDirectory: true).appendingPathComponent(String(parts[1]))
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { $0 == "/" || $0 == ":" || $0.value < 0x20 ? "_" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "attachment" + trimmed : trimmed
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "txt": "text/plain"
        case "csv": "text/csv"
        case "html", "htm": "text/html"
        case "zip": "application/zip"
        case "ics": "text/calendar"
        case "doc": "application/msword"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": "application/vnd.ms-excel"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": "application/vnd.ms-powerpoint"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: "application/octet-stream"
        }
    }
}

public enum AttachmentLimits {
    public static let maxTotalBytes = 25 * 1024 * 1024
}

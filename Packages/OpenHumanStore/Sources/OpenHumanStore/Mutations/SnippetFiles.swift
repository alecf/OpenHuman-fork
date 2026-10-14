import Foundation
import GRDB
import OpenHumanCore

enum SnippetFiles {
    static let orphanGrace: TimeInterval = 3600

    private struct WireAttachment: Codable {
        var hash: String
        var filename: String
        var mimeType: String
        var size: Int
    }

    static func encode(_ list: [SnippetAttachment]) -> String {
        guard !list.isEmpty else { return "[]" }
        let wire = list.map { WireAttachment(hash: $0.contentHash, filename: $0.filename, mimeType: $0.mimeType, size: $0.size) }
        return (try? StoreJSON.encoder.encode(wire)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func decode(_ json: String) -> [SnippetAttachment] {
        guard let data = json.data(using: .utf8), let wire = try? JSONDecoder().decode([WireAttachment].self, from: data)
        else { return [] }
        return wire.map { SnippetAttachment(contentHash: $0.hash, filename: $0.filename, mimeType: $0.mimeType, size: $0.size) }
    }

    static func isValidHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && StoreLocation.sanitizedFilename(name, partID: "0") == name
    }

    static func referencedKeys(in db: Database) throws -> Set<String> {
        var keys = Set<String>()
        for json in try String.fetchAll(db, sql: "SELECT attachments_json FROM snippets WHERE attachments_json <> '[]'") {
            for attachment in decode(json) { keys.insert(key(attachment)) }
        }
        return keys
    }

    static func key(_ attachment: SnippetAttachment) -> String { attachment.contentHash + "/" + attachment.filename }

    static func validate(_ list: [SnippetAttachment]) throws {
        guard list.count <= SnippetAttachmentLimits.maxFiles else { throw StoreError.limitExceeded("snippet attachments") }
        var total = 0
        for attachment in list {
            guard isValidHash(attachment.contentHash), isValidName(attachment.filename), attachment.size >= 0 else {
                throw StoreError.conflict("snippet attachment reference is malformed")
            }
            guard attachment.size <= SnippetAttachmentLimits.maxFileBytes else {
                throw StoreError.limitExceeded("snippet attachment size")
            }
            total += attachment.size
        }
        guard total <= SnippetAttachmentLimits.maxTotalBytes else { throw StoreError.limitExceeded("snippet attachments size") }
    }
}

extension StoreLocation {
    public func snippetFileURL(_ attachment: SnippetAttachment) -> URL? {
        guard SnippetFiles.isValidHash(attachment.contentHash), SnippetFiles.isValidName(attachment.filename) else { return nil }
        return snippetFilesDirectory.appendingPathComponent(attachment.contentHash, isDirectory: true)
            .appendingPathComponent(attachment.filename)
    }
}

extension MailStore {
    public func storeSnippetAttachment(data: Data, filename: String, mimeType: String) throws -> SnippetAttachment {
        if readOnly { throw StoreError.readOnly }
        guard data.count <= SnippetAttachmentLimits.maxFileBytes else { throw StoreError.limitExceeded("snippet attachment size") }
        let name = StoreLocation.sanitizedFilename(filename, partID: "snippet")
        let type = mimeType.trimmingCharacters(in: .whitespaces)
        let attachment = SnippetAttachment(contentHash: SHA256Digest.hex(data), filename: name,
                                           mimeType: type.isEmpty ? "application/octet-stream" : type, size: data.count)
        guard let url = location.snippetFileURL(attachment) else { throw StoreError.conflict("snippet attachment name") }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                for dir in [location.snippetFilesDirectory, url.deletingLastPathComponent()] {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }
                try data.write(to: url, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Log(.store).error("snippet file could not be written (\(storeLogCode(error)))")
                throw StoreError.integrity("snippet file could not be written")
            }
        }
        return attachment
    }

    public func storeSnippetAttachment(from file: URL, filename: String? = nil, mimeType: String) throws -> SnippetAttachment {
        if readOnly { throw StoreError.readOnly }
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { throw StoreError.conflict("a folder can't be a snippet attachment") }
        if let size = values?.fileSize, size > SnippetAttachmentLimits.maxFileBytes {
            throw StoreError.limitExceeded("snippet attachment size")
        }
        let data: Data
        do { data = try Data(contentsOf: file, options: .mappedIfSafe) } catch { throw StoreError.notFound("snippet attachment file") }
        return try storeSnippetAttachment(data: data, filename: filename ?? file.lastPathComponent, mimeType: mimeType)
    }

    func requireSnippetFiles(_ list: [SnippetAttachment]) throws {
        try SnippetFiles.validate(list)
        for attachment in list {
            guard let url = location.snippetFileURL(attachment), FileManager.default.fileExists(atPath: url.path) else {
                throw StoreError.notFound("snippet attachment file")
            }
        }
    }

    func removeUnreferencedSnippetFiles(_ candidates: [SnippetAttachment], now: Date = Date()) {
        let fm = FileManager.default
        let root = location.snippetFilesDirectory
        guard fm.fileExists(atPath: root.path), let referenced = try? read({ try SnippetFiles.referencedKeys(in: $0) }) else { return }
        for attachment in candidates where !referenced.contains(SnippetFiles.key(attachment)) {
            guard let url = location.snippetFileURL(attachment) else { continue }
            try? fm.removeItem(at: url)
            removeIfEmpty(url.deletingLastPathComponent())
        }
        for hash in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where SnippetFiles.isValidHash(hash) {
            let dir = root.appendingPathComponent(hash, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !referenced.contains(hash + "/" + name) {
                let file = dir.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? now
                if now.timeIntervalSince(modified) >= SnippetFiles.orphanGrace { try? fm.removeItem(at: file) }
            }
            removeIfEmpty(dir)
        }
    }

    private func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        if let left = try? fm.contentsOfDirectory(atPath: dir.path), left.isEmpty { try? fm.removeItem(at: dir) }
    }
}

import Crypto
import Foundation
import OpenHumanCore

public struct WriteAllowlist: Sendable, Hashable, Codable {
    public static let fileName = "safe-mode-allowlist.json"
    public static let currentVersion = 1

    public var version: Int
    public var accountHash: String
    public var threadIDs: Set<String>
    public var messageIDs: Set<String>
    public var draftIDs: Set<String>
    public var labels: [String: String]

    public init(accountEmail: String) {
        self.init(accountHash: Self.accountHash(accountEmail))
    }

    init(accountHash: String, threadIDs: Set<String> = [], messageIDs: Set<String> = [], draftIDs: Set<String> = [],
         labels: [String: String] = [:]) {
        version = Self.currentVersion
        self.accountHash = accountHash
        self.threadIDs = threadIDs
        self.messageIDs = messageIDs
        self.draftIDs = draftIDs
        self.labels = labels
    }

    public static func accountHash(_ email: String) -> String {
        SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var testLabelID: String? {
        labels.filter { $0.value == OHGmailLabels.test }.keys.sorted().first
    }

    public func containsThread(_ id: String) -> Bool { threadIDs.contains(id) }
    public func containsMessage(_ id: String) -> Bool { messageIDs.contains(id) }
    public func containsDraft(_ id: String) -> Bool { draftIDs.contains(id) }
    public func isOpenHumanLabel(_ id: String) -> Bool { labels[id] != nil }

    public var isEmpty: Bool { threadIDs.isEmpty && messageIDs.isEmpty && draftIDs.isEmpty && labels.isEmpty }

    private enum CodingKeys: String, CodingKey { case version, accountHash, threadIDs, messageIDs, draftIDs, labels }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        accountHash = try c.decode(String.self, forKey: .accountHash)
        threadIDs = Set(try c.decode([String].self, forKey: .threadIDs))
        messageIDs = Set(try c.decode([String].self, forKey: .messageIDs))
        draftIDs = Set(try c.decode([String].self, forKey: .draftIDs))
        labels = try c.decode([String: String].self, forKey: .labels)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(accountHash, forKey: .accountHash)
        try c.encode(threadIDs.sorted(), forKey: .threadIDs)
        try c.encode(messageIDs.sorted(), forKey: .messageIDs)
        try c.encode(draftIDs.sorted(), forKey: .draftIDs)
        try c.encode(labels, forKey: .labels)
    }
}

struct AllowlistLearning: Sendable, Equatable {
    var threadIDs: Set<String> = []
    var messageIDs: Set<String> = []
    var draftIDs: Set<String> = []
    var labelsSeen: [String: String] = [:]
    var labelsNotOurs: Set<String> = []

    var isEmpty: Bool {
        threadIDs.isEmpty && messageIDs.isEmpty && draftIDs.isEmpty && labelsSeen.isEmpty && labelsNotOurs.isEmpty
    }
}

public enum WriteAllowlistError: Error, Equatable, Sendable, CustomStringConvertible {
    case otherAccount
    case notARegularFile
    case malformed(String)
    case unsupportedVersion(Int)
    case io(String)

    public var description: String {
        switch self {
        case .otherAccount: return "safe-mode allowlist belongs to another account"
        case .notARegularFile: return "safe-mode allowlist is not a regular file"
        case .malformed(let why): return "safe-mode allowlist is malformed: \(why)"
        case .unsupportedVersion(let v): return "safe-mode allowlist version \(v) is not supported"
        case .io(let why): return "safe-mode allowlist I/O failed: \(why)"
        }
    }
}

public actor WriteAllowlistStore {
    public nonisolated let fileURL: URL?
    private var current: WriteAllowlist

    public init(accountEmail: String) {
        fileURL = nil
        current = WriteAllowlist(accountEmail: accountEmail)
    }

    init(seed: WriteAllowlist) {
        fileURL = nil
        current = seed
    }

    public init(fileURL: URL, accountEmail: String) throws {
        self.fileURL = fileURL
        current = try Self.load(fileURL, accountHash: WriteAllowlist.accountHash(accountEmail))
    }

    public static func open(storeDirectory: URL, accountEmail: String) throws -> WriteAllowlistStore {
        try WriteAllowlistStore(fileURL: storeDirectory.appendingPathComponent(WriteAllowlist.fileName),
                                accountEmail: accountEmail)
    }

    public var snapshot: WriteAllowlist { current }

    public var counts: (threads: Int, messages: Int, drafts: Int, labels: Int) {
        (current.threadIDs.count, current.messageIDs.count, current.draftIDs.count, current.labels.count)
    }

    func apply(_ learning: AllowlistLearning) {
        guard !learning.isEmpty else { return }
        var next = current
        next.threadIDs.formUnion(learning.threadIDs)
        next.messageIDs.formUnion(learning.messageIDs)
        next.draftIDs.formUnion(learning.draftIDs)
        for id in learning.labelsNotOurs { next.labels.removeValue(forKey: id) }
        next.labels.merge(learning.labelsSeen) { _, new in new }
        guard next != current else { return }
        current = next
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(current)
            try SecureFile.ensureDirectory(fileURL.deletingLastPathComponent(), mode: 0o700, tighten: false)
            try SecureFile.writeAtomically(data, to: fileURL, mode: 0o600)
        } catch {
            Log(.gmail).error("safe mode allowlist save failed (\(type(of: error))); rights added since the "
                              + "last save are lost on relaunch")
        }
    }

    static func load(_ url: URL, accountHash: String) throws -> WriteAllowlist {
        let (kind, mode) = SecureFile.inspect(url)
        switch kind {
        case .missing: return WriteAllowlist(accountHash: accountHash)
        case .other: throw WriteAllowlistError.notARegularFile
        case .regularFile: break
        }
        if (mode & 0o077) != 0, chmod(url.path, 0o600) != 0 {
            throw WriteAllowlistError.io("chmod (errno \(errno))")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw WriteAllowlistError.io("read") }
        let decoded: WriteAllowlist
        do {
            decoded = try JSONDecoder().decode(WriteAllowlist.self, from: data)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            throw WriteAllowlistError.malformed("invalid JSON")
        } catch let error as DecodingError {
            throw WriteAllowlistError.malformed(GmailClient.describe(error))
        } catch {
            throw WriteAllowlistError.malformed("invalid JSON")
        }
        guard decoded.version == WriteAllowlist.currentVersion else {
            throw WriteAllowlistError.unsupportedVersion(decoded.version)
        }
        guard decoded.accountHash == accountHash else { throw WriteAllowlistError.otherAccount }
        let ids = decoded.threadIDs.union(decoded.messageIDs).union(decoded.draftIDs).union(decoded.labels.keys)
        guard ids.allSatisfy(WriteRules.isPlainID) else { throw WriteAllowlistError.malformed("an id is not a Gmail id") }
        guard decoded.labels.values.allSatisfy({ $0.hasPrefix(WriteRules.labelPrefix) }) else {
            throw WriteAllowlistError.malformed("a label is not an OpenHuman label")
        }
        return decoded
    }
}

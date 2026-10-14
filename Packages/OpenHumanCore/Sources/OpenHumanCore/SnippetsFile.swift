import Foundation

public struct SnippetsFile: Codable, Sendable, Equatable {
    public static let format = "openhuman-snippets"
    public static let currentVersion = 2
    public static let maxSnippets = 500

    public struct Variable: Codable, Sendable, Equatable {
        public var name: String
        public var defaultValue: String?

        public init(name: String, defaultValue: String? = nil) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }

    public struct File: Codable, Sendable, Equatable {
        public var filename: String
        public var mimeType: String
        public var size: Int
        public var contentHash: String?
        public var data: Data

        public init(filename: String, mimeType: String, size: Int, contentHash: String? = nil, data: Data) {
            self.filename = filename
            self.mimeType = mimeType
            self.size = size
            self.contentHash = contentHash
            self.data = data
        }
    }

    public struct Snippet: Codable, Sendable, Equatable {
        public var name: String
        public var shortcut: String?
        public var subject: String?
        public var bodyHTML: String
        public var variables: [Variable]
        public var to: [EmailAddress]?
        public var cc: [EmailAddress]?
        public var bcc: [EmailAddress]?
        public var files: [File]?

        public init(name: String, shortcut: String?, subject: String?, bodyHTML: String, variables: [Variable],
                    to: [EmailAddress]? = nil, cc: [EmailAddress]? = nil, bcc: [EmailAddress]? = nil, files: [File]? = nil) {
            self.name = name
            self.shortcut = shortcut
            self.subject = subject
            self.bodyHTML = bodyHTML
            self.variables = variables
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.files = files
        }

        public var hasRecipients: Bool { !((to ?? []).isEmpty && (cc ?? []).isEmpty && (bcc ?? []).isEmpty) }

        public var hasVersion2Content: Bool { hasRecipients || !(files ?? []).isEmpty }
    }

    public enum ReadError: Error, Equatable {
        case notASnippetsFile
        case newerVersion
    }

    public var format: String
    public var version: Int
    public var snippets: [Snippet]

    public init(snippets: [Snippet]) {
        format = Self.format
        version = snippets.contains(where: \.hasVersion2Content) ? Self.currentVersion : 1
        self.snippets = snippets
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws(ReadError) -> SnippetsFile {
        guard let file = try? JSONDecoder().decode(SnippetsFile.self, from: data), file.format == format else {
            throw .notASnippetsFile
        }
        guard file.version <= currentVersion else { throw .newerVersion }
        return file
    }

    public var usableSnippets: [Snippet] {
        var seen = Set<String>()
        var out: [Snippet] = []
        for snippet in snippets where out.count < Self.maxSnippets {
            let name = snippet.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !snippet.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(name.lowercased()).inserted else { continue }
            var kept = snippet
            kept.name = name
            out.append(kept)
        }
        return out
    }

    public static func acceptedFiles(_ files: [File], maxFiles: Int, maxFileBytes: Int, maxTotalBytes: Int) -> [File] {
        var out: [File] = []
        var total = 0
        for file in files where out.count < maxFiles {
            guard file.data.count == file.size, file.size <= maxFileBytes, total + file.size <= maxTotalBytes,
                  !file.filename.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            total += file.size
            out.append(file)
        }
        return out
    }
}

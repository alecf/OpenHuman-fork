import Foundation

public struct ModelManifest: Codable, Sendable, Hashable, Identifiable {
    public enum Format: String, Codable, Sendable, Hashable {
        case mlx
        case coreai
        case coreml
    }

    public struct File: Codable, Sendable, Hashable {
        public let path: String
        public let url: URL
        public let sizeBytes: Int64
        public let sha256: String

        public init(path: String, url: URL, sizeBytes: Int64, sha256: String) {
            self.path = path
            self.url = url
            self.sizeBytes = sizeBytes
            self.sha256 = sha256.lowercased()
        }
    }

    public let id: String
    public let displayName: String
    public let sourceURL: URL
    public let revision: String
    public let files: [File]
    public let license: String
    public let format: Format
    public let declaredContextTokens: Int?

    public init(
        id: String, displayName: String, sourceURL: URL, revision: String, files: [File], license: String,
        format: Format, declaredContextTokens: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.revision = revision
        self.files = files
        self.license = license
        self.format = format
        self.declaredContextTokens = declaredContextTokens
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    public func validate() throws {
        func fail(_ message: String) -> ModelStoreError { .invalidManifest(message) }
        guard Self.isSafeComponent(id) else { throw fail("bad model id") }
        guard Self.isSafeComponent(revision) else { throw fail("bad revision") }
        guard !files.isEmpty else { throw fail("no files") }
        var seen = Set<String>()
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.isEmpty, !file.path.hasPrefix("/"), !file.path.contains("\0"),
                !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { throw fail("unsafe file path") }
            guard !file.path.hasSuffix(".partial"), file.path != ModelStore.readyMarkerName else { throw fail("reserved file name") }
            guard seen.insert(file.path).inserted else { throw fail("duplicate file path") }
            guard file.url.scheme?.lowercased() == "https", file.url.host() != nil else { throw fail("download URLs must be https") }
            guard file.sizeBytes > 0 else { throw fail("empty file") }
            guard file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw fail("bad SHA-256")
            }
        }
    }

    static func isSafeComponent(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && !text.hasPrefix(".")
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}

public enum ModelStoreError: Error, Sendable, Hashable {
    case invalidManifest(String)
    case sizeNotConfirmed(expected: Int64, confirmed: Int64)
    case tooLarge(bytes: Int64, cap: Int64)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case checksumMismatch(file: String)
    case sizeMismatch(file: String)
    case transport(String)
    case alreadyDownloading
    case notInstalled
}

public struct DownloadProgress: Sendable, Hashable {
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }

    public init(bytesDone: Int64, bytesTotal: Int64) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }
}

public enum DownloadState: Sendable, Hashable {
    case idle
    case downloading(DownloadProgress)
    case verifying(file: String)
    case ready(URL)
    case failed(ModelStoreError)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .ready, .failed, .cancelled: return true
        case .idle, .downloading, .verifying: return false
        }
    }
}

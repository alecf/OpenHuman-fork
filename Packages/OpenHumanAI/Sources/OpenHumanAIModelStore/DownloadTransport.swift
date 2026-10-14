import Foundation

public protocol DownloadTransport: Sendable {
    func fetch(
        url: URL, to destination: URL, resumeFrom offset: Int64, maxBytes: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws
}

public struct URLSessionDownloadTransport: DownloadTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func fetch(
        url: URL, to destination: URL, resumeFrom offset: Int64, maxBytes: Int64,
        progress: @Sendable (Int64) -> Void
    ) async throws {
        guard url.scheme?.lowercased() == "https" else { throw ModelStoreError.transport("not https") }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelStoreError.transport("not an HTTP response") }

        var written: Int64
        let append: Bool
        switch http.statusCode {
        case 206: (written, append) = (offset, true)
        case 200: (written, append) = (0, false)
        default: throw ModelStoreError.transport("HTTP \(http.statusCode)")
        }
        if http.expectedContentLength > 0, written + http.expectedContentLength > maxBytes {
            throw ModelStoreError.tooLarge(bytes: written + http.expectedContentLength, cap: maxBytes)
        }
        if !append { FileManager.default.createFile(atPath: destination.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if append { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }

        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                written += Int64(buffer.count)
                if written > maxBytes { throw ModelStoreError.tooLarge(bytes: written, cap: maxBytes) }
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(written)
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            written += Int64(buffer.count)
            if written > maxBytes { throw ModelStoreError.tooLarge(bytes: written, cap: maxBytes) }
            try handle.write(contentsOf: buffer)
        }
        progress(written)
    }
}

import Foundation

struct BatchPartRequest: Sendable, Hashable {
    var contentID: String
    var target: String
}

struct BatchPartResponse: Sendable, Hashable {
    var contentID: String?
    var status: Int
    var headers: [String: String]
    var body: Data
}

enum BatchCodec {
    static let endpoint = URL(string: "https://gmail.googleapis.com/batch/gmail/v1")!

    static func makeBoundary() -> String {
        "batch_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func contentType(boundary: String) -> String { "multipart/mixed; boundary=\(boundary)" }

    static func body(parts: [BatchPartRequest], boundary: String) -> Data {
        var out = Data()
        for part in parts {
            out.append(Data("--\(boundary)\r\n".utf8))
            out.append(Data("Content-Type: application/http\r\nContent-ID: <\(part.contentID)>\r\n\r\n".utf8))
            out.append(Data("GET \(part.target) HTTP/1.1\r\n\r\n".utf8))
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    static func target(for url: URL) -> String {
        var target = url.path(percentEncoded: true)
        if let query = url.query(percentEncoded: true), !query.isEmpty { target += "?" + query }
        return target
    }

    static func boundary(fromContentType contentType: String) -> String? {
        let pieces = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let kind = pieces.first?.lowercased(), kind.hasPrefix("multipart/") else { return nil }
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            guard piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            var value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func parse(contentType: String?, body: Data) -> [BatchPartResponse]? {
        let bytes = [UInt8](body)
        let boundary = contentType.flatMap(boundary(fromContentType:)) ?? sniffBoundary(bytes)
        guard let boundary else { return nil }
        let delimiter = Array("--\(boundary)".utf8)
        let close = delimiter + [0x2D, 0x2D]

        var ranges: [Range<Int>] = []
        var partStart: Int?
        var closed = false
        var lineStart = 0
        while lineStart < bytes.count {
            var newline = lineStart
            while newline < bytes.count, bytes[newline] != 0x0A { newline += 1 }
            var end = newline
            while end > lineStart, [0x0D, 0x20, 0x09].contains(bytes[end - 1]) { end -= 1 }
            let line = bytes[lineStart..<end]
            let isClose = line.elementsEqual(close)
            if isClose || line.elementsEqual(delimiter) {
                if let start = partStart { ranges.append(start..<lineStart) }
                partStart = isClose ? nil : min(newline + 1, bytes.count)
                if isClose { closed = true; break }
            }
            lineStart = newline + 1
        }
        if let start = partStart, !closed { ranges.append(start..<bytes.count) }
        guard !ranges.isEmpty || closed else { return nil }
        return ranges.compactMap { parsePart(bytes, trimTerminator(bytes, $0)) }
    }

    private static func sniffBoundary(_ bytes: [UInt8]) -> String? {
        var lineStart = 0
        while lineStart < bytes.count {
            var newline = lineStart
            while newline < bytes.count, bytes[newline] != 0x0A { newline += 1 }
            let line = String(decoding: bytes[lineStart..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("--"), line.count > 2 {
                return line.hasSuffix("--") && line.count > 4 ? String(line.dropFirst(2).dropLast(2)) : String(line.dropFirst(2))
            }
            if !line.isEmpty { return nil }
            lineStart = newline + 1
        }
        return nil
    }

    private static func trimTerminator(_ bytes: [UInt8], _ range: Range<Int>) -> Range<Int> {
        var end = range.upperBound
        if end > range.lowerBound, bytes[end - 1] == 0x0A { end -= 1 }
        if end > range.lowerBound, bytes[end - 1] == 0x0D { end -= 1 }
        return range.lowerBound..<end
    }

    private static func head(_ bytes: [UInt8], _ range: Range<Int>) -> (lines: [String], rest: Range<Int>) {
        var lines: [String] = []
        var lineStart = range.lowerBound
        while lineStart < range.upperBound {
            var newline = lineStart
            while newline < range.upperBound, bytes[newline] != 0x0A { newline += 1 }
            var end = newline
            if end > lineStart, bytes[end - 1] == 0x0D { end -= 1 }
            if end == lineStart { return (lines, min(newline + 1, range.upperBound)..<range.upperBound) }
            lines.append(String(decoding: bytes[lineStart..<end], as: UTF8.self))
            lineStart = newline + 1
        }
        return (lines, range.upperBound..<range.upperBound)
    }

    private static func headers(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { continue }
            out[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private static func parsePart(_ bytes: [UInt8], _ range: Range<Int>) -> BatchPartResponse? {
        var range = range
        while range.lowerBound < range.upperBound, bytes[range.lowerBound] == 0x0A || bytes[range.lowerBound] == 0x0D {
            range = (range.lowerBound + 1)..<range.upperBound
        }
        let outer = head(bytes, range)
        let outerHeaders = headers(outer.lines)
        var inner = outer.rest
        while inner.lowerBound < inner.upperBound, bytes[inner.lowerBound] == 0x0A || bytes[inner.lowerBound] == 0x0D {
            inner = (inner.lowerBound + 1)..<inner.upperBound
        }
        let inside = head(bytes, inner)
        guard let statusLine = inside.lines.first else { return nil }
        let words = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, words[0].hasPrefix("HTTP/"), let status = Int(words[1]) else { return nil }
        let innerHeaders = headers(Array(inside.lines.dropFirst()))
        var body = inside.rest
        if let length = innerHeaders["content-length"].flatMap({ Int($0) }), length >= 0, length < body.count {
            body = body.lowerBound..<(body.lowerBound + length)
        }
        return BatchPartResponse(contentID: outerHeaders["content-id"].map(normalize), status: status,
                                 headers: innerHeaders, body: Data(bytes[body]))
    }

    static func normalize(_ contentID: String) -> String {
        var id = contentID.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("<"), id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
        if id.hasPrefix("response-") { id = String(id.dropFirst("response-".count)) }
        return id
    }
}

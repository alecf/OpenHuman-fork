import Foundation

struct MediaType: Equatable {
    var type: String
    var parameters: [String: String]

    init?(_ value: String) {
        let pieces = value.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = pieces.first, !first.isEmpty, first.contains("/"), !first.contains(" ") else { return nil }
        type = first.lowercased()
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() where !piece.isEmpty {
            guard let eq = piece.firstIndex(of: "=") else { return nil }
            let name = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            guard !name.isEmpty, parameters[name] == nil else { return nil }
            parameters[name] = v
        }
        self.parameters = parameters
    }
}

struct Upload {
    var metadata: Data
    var message: Data

    struct Refusal: Error, Equatable, CustomStringConvertible {
        var text: String
        init(_ text: String) { self.text = text }
        var description: String { text }
    }

    static func parse(_ request: HTTPRequest) -> Result<Upload, Refusal> {
        guard let contentType = ReadOnlyTransport.header("content-type", in: request.headers),
              let media = MediaType(contentType), media.type == "multipart/related",
              let boundary = media.parameters["boundary"], !boundary.isEmpty, boundary.utf8.count <= 70 else {
            return .failure(.init("body is not multipart/related with a boundary"))
        }
        guard let body = request.body, !body.isEmpty else { return .failure(.init("empty body")) }
        let bytes = [UInt8](body)
        let open = Array("--\(boundary)\r\n".utf8)
        guard bytes.starts(with: open) else { return .failure(.init("body does not start with the boundary")) }
        let delimiter = Array("\r\n--\(boundary)".utf8)
        let hits = occurrences(of: delimiter, in: bytes, from: open.count)
        guard hits.count == 2 else { return .failure(.init("expected exactly two parts and the boundary nowhere else")) }
        let separatorEnd = hits[0] + delimiter.count
        guard bytes[separatorEnd...].starts(with: Array("\r\n".utf8)) else {
            return .failure(.init("malformed part delimiter"))
        }
        let closeEnd = hits[1] + delimiter.count
        let tail = Array(bytes[closeEnd...])
        guard tail == Array("--".utf8) || tail == Array("--\r\n".utf8) else {
            return .failure(.init("content after the close delimiter, or no close delimiter"))
        }
        let marker = Array("--\(boundary)".utf8)
        guard occurrences(of: marker, in: bytes, from: 0).count == 3 else {
            return .failure(.init("the boundary occurs inside a part"))
        }
        let first = Array(bytes[open.count..<hits[0]])
        let second = Array(bytes[(separatorEnd + 2)..<hits[1]])
        switch (part(first, expecting: "application/json"), part(second, expecting: "message/rfc822")) {
        case (.success(let meta), .success(let message)):
            return .success(Upload(metadata: Data(meta), message: Data(message)))
        case (.failure(let reason), _): return .failure(.init("metadata part: \(reason.text)"))
        case (_, .failure(let reason)): return .failure(.init("message part: \(reason.text)"))
        }
    }

    private static func part(_ bytes: [UInt8], expecting type: String) -> Result<[UInt8], Refusal> {
        let separator = Array("\r\n\r\n".utf8)
        guard let end = occurrences(of: separator, in: bytes, from: 0).first else {
            return .failure(.init("no blank line after the part headers"))
        }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        var contentType: MediaType?
        for line in head.components(separatedBy: "\r\n") {
            guard let first = line.first, first != " ", first != "\t", let colon = line.firstIndex(of: ":") else {
                return .failure(.init("malformed part header"))
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-type":
                guard contentType == nil, let media = MediaType(value) else {
                    return .failure(.init("repeated or malformed Content-Type"))
                }
                contentType = media
            case "content-transfer-encoding":
                guard ["7bit", "8bit", "binary"].contains(value.lowercased()) else {
                    return .failure(.init("Content-Transfer-Encoding cannot be inspected"))
                }
            default:
                return .failure(.init("part header \(isPlainName(name) ? name : "<non-id>") is not allowed"))
            }
        }
        guard contentType?.type == type else { return .failure(.init("Content-Type is not \(type)")) }
        return .success(Array(bytes[(end + separator.count)...]))
    }

    private static func isPlainName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
        }
    }

    static func occurrences(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var out: [Int] = []
        var i = start
        let last = haystack.count - needle.count
        let first = needle[0]
        while i <= last {
            if haystack[i] == first, haystack[i..<(i + needle.count)].elementsEqual(needle) {
                out.append(i)
                i += needle.count
            } else {
                i += 1
            }
        }
        return out
    }
}

import Foundation
import OpenHumanCore

public struct ReadOnlyTransport: HTTPTransport {
    private let wrapped: any HTTPTransport

    public init(wrapping transport: any HTTPTransport) {
        wrapped = transport
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if let reason = Self.refusalReason(for: request) {
            let summary = Self.summary(of: request)
            Log(.gmail).notice("safe mode read-only refused \(Self.redactingAddresses(summary)): \(reason)")
            throw TransportError.blockedBySafeMode(summary)
        }
        return try await wrapped.send(request)
    }

    public static func refusalReason(for request: HTTPRequest) -> String? {
        if let header = methodOverrideHeader(in: request.headers) { return "method override header \(header)" }
        if let name = methodOverrideQueryName(in: request.url) { return "method override query parameter \(name)" }
        switch request.method {
        case "GET":
            if let body = request.body, !body.isEmpty { return "GET with a body" }
            return nil
        case "POST" where isBatchEndpoint(request.url):
            return BatchInspector.refusalReason(contentType: header("content-type", in: request.headers),
                                                body: request.body)
        default:
            return "method \(request.method.isEmpty ? "<empty>" : request.method) is not GET"
        }
    }

    static func summary(of request: HTTPRequest) -> String {
        let path = request.url.path(percentEncoded: true)
        return "\(request.method) \(path.isEmpty ? "/" : path)"
    }

    static func redactingAddresses(_ summary: String) -> String {
        summary.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.contains("@") || $0.lowercased().contains("%40") ? "<redacted>" : String($0) }
            .joined(separator: "/")
    }

    static func isBatchEndpoint(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: true).lowercased()
        return path == "/batch" || path.hasPrefix("/batch/")
    }

    static let overrideHeaders: Set<String> = ["x-http-method-override", "x-http-method", "x-method-override"]
    static let overrideQueryNames: Set<String> = ["$httpmethod", "httpmethod", "_method", "x-http-method-override"]

    static func methodOverrideHeader(in headers: [String: String]) -> String? {
        headers.keys.first { overrideHeaders.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }
    }

    static func methodOverrideQueryName(in url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { overrideQueryNames.contains($0.name.lowercased()) }?.name
    }

    static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }
}

enum BatchInspector {
    static func refusalReason(contentType: String?, body: Data?) -> String? {
        guard let contentType, let boundary = boundary(fromContentType: contentType) else {
            return "batch without a multipart/mixed boundary"
        }
        guard let body, !body.isEmpty else { return "batch with an empty body" }
        guard let text = String(data: body, encoding: .isoLatin1) else { return "batch body unreadable" }
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }

        let delimiter = "--" + boundary
        let closeDelimiter = delimiter + "--"
        var parts: [[String]] = []
        var current: [String]?
        var closed = false
        for line in lines {
            let trimmed = trimTrailingWhitespace(line)
            if closed {
                if !trimmed.isEmpty { return "batch has content after the close delimiter" }
                continue
            }
            if trimmed == closeDelimiter {
                if let current { parts.append(current) }
                current = nil
                closed = true
            } else if trimmed == delimiter {
                if let current { parts.append(current) }
                current = []
            } else if current != nil {
                current!.append(line)
            } else if !trimmed.isEmpty {
                return "batch has content before the first boundary"
            }
        }
        guard closed else { return "batch without a close delimiter" }
        guard !parts.isEmpty else { return "batch without parts" }
        for (index, part) in parts.enumerated() {
            if let reason = refusalReason(part: part) { return "batch part \(index + 1): \(reason)" }
        }
        return nil
    }

    private static func refusalReason(part: [String]) -> String? {
        var index = 0
        var partContentType: String?
        while index < part.count, !part[index].isEmpty {
            guard let (name, value) = headerField(part[index]) else { return "malformed part header" }
            switch name {
            case "content-type": partContentType = value
            case "content-transfer-encoding":
                let encoding = value.lowercased()
                guard encoding == "binary" || encoding == "8bit" || encoding == "7bit" else {
                    return "content-transfer-encoding \(value) cannot be inspected"
                }
            default: break
            }
            index += 1
        }
        guard index < part.count else { return "part has no request" }
        guard let partContentType,
              partContentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
                == "application/http" else {
            return "part is not application/http"
        }
        while index < part.count, part[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        guard index < part.count else { return "part has no request line" }
        let requestLine = part[index]
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count == 2 || tokens.count == 3 else { return "malformed request line" }
        guard tokens[0] == "GET" else { return "inner method \(tokens[0].isEmpty ? "<empty>" : tokens[0]) is not GET" }
        guard tokens[1].hasPrefix("/") else { return "inner request target is not a path" }
        if tokens.count == 3, tokens[2] != "HTTP/1.1", tokens[2] != "HTTP/1.0" { return "malformed request line" }
        if let url = URL(string: "https://batch.invalid" + tokens[1]),
           let name = ReadOnlyTransport.methodOverrideQueryName(in: url) {
            return "inner method override query parameter \(name)"
        }
        index += 1
        while index < part.count, !part[index].isEmpty {
            guard let (name, _) = headerField(part[index]) else { return "malformed inner header" }
            if ReadOnlyTransport.overrideHeaders.contains(name) { return "inner method override header" }
            index += 1
        }
        while index < part.count {
            if !part[index].trimmingCharacters(in: .whitespaces).isEmpty { return "inner GET with a body" }
            index += 1
        }
        return nil
    }

    static func boundary(fromContentType contentType: String) -> String? {
        let pieces = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.first?.lowercased() == "multipart/mixed" else { return nil }
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "boundary" else { continue }
            var value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !value.isEmpty, value.count <= 70 else { return nil }
            return value
        }
        return nil
    }

    private static func headerField(_ line: String) -> (String, String)? {
        guard let first = line.first, first != " ", first != "\t", let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].lowercased()
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        return (name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func trimTrailingWhitespace(_ line: String) -> String {
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }
}

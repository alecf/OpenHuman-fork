import Foundation
import OpenHumanCore
import Synchronization

public struct DenyListTransport: HTTPTransport {
    private let wrapped: any HTTPTransport
    public let recipients: SendRecipientGate?

    public init(wrapping transport: any HTTPTransport, recipients: SendRecipientGate? = nil) {
        wrapped = transport
        self.recipients = recipients
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let summary = ReadOnlyTransport.summary(of: request)
        if let reason = Self.refusalReason(for: request) ?? recipients?.refusalReason(for: request) {
            Log(.gmail).notice("write mode refused \(ReadOnlyTransport.redactingAddresses(summary)): \(reason)")
            throw TransportError.blockedBySafeMode(summary)
        }
        let response = try await wrapped.send(request)
        if let recipients, (200..<300).contains(response.status) { recipients.learn(from: request, response: response) }
        return response
    }

    public static func refusalReason(for request: HTTPRequest) -> String? {
        let url = request.url
        guard url.scheme?.lowercased() == "https", url.host(percentEncoded: true)?.lowercased() == GmailClient.host,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else {
            return "only https://\(GmailClient.host) is allowed"
        }
        let path = url.path(percentEncoded: false)
        let parts = path.split(separator: "/").map { String($0) }
        if parts.contains(".") || parts.contains("..") { return "a `.` or `..` path segment is never allowed" }
        if let header = ReadOnlyTransport.methodOverrideHeader(in: request.headers) { return "method override header \(header)" }
        if let name = ReadOnlyTransport.methodOverrideQueryName(in: url) {
            return "method override query parameter \(name)"
        }
        let method = request.method.uppercased()
        if method == "POST", ReadOnlyTransport.isBatchEndpoint(url) {
            return ReadOnlyTransport.refusalReason(for: request).map { "batch with a write inside (\($0))" }
        }
        let resource = Self.resourcePath(path)
        if resource == nil, method != "GET" { return "only Gmail API resource paths can be written" }
        let rest = resource ?? parts.map { $0.lowercased() }
        let last = rest.last ?? ""
        if let first = rest.first, ["trash", "spam"].contains(first) { return "emptying trash or spam is never allowed" }
        if ["empty", "emptytrash", "emptyspam"].contains(last) { return "emptying trash or spam is never allowed" }
        if method == "DELETE" {
            if rest.count == 2, rest[0] == "drafts" { return nil }
            if rest.first == "labels" { return "deleting a label is never allowed" }
            return "permanent delete is never allowed"
        }
        if last == "batchdelete" || last == "delete" { return "permanent delete is never allowed" }
        if rest.first == "settings" || rest.contains(where: Self.settingsSegments.contains) {
            guard method == "GET" else { return "changing Gmail settings, filters, forwarding or send-as is never allowed" }
            return nil
        }
        if rest.first == "labels", method != "GET" {
            guard method == "POST", rest.count == 1 else { return "changing or deleting a label is never allowed" }
            return nil
        }
        if rest.first == "messages", last == "import" { return "importing mail is not allowed" }
        if rest.first == "watch" || rest.first == "stop" { return "push notification setup is not allowed" }
        if method != "GET", !["POST", "PUT", "PATCH"].contains(method) {
            return "method \(method.isEmpty ? "<empty>" : method) is not allowed"
        }
        return nil
    }

    static func resourcePath(_ decodedPath: String) -> [String]? {
        guard decodedPath.hasPrefix("/") else { return nil }
        let segments = decodedPath.dropFirst().lowercased().split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !segments.contains("") else { return nil }
        for prefix in [["gmail", "v1", "users"], ["upload", "gmail", "v1", "users"]]
        where segments.starts(with: prefix) && segments.count > prefix.count + 1 {
            return Array(segments.dropFirst(prefix.count + 1))
        }
        return nil
    }

    static let settingsSegments: Set<String> = ["filters", "forwardingaddresses", "autoforwarding", "delegates", "sendas",
                                                "vacation", "imap", "pop", "language", "cse", "smimeinfo"]
}

public final class SendRecipientGate: Sendable {
    public let limit: Int
    private struct State {
        var confirmed: Set<[String]> = []
        var drafts: [String: [String]?] = [:]
    }
    private let state = Mutex(State())

    public init(limit: Int = 20) {
        self.limit = max(1, limit)
    }

    public static func normalized(_ addresses: [String]) -> [String] {
        Array(Set(addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })).sorted()
    }

    public func confirm(_ addresses: [String]) {
        let set = Self.normalized(addresses)
        state.withLock { _ = $0.confirmed.insert(set) }
    }

    public func allows(_ addresses: [String]) -> Bool {
        let set = Self.normalized(addresses)
        return set.count <= limit || state.withLock { $0.confirmed.contains(set) }
    }

    func recipients(ofDraft id: String) -> [String]?? {
        state.withLock { $0.drafts[id] }
    }

    func refusalReason(for request: HTTPRequest) -> String? {
        guard request.method.uppercased() == "POST" else { return nil }
        let parts = request.url.path(percentEncoded: false).split(separator: "/").map { String($0) }
        let isMessageSend = parts.suffix(2) == ["messages", "send"]
        guard isMessageSend || parts.suffix(2) == ["drafts", "send"] else { return nil }
        let addresses: [String]
        if isMessageSend {
            guard let found = OutgoingRecipients.ofUpload(request) ?? OutgoingRecipients.ofJSONRaw(request.body) else {
                return "the recipients of this send could not be read"
            }
            addresses = found
        } else if let found = OutgoingRecipients.ofJSONRaw(request.body) {
            addresses = found
        } else {
            guard let id = OutgoingRecipients.draftID(request.body) else { return "drafts.send without a draft id" }
            switch recipients(ofDraft: id) {
            case .none: return nil
            case .some(.none): return "the recipients of this draft could not be read"
            case .some(.some(let known)): addresses = known
            }
        }
        guard !allows(addresses) else { return nil }
        return "\(Self.normalized(addresses).count) recipients is over the limit of \(limit) and was not confirmed"
    }

    func learn(from request: HTTPRequest, response: HTTPResponse) {
        let parts = request.url.path(percentEncoded: false).split(separator: "/").map { String($0) }
        guard parts.contains("upload"), parts.contains("drafts"), ["POST", "PUT"].contains(request.method.uppercased()),
              let id = OutgoingRecipients.draftID(response.body) else { return }
        let found = OutgoingRecipients.ofUpload(request)
        state.withLock { $0.drafts[id] = .some(found) }
    }
}

enum OutgoingRecipients {
    static func ofUpload(_ request: HTTPRequest) -> [String]? {
        guard case .success(let upload) = Upload.parse(request) else { return nil }
        return addresses(inRFC822: upload.message)
    }

    static func ofJSONRaw(_ body: Data?) -> [String]? {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let raw = (object["raw"] as? String) ?? ((object["message"] as? [String: Any])?["raw"] as? String)
        guard let raw, let data = base64URL(raw) else { return nil }
        return addresses(inRFC822: data)
    }

    static func draftID(_ body: Data?) -> String? {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    static func addresses(inRFC822 raw: Data) -> [String]? {
        let bytes = [UInt8](raw)
        let crlf = Upload.occurrences(of: Array("\r\n\r\n".utf8), in: bytes, from: 0).first
        let lf = Upload.occurrences(of: Array("\n\n".utf8), in: bytes, from: 0).first
        guard let end = [crlf, lf].compactMap({ $0 }).min() else { return nil }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        var fields: [(String, String)] = []
        for rawLine in head.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let first = line.first, first == " " || first == "\t" {
                guard !fields.isEmpty else { return nil }
                fields[fields.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            fields.append((line[..<colon].lowercased().trimmingCharacters(in: .whitespaces),
                           String(line[line.index(after: colon)...])))
        }
        return fields.filter { ["to", "cc", "bcc"].contains($0.0) }.flatMap { addresses(inField: $0.1) }
    }

    static func addresses(inField value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false, escaped = false, comment = 0, angle = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            let plain = !quoted && comment == 0
            switch character {
            case "\\" where quoted:
                escaped = true
                current.append(character)
            case "\"" where comment == 0:
                quoted.toggle()
                current.append(character)
            case "(" where !quoted:
                comment += 1
            case ")" where !quoted && comment > 0:
                comment -= 1
            case "<" where plain:
                angle = true
                current.append(character)
            case ">" where plain:
                angle = false
                current.append(character)
            case ",", ";":
                if plain && !angle {
                    tokens.append(current)
                    current = ""
                } else if comment == 0 {
                    current.append(character)
                }
            default:
                if comment == 0 { current.append(character) }
            }
        }
        tokens.append(current)
        return tokens.compactMap { token -> String? in
            var text = token.trimmingCharacters(in: .whitespaces)
            if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), close > open {
                text = String(text[text.index(after: open)..<close])
            } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("\""), !text[..<colon].contains("@") {
                text = String(text[text.index(after: colon)...])
            }
            text = text.trimmingCharacters(in: .whitespaces)
            guard text.contains("@"), !text.contains(" ") else { return nil }
            return text.lowercased()
        }
    }

    private static func base64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

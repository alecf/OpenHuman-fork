import Foundation
import OpenHumanCore

extension OutgoingMessage {
    public func removingAgentMarkers() -> OutgoingMessage {
        var copy = self
        copy.extraHeaders = extraHeaders.filter { !$0.name.lowercased().hasPrefix("x-openhuman-") }
        return copy
    }
}

public enum MIMEBuilder {
    static let maxBytes = 35 * 1024 * 1024
    // Why: an extra header with one of these names would bypass the builder's rules (e.g. Bcc)
    static let reservedHeaders: Set<String> = [
        "from", "to", "cc", "bcc", "resent-bcc", "reply-to", "subject", "date", "message-id", "in-reply-to", "references",
        "mime-version", "content-type", "content-transfer-encoding", "content-disposition", "content-id",
    ]

    public static func build(_ message: OutgoingMessage, bcc: BccHandling) throws -> Data {
        try build(message, bcc: bcc, boundary: { randomBoundary() })
    }

    static func randomBoundary() -> String {
        var rng = SystemRandomNumberGenerator()
        let hex = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
        return "oh-" + hex
    }

    private indirect enum Node {
        case leaf(headers: [String], body: String)
        case multipart(subtype: String, children: [Node])
    }

    static func build(_ m: OutgoingMessage, bcc: BccHandling, boundary makeBoundary: () -> String) throws -> Data {
        try validate(m)
        guard m.htmlBody != nil || m.textBody != nil else { throw MIMEError.missingBody }
        var estimate = (m.htmlBody?.utf8.count ?? 0) + (m.textBody?.utf8.count ?? 0)
        for a in m.attachments { estimate += a.data.count }
        guard estimate <= maxBytes else { throw MIMEError.tooLarge(bytes: estimate) }

        let plain: Node? = {
            let text = m.textBody ?? m.htmlBody.map { HTMLText.extract($0, maxBytes: 4 * 1024 * 1024) } ?? ""
            if case .flowed = m.textFormat {
                return .leaf(headers: ["Content-Type: text/plain; charset=utf-8; format=flowed",
                                       "Content-Transfer-Encoding: quoted-printable"],
                             body: HeaderEncoding.quotedPrintable(FlowedText.encode(text)))
            }
            return .leaf(headers: ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"],
                         body: HeaderEncoding.quotedPrintable(text))
        }()
        var bodyNode: Node
        var regular = m.attachments
        if let html = m.htmlBody {
            let htmlLeaf = Node.leaf(headers: ["Content-Type: text/html; charset=utf-8",
                                               "Content-Transfer-Encoding: quoted-printable"],
                                     body: HeaderEncoding.quotedPrintable(html))
            let inline = m.attachments.filter { $0.isInline && ($0.contentID?.isEmpty == false) }
            regular = m.attachments.filter { !($0.isInline && ($0.contentID?.isEmpty == false)) }
            let htmlSide: Node = inline.isEmpty ? htmlLeaf
                : .multipart(subtype: "related", children: [htmlLeaf] + (try inline.map(attachmentNode)))
            bodyNode = .multipart(subtype: "alternative", children: [plain!, htmlSide])
        } else {
            bodyNode = plain!
        }
        if !regular.isEmpty {
            bodyNode = .multipart(subtype: "mixed", children: [bodyNode] + (try regular.map(attachmentNode)))
        }

        var texts: [String] = []
        func collect(_ n: Node) {
            switch n {
            case .leaf(let h, let b): texts.append(contentsOf: h); texts.append(b)
            case .multipart(_, let c): c.forEach(collect)
            }
        }
        collect(bodyNode)
        var used = Set<String>()
        func freshBoundary() throws -> String {
            for _ in 0..<8 {
                let b = makeBoundary()
                if !used.contains(b), !b.isEmpty, !texts.contains(where: { $0.contains(b) }) {
                    used.insert(b)
                    return b
                }
            }
            throw MIMEError.malformed("could not choose a unique multipart boundary")
        }
        func render(_ n: Node) throws -> (headers: [String], body: String) {
            switch n {
            case .leaf(let h, let b): return (h, b)
            case .multipart(let subtype, let children):
                let boundary = try freshBoundary()
                var body = ""
                for child in children {
                    let r = try render(child)
                    body += "--\(boundary)\r\n" + r.headers.joined(separator: "\r\n") + "\r\n\r\n" + r.body + "\r\n"
                }
                body += "--\(boundary)--\r\n"
                return (["Content-Type: multipart/\(subtype); boundary=\"\(boundary)\""], body)
            }
        }
        let rendered = try render(bodyNode)

        var lines: [String] = ["MIME-Version: 1.0"]
        func add(_ name: String, _ value: String) throws {
            guard let folded = HeaderEncoding.fold(name: name, value: value) else {
                throw MIMEError.invalidHeader("\(name): line too long")
            }
            lines.append(folded)
        }
        func list(_ a: [EmailAddress]) -> String { a.map(format).joined(separator: ", ") }
        try add("Date", rfc5322Date(m.date))
        try add("Message-ID", bracketed(m.messageID))
        try add("From", format(m.from))
        if !m.to.isEmpty { try add("To", list(m.to)) }
        if !m.cc.isEmpty { try add("Cc", list(m.cc)) }
        if bcc == .includeForGmailSubmission, !m.bcc.isEmpty { try add("Bcc", list(m.bcc)) }
        if !m.replyTo.isEmpty { try add("Reply-To", list(m.replyTo)) }
        try add("Subject", HeaderEncoding.unstructured(m.subject))
        if let r = m.inReplyTo, !r.isEmpty { try add("In-Reply-To", bracketed(r)) }
        if !m.references.isEmpty { try add("References", m.references.map(bracketed).joined(separator: " ")) }
        for h in m.extraHeaders { try add(h.name, HeaderEncoding.unstructured(h.value)) }
        lines += rendered.headers

        let text = lines.joined(separator: "\r\n") + "\r\n\r\n" + rendered.body
        let data = Data(text.utf8)
        guard data.count <= maxBytes + maxBytes / 3 + 1_000_000 else { throw MIMEError.tooLarge(bytes: data.count) }
        return data
    }

    private static func attachmentNode(_ a: OutgoingAttachment) throws -> Node {
        let mime = a.mimeType.trimmingCharacters(in: .whitespaces)
        let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&^_.+-")
        let pieces = mime.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty,
              pieces.allSatisfy({ $0.unicodeScalars.allSatisfy(token.contains) }) else {
            throw MIMEError.invalidHeader("attachment mime type")
        }
        guard !HeaderEncoding.hasLineBreakOrControl(a.filename), !a.filename.contains("\t") else {
            throw MIMEError.invalidHeader("attachment filename")
        }
        var typeParams = ""
        var dispParams = ""
        if !a.filename.isEmpty {
            if HeaderEncoding.isPlainASCII(a.filename) {
                typeParams = "; name=\(HeaderEncoding.quotedString(a.filename))"
                dispParams = "; filename=\(HeaderEncoding.quotedString(a.filename))"
            } else {
                typeParams = "; name=\"\(HeaderEncoding.encodedWords(a.filename))\""
                dispParams = "; " + HeaderEncoding.extendedParameter("filename", a.filename).joined(separator: "; ")
            }
        }
        var headers = [mime.lowercased() + typeParams].map { "Content-Type: " + $0 }
        headers.append("Content-Transfer-Encoding: base64")
        let inline = a.isInline && a.contentID?.isEmpty == false
        headers.append("Content-Disposition: " + (inline ? "inline" : "attachment") + dispParams)
        if inline, let cid = a.contentID {
            let bare = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard !bare.isEmpty, bare.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != "<" && $0 != ">" })
            else { throw MIMEError.invalidHeader("Content-ID") }
            headers.append("Content-ID: <\(bare)>")
        }
        headers = try headers.map { line in
            let colon = line.firstIndex(of: ":")!
            guard let folded = HeaderEncoding.fold(name: String(line[..<colon]),
                                                   value: String(line[line.index(after: colon)...].dropFirst())) else {
                throw MIMEError.invalidHeader("attachment header too long")
            }
            return folded
        }
        let body = a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                        .endLineWithLineFeed])
        return .leaf(headers: headers, body: body)
    }

    private static func validate(_ m: OutgoingMessage) throws {
        for a in [m.from] + m.to + m.cc + m.bcc + m.replyTo { try validate(address: a) }
        guard !HeaderEncoding.hasLineBreakOrControl(m.subject) else { throw MIMEError.invalidHeader("Subject") }
        for id in [m.messageID] + (m.inReplyTo.map { [$0] } ?? []) + m.references {
            let bad = id.isEmpty || id.unicodeScalars.contains { $0.value <= 0x20 || $0.value >= 0x7F }
            if bad { throw MIMEError.invalidHeader("message id") }
        }
        let nameOK = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        for h in m.extraHeaders {
            guard !h.name.isEmpty, h.name.unicodeScalars.allSatisfy(nameOK.contains) else {
                throw MIMEError.invalidHeader("header name \(h.name)")
            }
            guard !reservedHeaders.contains(h.name.lowercased()) else {
                throw MIMEError.invalidHeader("reserved header \(h.name)")
            }
            guard !h.value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
                throw MIMEError.invalidHeader("header value \(h.name)")
            }
        }
    }

    private static func validate(address a: EmailAddress) throws {
        let forbidden = CharacterSet(charactersIn: "<>,;\"()\\").union(.whitespaces).union(.controlCharacters)
        guard !a.email.isEmpty, a.email.contains("@"), a.email.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw MIMEError.invalidHeader("address")
        }
        if let name = a.name, HeaderEncoding.hasLineBreakOrControl(name) { throw MIMEError.invalidHeader("display name") }
    }

    private static func format(_ a: EmailAddress) -> String {
        guard let name = a.name, !name.isEmpty else { return a.email }
        return "\(HeaderEncoding.phrase(name)) <\(a.email)>"
    }

    private static func bracketed(_ id: String) -> String { id.hasPrefix("<") ? id : "<\(id)>" }

    static func rfc5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        return f.string(from: date)
    }
}

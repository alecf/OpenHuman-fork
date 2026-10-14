import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME

extension FakeGmail {
    @discardableResult
    public func deliver(from: String = "Alice Example <alice@example.com>", to: String? = nil,
                        subject: String = "Synthetic subject", body: String = "Synthetic body text.",
                        html: String? = nil, labels: [String] = ["INBOX", "UNREAD"], threadID: String? = nil,
                        date: Date? = nil, extraHeaders: [GmailHeader] = [],
                        attachments: [FakeGmailAttachment] = []) -> (messageID: String, threadID: String) {
        let id = nextID()
        let thread = threadID ?? id
        let internalMS = nextDate(date)
        var headers = [
            GmailHeader(name: "From", value: from),
            GmailHeader(name: "To", value: to ?? accountEmail),
            GmailHeader(name: "Subject", value: subject),
            GmailHeader(name: "Date", value: Self.rfc5322(Date(timeIntervalSince1970: Double(internalMS) / 1000))),
            GmailHeader(name: "Message-ID", value: "<\(id)@fake.openhuman.invalid>"),
        ]
        if threadID != nil,
           let parent = messages.values.filter({ $0.threadID == thread }).max(by: { $0.internalDate < $1.internalDate }) {
            let parentID = "<\(parent.id)@fake.openhuman.invalid>"
            headers.append(GmailHeader(name: "In-Reply-To", value: parentID))
            headers.append(GmailHeader(name: "References", value: parentID))
        }
        headers += extraHeaders
        let (payload, parts) = attachments.isEmpty
            ? (Self.payload(headers: headers, text: body, html: html), [:])
            : Self.payload(headers: headers, text: body, html: html, attachments: attachments, messageID: id)
        insert(StoredMessage(id: id, threadID: thread, labels: Set(labels), internalDate: internalMS, historyID: 0,
                             snippet: String(body.prefix(100)), payload: payload,
                             sizeEstimate: body.utf8.count + (html?.utf8.count ?? 0) + 400
                                 + attachments.reduce(0) { $0 + $1.data.count },
                             attachments: parts))
        return (id, thread)
    }

    @discardableResult
    public func deliver(payload: GmailMessagePart, snippet: String = "", labels: [String] = ["INBOX", "UNREAD"],
                        threadID: String? = nil, date: Date? = nil) -> (messageID: String, threadID: String) {
        let id = nextID()
        let thread = threadID ?? id
        insert(StoredMessage(id: id, threadID: thread, labels: Set(labels), internalDate: nextDate(date), historyID: 0,
                             snippet: snippet, payload: payload, sizeEstimate: 4_000))
        return (id, thread)
    }

    @discardableResult
    public func seedInbox(count: Int, unread: Bool = true) -> [String] {
        (0..<count).map { n in
            deliver(subject: "Seeded thread \(n)", body: "Seeded body \(n).",
                    labels: unread ? ["INBOX", "UNREAD"] : ["INBOX"]).threadID
        }
    }

    @discardableResult
    public func addUserLabel(_ name: String) -> String {
        insertUserLabel(name: name, labelListVisibility: "labelShow", messageListVisibility: "show").id
    }

    public func modifyLabels(messageID: String, add: [String] = [], remove: [String] = []) {
        change(messageID, add: Set(add), remove: Set(remove))
    }

    public func simulateWebArchive(threadID: String) {
        for m in messages.values where m.threadID == threadID && m.labels.contains("INBOX") {
            change(m.id, add: [], remove: ["INBOX"])
        }
    }

    public func simulateWebRead(threadID: String) {
        for m in messages.values where m.threadID == threadID && m.labels.contains("UNREAD") {
            change(m.id, add: [], remove: ["UNREAD"])
        }
    }

    public func simulateWebLabelRename(labelID: String, newName: String) {
        labels[labelID]?.name = newName
    }

    public func deleteMessagePermanently(_ id: String) {
        removeMessage(id)
    }

    public func labelIDs(ofMessage id: String) -> Set<String>? { messages[id]?.labels }
    public func messageIDs(inThread id: String) -> [String] {
        messages.values.filter { $0.threadID == id }.sorted { $0.internalDate < $1.internalDate }.map(\.id)
    }
    public var threadCount: Int { Set(messages.values.map(\.threadID)).count }
    public var messageCount: Int { messages.count }
    public func labelID(named name: String) -> String? { labels.values.first { $0.name == name }?.id }

    func nextID() -> String {
        idCounter += 1
        return String(idCounter, radix: 16)
    }

    func nextDate(_ date: Date?) -> Int64 {
        if let date { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        dateCounter += 60_000
        return dateCounter
    }

    @discardableResult
    func insertUserLabel(name: String, labelListVisibility: String?, messageListVisibility: String?) -> GmailLabel {
        let label = GmailLabel(id: "Label_\(labels.count + 1)", name: name, type: "user",
                               messageListVisibility: messageListVisibility, labelListVisibility: labelListVisibility)
        labels[label.id] = label
        return label
    }

    func bumpHistory() -> UInt64 {
        historyID += 1
        return historyID
    }

    func stub(_ m: StoredMessage) -> GmailMessage {
        GmailMessage(id: m.id, threadId: m.threadID, labelIds: m.labels.sorted())
    }

    func insert(_ message: StoredMessage) {
        var m = message
        let h = bumpHistory()
        m.historyID = h
        messages[m.id] = m
        history.append(GmailHistoryRecord(id: String(h), messages: [GmailMessage(id: m.id, threadId: m.threadID)],
                                          messagesAdded: [GmailHistoryMessageRef(message: stub(m))]))
    }

    func removeMessage(_ id: String) {
        guard let m = messages.removeValue(forKey: id) else { return }
        let h = bumpHistory()
        history.append(GmailHistoryRecord(id: String(h), messages: [GmailMessage(id: m.id, threadId: m.threadID)],
                                          messagesDeleted: [GmailHistoryMessageRef(message: GmailMessage(id: m.id, threadId: m.threadID))]))
    }

    func change(_ id: String, add: Set<String>, remove: Set<String>) {
        guard var m = messages[id] else { return }
        let added = add.subtracting(m.labels).subtracting(remove)
        let removed = remove.intersection(m.labels)
        if added.isEmpty && removed.isEmpty { return }
        m.labels = m.labels.union(added).subtracting(removed)
        let h = bumpHistory()
        m.historyID = h
        messages[id] = m
        var record = GmailHistoryRecord(id: String(h), messages: [GmailMessage(id: m.id, threadId: m.threadID)])
        if !added.isEmpty { record.labelsAdded = [GmailHistoryLabelChange(message: stub(m), labelIds: added.sorted())] }
        if !removed.isEmpty { record.labelsRemoved = [GmailHistoryLabelChange(message: stub(m), labelIds: removed.sorted())] }
        history.append(record)
    }

    func threadHistoryID(_ threadID: String) -> UInt64 {
        messages.values.filter { $0.threadID == threadID }.map(\.historyID).max() ?? 0
    }

    func thread(_ id: String, format: MessageFormat, headers: [String]) throws -> GmailThread {
        let members = messages.values.filter { $0.threadID == id }.sorted { ($0.internalDate, $0.id) < ($1.internalDate, $1.id) }
        guard let last = members.last else { throw GmailError.notFound("threads/\(id)") }
        return GmailThread(id: id, snippet: last.snippet, historyId: String(threadHistoryID(id)),
                           messages: members.map { render($0, format: format, headers: headers) })
    }

    func render(_ m: StoredMessage, format: MessageFormat, headers: [String]) -> GmailMessage {
        var out = GmailMessage(id: m.id, threadId: m.threadID, labelIds: m.labels.sorted(), snippet: m.snippet,
                               historyId: String(m.historyID), internalDate: String(m.internalDate),
                               sizeEstimate: m.sizeEstimate)
        switch format {
        case .minimal:
            break
        case .metadata:
            let wanted = Set(headers.map { $0.lowercased() })
            let kept = (m.payload.headers ?? []).filter { wanted.isEmpty || wanted.contains($0.name.lowercased()) }
            out.payload = GmailMessagePart(partId: "", mimeType: m.payload.mimeType, filename: "", headers: kept,
                                           body: GmailMessagePartBody(size: 0))
        case .full:
            out.payload = m.payload
        case .raw:
            out.raw = Base64URL.encode(Self.rawRFC822(m.payload))
        }
        return out
    }

    func paginate<T>(_ items: [T], _ token: String?, _ maxResults: Int) throws -> ([T], String?) {
        let start: Int
        if let token {
            guard token.hasPrefix("p"), let n = Int(token.dropFirst()), n >= 0 else {
                throw GmailError.badRequest(reason: "invalidArgument", message: "Invalid pageToken")
            }
            start = n
        } else {
            start = 0
        }
        let size = min(max(maxResults, 1), 500)
        guard start < items.count else { return ([], nil) }
        let end = min(items.count, start + size)
        return (Array(items[start..<end]), end < items.count ? "p\(end)" : nil)
    }

    func matchingMessages(_ query: ListQuery) throws -> [StoredMessage] {
        var required = Set(query.labelIDs)
        var before: Int64?, after: Int64?
        var anywhere = query.includeSpamTrash
        var rfc822: String?
        for token in (query.q ?? "").split(separator: " ").map(String.init) where !token.isEmpty {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw GmailError.badRequest(reason: "invalidArgument", message: "FakeGmail q supports operators only")
            }
            let (op, value) = (parts[0].lowercased(), parts[1])
            switch op {
            case "in", "label":
                if value.lowercased() == "anywhere" { anywhere = true; continue }
                guard let id = resolveLabel(value) else { return [] }
                required.insert(id)
            case "is":
                switch value.lowercased() {
                case "unread": required.insert("UNREAD")
                case "starred": required.insert("STARRED")
                case "important": required.insert("IMPORTANT")
                default: throw GmailError.badRequest(reason: "invalidArgument", message: "FakeGmail: unsupported is:")
                }
            case "before": before = try Self.queryDate(value)
            case "after": after = try Self.queryDate(value)
            case "rfc822msgid": rfc822 = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            default:
                throw GmailError.badRequest(reason: "invalidArgument", message: "FakeGmail: unsupported operator")
            }
        }
        if required.contains("SPAM") || required.contains("TRASH") { anywhere = true }
        return messages.values.filter { m in
            if !anywhere && (m.labels.contains("SPAM") || m.labels.contains("TRASH")) { return false }
            if !required.isSubset(of: m.labels) { return false }
            if let before, m.internalDate >= before { return false }
            if let after, m.internalDate < after { return false }
            if let rfc822 {
                let id = (m.payload.headers ?? []).first { $0.name.lowercased() == "message-id" }?.value ?? ""
                if id.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) != rfc822 { return false }
            }
            return true
        }
    }

    func resolveLabel(_ value: String) -> String? {
        if labels[value.uppercased()] != nil, labels[value.uppercased()]?.type == "system" { return value.uppercased() }
        if labels[value] != nil { return value }
        return labels.values.first { $0.name.caseInsensitiveCompare(value) == .orderedSame
            || $0.name.replacingOccurrences(of: " ", with: "-").caseInsensitiveCompare(value) == .orderedSame }?.id
    }

    static func queryDate(_ value: String) throws -> Int64 {
        if let seconds = Int64(value) { return seconds * 1000 }
        let parts = value.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { throw GmailError.badRequest(reason: "invalidArgument", message: "bad date") }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: c) else { throw GmailError.badRequest(reason: "invalidArgument", message: "bad date") }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    func addRaw(_ raw: Data, labels: Set<String>, threadID: String?) -> String {
        let text = String(decoding: raw, as: UTF8.self)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let split = normalized.range(of: "\n\n")
        let head = split.map { String(normalized[..<$0.lowerBound]) } ?? normalized
        let rawBody = split.map { String(normalized[$0.upperBound...]) } ?? ""
        var headers: [GmailHeader] = []
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append(GmailHeader(name: String(line[..<colon]),
                                           value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        headers.removeAll { ["content-type", "content-transfer-encoding", "mime-version"].contains($0.name.lowercased()) }
        var body = rawBody, html: String?
        if let parsed = try? MIMEParser.parse(rfc822: raw), parsed.textBody != nil || parsed.htmlBody != nil {
            body = parsed.textBody ?? ""
            html = parsed.htmlBody
        }
        let id = nextID()
        insert(StoredMessage(id: id, threadID: threadID ?? id, labels: labels, internalDate: nextDate(nil), historyID: 0,
                             snippet: String(body.prefix(100)), payload: Self.payload(headers: headers, text: body, html: html),
                             sizeEstimate: raw.count))
        return id
    }

    func recordDeliveries(messageID: String, raw: Data) {
        guard let parsed = try? MIMEParser.parse(rfc822: raw) else { return }
        let stripped = Self.removingBcc(raw)
        let recipients = (parsed.to + parsed.cc + parsed.bcc).map { $0.email.lowercased() }
        var seen = Set<String>()
        for recipient in recipients where seen.insert(recipient).inserted {
            deliveryLog.append(FakeDelivery(recipient: recipient, sentMessageID: messageID, raw: stripped))
        }
    }

    static func removingBcc(_ raw: Data) -> Data {
        let text = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        guard let split = text.range(of: "\r\n\r\n") else { return raw }
        var out: [Substring] = []
        var skipping = false
        for line in text[..<split.lowerBound].split(separator: "\r\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" { if !skipping { out.append(line) }; continue }
            skipping = line.lowercased().hasPrefix("bcc:")
            if !skipping { out.append(line) }
        }
        return Data((out.joined(separator: "\r\n") + String(text[split.lowerBound...])).utf8)
    }

    public func deliveries() -> [FakeDelivery] { deliveryLog }

    static func payload(headers: [GmailHeader], text: String, html: String?) -> GmailMessagePart {
        func leaf(_ id: String, _ type: String, _ content: String) -> GmailMessagePart {
            GmailMessagePart(partId: id, mimeType: type, filename: "",
                             headers: [GmailHeader(name: "Content-Type", value: "\(type); charset=\"UTF-8\"")],
                             body: GmailMessagePartBody(size: content.utf8.count, data: Base64URL.encode(Data(content.utf8))))
        }
        guard let html else {
            var part = leaf("", "text/plain", text)
            part.headers = headers + [GmailHeader(name: "Content-Type", value: "text/plain; charset=\"UTF-8\"")]
            return part
        }
        return GmailMessagePart(partId: "", mimeType: "multipart/alternative", filename: "",
                                headers: headers + [GmailHeader(name: "Content-Type",
                                                                value: "multipart/alternative; boundary=\"fake\"")],
                                body: GmailMessagePartBody(size: 0),
                                parts: [leaf("0", "text/plain", text), leaf("1", "text/html", html)])
    }

    static func rawRFC822(_ payload: GmailMessagePart) -> Data {
        var out = ""
        for h in payload.headers ?? [] where h.name.lowercased() != "content-type" { out += "\(h.name): \(h.value)\r\n" }
        out += "Content-Type: text/plain; charset=\"UTF-8\"\r\n\r\n"
        func text(_ part: GmailMessagePart) -> String? {
            if part.mimeType == "text/plain", let data = part.body?.data, let bytes = Base64URL.decode(data) {
                return String(decoding: bytes, as: UTF8.self)
            }
            return part.parts?.lazy.compactMap(text).first
        }
        out += text(payload) ?? ""
        return Data(out.utf8)
    }

    static func rfc5322(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}

public struct FakeDelivery: Sendable, Hashable {
    public var recipient: String
    public var sentMessageID: String
    public var raw: Data
}

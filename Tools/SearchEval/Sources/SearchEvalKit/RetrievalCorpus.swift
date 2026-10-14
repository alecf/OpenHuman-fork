import Foundation
import OpenHumanAI
import OpenHumanCore
import OpenHumanStore

public struct CorpusEmail: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let account: String
    public let thread: String
    public let topic: String
    public let from: String
    public let to: [String]
    public let days: Int
    public let subject: String
    public let body: String
    public let labels: [String]
    public let attachments: [String]
    public let tags: [String]

    public init(id: String, account: String, thread: String, topic: String, from: String, to: [String], days: Int,
                subject: String, body: String, labels: [String] = ["INBOX"], attachments: [String] = [],
                tags: [String] = []) {
        self.id = id; self.account = account; self.thread = thread; self.topic = topic; self.from = from; self.to = to
        self.days = days; self.subject = subject; self.body = body; self.labels = labels; self.attachments = attachments
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey { case id, account, thread, topic, from, to, days, subject, body, labels, attachments, tags }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        account = try c.decode(String.self, forKey: .account)
        thread = try c.decodeIfPresent(String.self, forKey: .thread) ?? id
        topic = try c.decode(String.self, forKey: .topic)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decodeIfPresent([String].self, forKey: .to) ?? []
        days = try c.decode(Int.self, forKey: .days)
        subject = try c.decode(String.self, forKey: .subject)
        body = try c.decode(String.self, forKey: .body)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? ["INBOX"]
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public var sender: EmailAddress { RetrievalCorpus.address(from) }
    public var isSpam: Bool { labels.contains("SPAM") }
    public var isTrash: Bool { labels.contains("TRASH") }
    public var date: Date { RetrievalCorpus.anchor.addingTimeInterval(-Double(days) * 86_400 - Double(minuteOffset) * 60) }

    var minuteOffset: Int { Int(RetrievalCorpus.stableHash(id) % 600) }
}

public enum QueryClass: String, Codable, Sendable, Hashable, CaseIterable {
    case exact, paraphrase, vague, natural, distractor, misspelling, short, negative, crossLanguage, poisoning
}

public struct CorpusQuery: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: QueryClass
    public let query: String
    public let relevant: [String: Int]
    public let planned: String?
    public let account: String?
    public let relevantThreads: [String: Int]?

    public init(id: String, kind: QueryClass, query: String, relevant: [String: Int], planned: String? = nil,
                account: String? = nil, relevantThreads: [String: Int]? = nil) {
        self.id = id; self.kind = kind; self.query = query; self.relevant = relevant; self.planned = planned
        self.account = account; self.relevantThreads = relevantThreads
    }

    enum CodingKeys: String, CodingKey {
        case id, kind = "class", query, relevant, planned, account, relevantThreads = "threads"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(QueryClass.self, forKey: .kind)
        query = try c.decode(String.self, forKey: .query)
        relevant = try c.decodeIfPresent([String: Int].self, forKey: .relevant) ?? [:]
        planned = try c.decodeIfPresent(String.self, forKey: .planned)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        relevantThreads = try c.decodeIfPresent([String: Int].self, forKey: .relevantThreads)
    }
}

public enum RetrievalCorpus {
    public enum LoadError: Error, Equatable {
        case missingResource(String)
        case badLine(file: String, line: Int)
    }

    public static let anchor = Date(timeIntervalSince1970: 1_791_720_000)

    public static let accounts: [(key: String, email: String, name: String)] = [
        ("work", "jordan@example.com", "Jordan Avery"),
        ("home", "jordan.avery@example.net", "Jordan Avery"),
    ]

    public static let systemLabels: Set<String> = [
        "INBOX", "STARRED", "IMPORTANT", "UNREAD", "SENT", "DRAFT", "TRASH", "SPAM",
        "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ]

    public static func loadEmails() throws -> [CorpusEmail] {
        try parse(resource("retrieval-corpus"), file: "retrieval-corpus.jsonl")
    }

    public static func loadQueries() throws -> [CorpusQuery] {
        try parse(resource("queries"), file: "queries.jsonl")
    }

    static func resource(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "jsonl") else {
            throw LoadError.missingResource(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func parse<T: Decodable>(_ jsonl: String, file: String = "jsonl") throws -> [T] {
        let decoder = JSONDecoder()
        var items: [T] = []
        for (index, line) in jsonl.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
            guard let item = try? decoder.decode(T.self, from: Data(trimmed.utf8)) else {
                throw LoadError.badLine(file: file, line: index + 1)
            }
            items.append(item)
        }
        return items
    }

    public static func address(_ text: String) -> EmailAddress {
        guard let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else {
            return EmailAddress(name: nil, email: text.trimmingCharacters(in: .whitespaces).lowercased())
        }
        let name = text[..<open].trimmingCharacters(in: .whitespaces)
        let email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
        return EmailAddress(name: name.isEmpty ? nil : name, email: email)
    }

    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

public struct EvalDocument: Sendable {
    public var message: MessageRowID
    public var thread: String
    public var account: AccountID
    public var date: Date
    public var isTrash: Bool
    public var text: EmbeddingRecipe.MessageText

    public init(message: MessageRowID, thread: String, account: AccountID, date: Date, isTrash: Bool,
                text: EmbeddingRecipe.MessageText) {
        self.message = message
        self.thread = thread
        self.account = account
        self.date = date
        self.isTrash = isTrash
        self.text = text
    }
}

public struct BuiltCorpus: Sendable {
    public let store: MailStore
    public let emails: [CorpusEmail]
    public let documents: [EvalDocument]
    public let accounts: [String: AccountID]
    public let threadOfRow: [ThreadRowID: String]
    public let messageRow: [String: MessageRowID]
    public let newestDate: [String: Date]
    public let now: Date

    public init(store: MailStore, emails: [CorpusEmail], documents: [EvalDocument], accounts: [String: AccountID],
                threadOfRow: [ThreadRowID: String], messageRow: [String: MessageRowID], newestDate: [String: Date],
                now: Date) {
        self.store = store
        self.emails = emails
        self.documents = documents
        self.accounts = accounts
        self.threadOfRow = threadOfRow
        self.messageRow = messageRow
        self.newestDate = newestDate
        self.now = now
    }

    public func threads(_ rows: [ThreadRowID]) -> [String] { rows.compactMap { threadOfRow[$0] } }

    public func grades(for query: CorpusQuery) -> [String: Int] {
        if let threads = query.relevantThreads { return threads.filter { $0.value > 0 } }
        var grades: [String: Int] = [:]
        let byID = Dictionary(emails.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (emailID, grade) in query.relevant {
            guard let email = byID[emailID], grade > 0 else { continue }
            grades[email.thread] = max(grades[email.thread] ?? 0, grade)
        }
        return grades
    }

    public func scope(for query: CorpusQuery) -> [AccountID]? {
        query.account.flatMap { accounts[$0] }.map { [$0] }
    }

    public static func build(_ emails: [CorpusEmail]) throws -> BuiltCorpus {
        let store = try MailStore.openInMemoryForTesting()
        var accounts: [String: AccountID] = [:]
        for account in RetrievalCorpus.accounts {
            let id = try store.addAccount(email: account.email, displayName: account.name, scopes: ["gmail.readonly"])
            accounts[account.key] = id
            let userLabels = Set(emails.filter { $0.account == account.key }.flatMap(\.labels))
                .subtracting(RetrievalCorpus.systemLabels).sorted()
            let labels = RetrievalCorpus.systemLabels.sorted().map { LabelUpsert(gmailLabelID: GmailLabelID($0), name: $0, type: "system") }
                + userLabels.map { LabelUpsert(gmailLabelID: GmailLabelID(labelID($0)), name: $0, type: "user") }
            try store.upsertLabels(labels, account: id, removeMissing: false)
        }
        var history: UInt64 = 1
        for account in RetrievalCorpus.accounts {
            guard let accountID = accounts[account.key] else { continue }
            let mine = emails.filter { $0.account == account.key }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            var batch: [MessageUpsert] = []
            for email in mine {
                batch.append(upsert(email, history: history))
                history += 1
                if batch.count == 200 {
                    _ = try store.upsertMessages(batch, account: accountID, generation: 1)
                    batch.removeAll()
                }
            }
            if !batch.isEmpty { _ = try store.upsertMessages(batch, account: accountID, generation: 1) }
        }
        var threadOfRow: [ThreadRowID: String] = [:]
        var messageRow: [String: MessageRowID] = [:]
        var documents: [EvalDocument] = []
        var newest: [String: Date] = [:]
        for email in emails.sorted(by: { $0.id < $1.id }) {
            guard let account = accounts[email.account] else { continue }
            if let ref = try store.thread(account: account, gmailThreadID: GmailThreadID(threadID(email))) {
                threadOfRow[ref.rowID] = email.thread
            }
            if let message = try store.message(account: account, gmailMessageID: GmailMessageID(email.id)) {
                messageRow[email.id] = message.id
                if !email.isSpam {
                    documents.append(EvalDocument(
                        message: message.id, thread: email.thread, account: account, date: email.date,
                        isTrash: email.isTrash,
                        text: .init(subject: email.subject, senderName: email.sender.name, body: email.body,
                                    attachmentNames: email.attachments)))
                }
            }
            newest[email.thread] = max(newest[email.thread] ?? .distantPast, email.date)
        }
        return BuiltCorpus(store: store, emails: emails, documents: documents, accounts: accounts,
                           threadOfRow: threadOfRow, messageRow: messageRow, newestDate: newest,
                           now: RetrievalCorpus.anchor)
    }

    static func labelID(_ name: String) -> String {
        "Label_" + name.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }

    static func threadID(_ email: CorpusEmail) -> String { "\(email.account)-\(email.thread)" }

    static func upsert(_ email: CorpusEmail, history: UInt64) -> MessageUpsert {
        let accountEmail = RetrievalCorpus.accounts.first { $0.key == email.account }?.email ?? "jordan@example.com"
        let labels = email.labels.map { RetrievalCorpus.systemLabels.contains($0) ? $0 : labelID($0) }
        let sender = email.sender
        let snippet = String(email.body.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(140))
        let to = email.to.isEmpty ? [EmailAddress(name: nil, email: accountEmail)] : email.to.map(RetrievalCorpus.address)
        let body = MessageBodyUpsert(html: nil, text: email.body, hasCalendarInvite: email.tags.contains("invite"),
                                     decodeWarnings: [], searchText: email.body)
        var message = MessageUpsert(
            gmailMessageID: GmailMessageID(email.id), gmailThreadID: GmailThreadID(threadID(email)),
            historyID: HistoryID(history), internalDate: email.date, labelIDs: labels.map { GmailLabelID($0) },
            snippet: snippet, sizeEstimate: 2_000 + email.body.utf8.count,
            headers: MessageHeaderFields(
                subject: email.subject, from: sender, to: to, cc: [], bcc: [], replyTo: [], date: email.date,
                messageID: "<\(email.id)@example.com>", inReplyTo: nil, references: []),
            body: body)
        if !email.attachments.isEmpty {
            message.attachments = email.attachments.enumerated().map { index, name in
                AttachmentUpsert(partID: "\(index + 2)", filename: name, mimeType: mimeType(name),
                                 size: 10_000 + 1_000 * index, isInline: false)
            }
        }
        return message
    }

    static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "ics": "text/calendar"
        case "csv": "text/csv"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        default: "application/octet-stream"
        }
    }
}

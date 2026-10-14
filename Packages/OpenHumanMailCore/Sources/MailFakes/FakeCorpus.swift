import Foundation
import MailModel
import OpenHumanCore

public struct FakeCorpus: Sendable {
    public struct Thread: Sendable {
        public let row: ThreadRow
        public let detail: ConversationDetail
        public let bodyKinds: [MessageKey: FakeBodyKind]
        public let labels: [MessageKey: [GmailLabelID]]
        public let unsubscribe: [MessageKey: UnsubscribeInfo]
        public let listIDs: [MessageKey: String]
        let allMessages: [MessageSummary]
        let fromMe: Set<MessageKey>
        let bodySpecs: [MessageKey: FakeBodySpec]

        public var bodies: [MessageKey: MessageContent] { bodySpecs.mapValues(\.content) }

        init(row: ThreadRow, detail: ConversationDetail, allMessages: [MessageSummary], fromMe: Set<MessageKey>,
             bodySpecs: [MessageKey: FakeBodySpec], labels: [MessageKey: [GmailLabelID]],
             unsubscribe: [MessageKey: UnsubscribeInfo] = [:], listIDs: [MessageKey: String] = [:]) {
            self.row = row
            self.detail = detail
            self.allMessages = allMessages
            self.fromMe = fromMe
            self.bodySpecs = bodySpecs
            self.bodyKinds = bodySpecs.mapValues(\.kind)
            self.labels = labels
            self.unsubscribe = unsubscribe
            self.listIDs = listIDs
        }
    }

    public struct Mailbox: Sendable {
        public let account: Account
        public let threads: [Thread]
        public let labels: [LabelInfo]
        public let splits: [SplitInfo]
        public let drafts: [DraftSummary]
        public let reminders: [ReminderItem]
        let draftSendStamps: [DraftKey: String]

        public init(account: Account, threads: [Thread], labels: [LabelInfo], splits: [SplitInfo],
                    drafts: [DraftSummary] = [], reminders: [ReminderItem] = []) {
            self.init(account: account, threads: threads, labels: labels, splits: splits, drafts: drafts,
                      reminders: reminders, draftSendStamps: [:])
        }

        init(account: Account, threads: [Thread], labels: [LabelInfo], splits: [SplitInfo], drafts: [DraftSummary],
             reminders: [ReminderItem], draftSendStamps: [DraftKey: String]) {
            self.account = account
            self.threads = threads
            self.labels = labels
            self.splits = splits
            self.drafts = drafts
            self.reminders = reminders
            self.draftSendStamps = draftSendStamps
        }
    }

    public let mailboxes: [Mailbox]
    public let snippets: [SnippetInfo]

    public var account: Account { mailboxes[0].account }
    public var threads: [Thread] { mailboxes[0].threads }
    public var accounts: [Account] { mailboxes.map(\.account) }

    public init(mailboxes: [Mailbox], snippets: [SnippetInfo] = []) {
        precondition(!mailboxes.isEmpty, "a corpus needs at least one account")
        self.mailboxes = mailboxes
        self.snippets = snippets
    }

    public init(account: Account, threads: [Thread]) {
        var ids = FakeIDs()
        self.init(mailboxes: [Mailbox(account: account, threads: threads,
                                      labels: FakeLabels.standard(account: account.id, ids: &ids),
                                      splits: [FakeLabels.importantSplit(account: account.id, ids: &ids)])])
    }

    public static let me = EmailAddress(name: "Robin Example", email: "robin@example.com")

    static let people: [EmailAddress] = [
        .init(name: "Dana Ruiz", email: "dana@example.com"), .init(name: "Sam Lee", email: "sam@example.org"),
        .init(name: "Priya Natarajan", email: "priya@example.net"), .init(name: "Jonas Berg", email: "jonas@example.com"),
        .init(name: "Mia Chen", email: "mia@example.org"), .init(name: "Alex Moreau", email: "alex@example.net"),
        .init(name: "Team Updates", email: "updates@news.example"), .init(name: "Lena Fischer", email: "lena@example.com"),
        .init(name: "Omar Haddad", email: "omar@example.org"), .init(name: "Grace Okafor", email: "grace@example.net"),
        .init(name: "Weekly Digest", email: "digest@news.example"), .init(name: "Tomás Silva", email: "tomas@example.com"),
        .init(name: "Hana Sato", email: "hana@example.org"), .init(name: "Ravi Kapoor", email: "ravi@example.net"),
        .init(name: "Billing", email: "billing@shop.example"), .init(name: "Ella Novak", email: "ella@example.com"),
    ]

    static let topics: [String] = [
        "Q4 budget", "Offsite planning", "Design review", "Hiring loop", "Launch checklist", "Board deck",
        "Customer interviews", "Roadmap draft", "Security review", "Quarterly goals", "Office move", "Team dinner",
        "Pricing update", "Contract renewal", "Onboarding notes", "Release notes", "Partner call", "Survey results",
        "Travel booking", "Weekly sync", "Bug triage", "Research summary", "Invoice 2214", "Product feedback",
    ]

    public static func make(threadCount: Int = 200, now: Date = Date(), seed: UInt64 = 0x5eed) -> FakeCorpus {
        var rng = SplitMix64(seed: seed)
        let accountID = AccountID(1)
        let account = Account(id: accountID, email: me.email, displayName: me.name, alias: "Work", health: .active,
                              sendAs: [SenderIdentity(email: me.email, name: me.name, isDefault: true, isPrimary: true)])
        var threads: [Thread] = []
        threads.reserveCapacity(threadCount)
        var messageRow: Int64 = 1
        var lastAt = now.addingTimeInterval(-Double(rng.next(in: 2...25)) * 60)

        for index in 0..<threadCount {
            let topic = topics[index % topics.count]
            let counterpart = people[Int(rng.next(in: 0...UInt64(people.count - 1)))]
            let other = people[((people.firstIndex(of: counterpart) ?? 0) + 3) % people.count]
            let messageCount = Int(rng.next(in: 1...4))
            let isNewsletter = counterpart.email.hasSuffix("news.example")
            let kinds: [FakeBodyKind] = (0..<messageCount).map { i in
                if isNewsletter { return .newsletter }
                if index == 4, i == messageCount - 1 { return .hostile }
                let pool: [FakeBodyKind] = [.plainReply, .simpleHTML, .gmailReply, .plainShort, .simpleHTML]
                return pool[Int(rng.next(in: 0...UInt64(pool.count - 1)))]
            }
            let unread = index < 6 ? rng.next(in: 0...9) < 8 : rng.next(in: 0...9) < 2
            let starred = rng.next(in: 0...9) == 0
            let attachments = rng.next(in: 0...6) == 0
            let threadKey = ThreadKey(account: accountID, rowID: Int64(index + 1),
                                      gmailThreadID: GmailThreadID("fake-t\(index + 1)"))
            let subject = index == 4 ? "Action required: verify your account" : (isNewsletter ? "\(topic) weekly" : topic)

            var dates: [Date] = [lastAt]
            for _ in 1..<max(messageCount, 1) {
                dates.insert(dates[0].addingTimeInterval(-Double(rng.next(in: 20...600)) * 60), at: 0)
            }
            var blueprints: [FakeMessageBlueprint] = []
            for i in 0..<messageCount {
                let fromMe = !isNewsletter && messageCount > 1 && i % 2 == 1
                let sender = fromMe ? me : counterpart
                let isLast = i == messageCount - 1
                let key = MessageKey(account: accountID, rowID: messageRow, gmailMessageID: GmailMessageID("fake-m\(messageRow)"))
                let atts = attachments && isLast
                    ? [AttachmentInfo(id: Int64(index * 10 + i), filename: "\(topic).pdf", mimeType: "application/pdf",
                                      size: 120_000 + index * 37, contentID: nil, isInline: false)]
                    : []
                let isUnread = unread && isLast && !fromMe
                var labels: [GmailLabelID] = fromMe ? [FakeLabels.sent] : [FakeLabels.inbox]
                if fromMe, messageCount > 1 { labels.append(FakeLabels.inbox) }
                if isUnread { labels.append(FakeLabels.unread) }
                if starred, isLast { labels.append(FakeLabels.starred) }
                if index % 3 == 0 { labels.append(FakeLabels.important) }
                blueprints.append(FakeMessageBlueprint(
                    key: key, from: sender, to: fromMe ? [counterpart] : [me], date: dates[i],
                    body: FakeBodySpec(kind: kinds[i], sender: sender.name ?? sender.email, topic: topic,
                                       other: other.name ?? other.email),
                    labels: labels, attachments: atts, isFromMe: fromMe))
                messageRow += 1
            }
            threads.append(FakeThreadBuilder.thread(key: threadKey, subject: subject, messages: blueprints,
                                                    me: [me.email], userLabelRows: [:]))
            let gapMinutes: UInt64 = index < 10 ? rng.next(in: 15...70) : (index < 40 ? rng.next(in: 90...400) : rng.next(in: 600...3000))
            lastAt = lastAt.addingTimeInterval(-Double(gapMinutes) * 60)
        }
        return FakeCorpus(account: account, threads: threads)
    }

    static func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }.joined(separator: " ")
        return String(flat.prefix(140))
    }
}

struct FakeMessageBlueprint: Sendable {
    var key: MessageKey
    var from: EmailAddress
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var date: Date
    var body: FakeBodySpec
    var labels: [GmailLabelID]
    var attachments: [AttachmentInfo]
    var isFromMe: Bool
    var hasCalendarInvite: Bool
    var unsubscribe: UnsubscribeInfo?
    var listID: String?
    var snippet: String?

    init(key: MessageKey, from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], date: Date,
         body: FakeBodySpec, labels: [GmailLabelID], attachments: [AttachmentInfo] = [], isFromMe: Bool,
         hasCalendarInvite: Bool = false, unsubscribe: UnsubscribeInfo? = nil, listID: String? = nil,
         snippet: String? = nil) {
        self.key = key
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.body = body
        self.labels = labels
        self.attachments = attachments
        self.isFromMe = isFromMe
        self.hasCalendarInvite = hasCalendarInvite
        self.unsubscribe = unsubscribe
        self.listID = listID
        self.snippet = snippet
    }
}

enum FakeThreadBuilder {
    static func thread(key: ThreadKey, subject: String, messages: [FakeMessageBlueprint], me: Set<String>,
                       userLabelRows: [GmailLabelID: Int64]) -> FakeCorpus.Thread {
        var views: [FakeAggregator.MessageView] = []
        var specs: [MessageKey: FakeBodySpec] = [:]
        var labels: [MessageKey: [GmailLabelID]] = [:]
        var unsubscribe: [MessageKey: UnsubscribeInfo] = [:]
        var lists: [MessageKey: String] = [:]
        var fromMe = Set<MessageKey>()
        views.reserveCapacity(messages.count)
        for m in messages {
            let labelSet = Set(m.labels)
            let summary = MessageSummary(id: m.key, from: m.from, to: m.to, cc: m.cc, bcc: [], date: m.date,
                                         snippet: m.snippet ?? m.body.snippet, isUnread: labelSet.contains(FakeLabels.unread),
                                         attachments: m.attachments, hasCalendarInvite: m.hasCalendarInvite)
            views.append(FakeAggregator.MessageView(summary: summary, labels: labelSet, isFromMe: m.isFromMe))
            specs[m.key] = m.body
            labels[m.key] = m.labels
            if m.isFromMe { fromMe.insert(m.key) }
            if let u = m.unsubscribe { unsubscribe[m.key] = u }
            if let l = m.listID { lists[m.key] = l }
        }
        let row = FakeAggregator.row(key: key, subject: subject, messages: views, me: me, userLabelRows: userLabelRows)
        let detail = ConversationDetail(id: key, subject: subject, messages: FakeAggregator.scope(views).map(\.summary),
                                        userLabelIDs: row.userLabelIDs, isStarred: row.isStarred)
        return FakeCorpus.Thread(row: row, detail: detail, allMessages: views.map(\.summary), fromMe: fromMe,
                                 bodySpecs: specs, labels: labels, unsubscribe: unsubscribe, listIDs: lists)
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<UInt64>) -> UInt64 {
        range.lowerBound + next() % (range.upperBound - range.lowerBound + 1)
    }
    mutating func chance(_ percent: UInt64) -> Bool { next(in: 0...99) < percent }
}

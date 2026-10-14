import Foundation
import OpenHumanCore
import OpenHumanStore

public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct SyntheticCorpus: Sendable {
    public struct Config: Sendable {
        public var seed: UInt64
        public var accounts: Int
        public var threads: Int
        public var messages: Int
        public var userLabels: Int
        public var inboxThreads: Int
        public var bodyFraction: Double
        public var bodyBytes: Int

        public init(seed: UInt64 = 20_261_010, accounts: Int, threads: Int, messages: Int, userLabels: Int,
                    inboxThreads: Int, bodyFraction: Double, bodyBytes: Int) {
            self.seed = seed; self.accounts = accounts; self.threads = threads; self.messages = messages
            self.userLabels = userLabels; self.inboxThreads = inboxThreads; self.bodyFraction = bodyFraction
            self.bodyBytes = bodyBytes
        }

        public static let small = Config(accounts: 2, threads: 120, messages: 400, userLabels: 8, inboxThreads: 30,
                                         bodyFraction: 0.3, bodyBytes: 600)
        public static let perf = Config(accounts: 2, threads: 16_700, messages: 50_000, userLabels: 60, inboxThreads: 1_000,
                                        bodyFraction: 0.3, bodyBytes: 6_000)
        public static let spec = Config(accounts: 2, threads: 100_000, messages: 300_000, userLabels: 60, inboxThreads: 3_000,
                                        bodyFraction: 0.3, bodyBytes: 6_000)
    }

    public var config: Config
    public var accounts: [AccountID]
    public var threadCount: Int
    public var messageCount: Int
    public var thirtyMessageThread: (account: AccountID, gmailThreadID: GmailThreadID)?
    public var userLabelIDs: [GmailLabelID]
    public var messagesWithBody: [(account: AccountID, gmailMessageID: GmailMessageID)]
    public var senderAddresses: [String]

    private static let words = [
        "invoice", "meeting", "project", "update", "review", "budget", "quarter", "launch", "design", "schedule", "report",
        "contract", "travel", "lunch", "feedback", "roadmap", "hiring", "security", "release", "customer", "support", "plan",
        "draft", "proposal", "workshop", "retro", "metrics", "forecast", "onboarding", "vendor", "renewal", "audit",
    ]
    private static let firstNames = ["Alex", "Sam", "Jo", "Kim", "Lee", "Pat", "Robin", "Taylor", "Morgan", "Casey", "Drew", "Jamie"]
    private static let lastNames = ["Rivera", "Chen", "Okafor", "Novak", "Silva", "Ito", "Haddad", "Larsen", "Costa", "Reyes"]

    @discardableResult
    public static func generate(_ config: Config, in store: MailStore, progress: ((Double) -> Void)? = nil) throws -> SyntheticCorpus {
        precondition(config.accounts >= 1 && config.threads >= 1 && config.messages >= config.threads)
        var rng = SeededGenerator(seed: config.seed)
        var accounts: [AccountID] = []
        var userLabelIDs: [GmailLabelID] = []
        for a in 0..<config.accounts {
            let id = try store.addAccount(email: "user\(a)@example.com", displayName: "User \(a)", scopes: ["gmail.readonly"])
            accounts.append(id)
            let user = (0..<config.userLabels).map {
                LabelUpsert(gmailLabelID: GmailLabelID("Label_\($0)"), name: $0 % 3 == 0 ? "Projects/Area \($0)" : "Label \($0)", type: "user")
            }
            try store.upsertLabels(OpenHumanStoreTesting.systemLabels + user, account: id, removeMissing: false)
        }
        userLabelIDs = (0..<config.userLabels).map { GmailLabelID("Label_\($0)") }

        let people: [(name: String, email: String)] = (0..<400).map { i in
            let first = firstNames[i % firstNames.count], last = lastNames[(i / firstNames.count) % lastNames.count]
            return ("\(first) \(last)", "\(first.lowercased()).\(last.lowercased())\(i)@example.com")
        }

        var sizes = [Int](repeating: 1, count: config.threads)
        var extra = config.messages - config.threads
        var thirtyIndex: Int?
        if config.messages - config.threads >= 29 && config.threads > 1 {
            thirtyIndex = Int.random(in: 0..<config.threads, using: &rng)
            sizes[thirtyIndex!] = 30
            extra -= 29
        }
        var guardCount = 0
        while extra > 0 && guardCount < config.messages * 20 {
            let i = Int.random(in: 0..<config.threads, using: &rng)
            guardCount += 1
            if sizes[i] < 40 && i != thirtyIndex { sizes[i] += 1; extra -= 1 }
        }

        let perAccountInbox = max(config.inboxThreads / config.accounts, 0)
        let baseMinutes = 0
        var history: UInt64 = 1
        var buffers = [[MessageUpsert]](repeating: [], count: config.accounts)
        var messageCount = 0, withBody = 0
        var bodyIDs: [(AccountID, GmailMessageID)] = []
        var thirty: (AccountID, GmailThreadID)?
        var senders = Set<String>()

        func flush(_ a: Int) throws {
            guard !buffers[a].isEmpty else { return }
            _ = try store.upsertMessages(buffers[a], account: accounts[a], generation: 1)
            buffers[a].removeAll(keepingCapacity: true)
        }

        for t in 0..<config.threads {
            let a = t % config.accounts
            let account = accounts[a]
            let threadID = "syn-\(a)-\(t)"
            let k = t / config.accounts
            let inInbox = k % 4 == 0 && k / 4 < perAccountInbox
            let newestMinute = baseMinutes - (t * 1_576_800 / config.threads)
            let kind = Int.random(in: 0..<100, using: &rng)
            let mine = "user\(a)@example.com"
            var threadLabels: [String] = []
            if !inInbox {
                for _ in 0..<Int.random(in: 0...2, using: &rng) where config.userLabels > 0 {
                    threadLabels.append("Label_\(Int.random(in: 0..<config.userLabels, using: &rng))")
                }
            }
            let unread = inInbox && Int.random(in: 0..<10, using: &rng) < 3
            let person = people[Int.random(in: 0..<people.count, using: &rng)]
            let subject = "\(words(&rng, 3).capitalized)"
            for m in 0..<sizes[t] {
                let id = "syn-\(a)-\(t)-\(m)"
                var labels = threadLabels
                let fromMe = kind < 12 || (m % 3 == 2)
                if fromMe { labels.append("SENT") }
                if inInbox { labels.append("INBOX") }
                if unread && m == sizes[t] - 1 { labels.append("UNREAD") }
                if kind >= 12 && kind < 15 && !inInbox { labels.append("TRASH") }
                if kind >= 15 && kind < 18 { labels.append("STARRED") }
                if kind >= 18 && kind < 22 { labels.append("CATEGORY_PROMOTIONS") }
                if inInbox && kind >= 22 && kind < 34 { labels.append("IMPORTANT") }
                let from = fromMe ? (name: "User \(a)", email: mine) : person
                if !fromMe { senders.insert(from.email) }
                let to = fromMe ? [person.email] : [mine]
                var body: MessageBodyUpsert?
                var attachments: [AttachmentUpsert]?
                if Double.random(in: 0..<1, using: &rng) < config.bodyFraction {
                    let text = words(&rng, max(config.bodyBytes / 7, 1))
                    body = MessageBodyUpsert(html: "<p>\(text.prefix(config.bodyBytes / 4))</p>", text: String(text.prefix(config.bodyBytes)),
                                             hasCalendarInvite: false, decodeWarnings: [], searchText: String(text.prefix(config.bodyBytes)))
                    if Int.random(in: 0..<10, using: &rng) == 0 {
                        attachments = [AttachmentUpsert(partID: "2", filename: "doc-\(t).pdf", mimeType: "application/pdf",
                                                        size: 12_000 + t, isInline: false)]
                    }
                    withBody += 1
                    if bodyIDs.count < 2_000 { bodyIDs.append((account, GmailMessageID(id))) }
                }
                var message = MessageUpsert.fixture(
                    id, thread: threadID, minutes: newestMinute - (sizes[t] - 1 - m) * 7, labels: labels, from: from.email,
                    fromName: from.name, to: to, subject: m == 0 ? subject : "Re: \(subject)",
                    snippet: words(&rng, 8), history: history, body: body)
                message.attachments = attachments
                history += 1
                buffers[a].append(message)
                messageCount += 1
                if buffers[a].count >= 200 { try flush(a) }
            }
            if sizes[t] == 30 && thirtyIndex == t { thirty = (account, GmailThreadID(threadID)) }
            if t % 500 == 0 { progress?(Double(t) / Double(config.threads)) }
        }
        for a in 0..<config.accounts { try flush(a) }
        progress?(1)

        return SyntheticCorpus(config: config, accounts: accounts, threadCount: config.threads, messageCount: messageCount,
                               thirtyMessageThread: thirty, userLabelIDs: userLabelIDs,
                               messagesWithBody: bodyIDs, senderAddresses: Array(senders).sorted())
    }

    private static func words(_ rng: inout SeededGenerator, _ count: Int) -> String {
        var out = ""
        for i in 0..<count {
            if i > 0 { out += " " }
            out += Self.words[Int.random(in: 0..<Self.words.count, using: &rng)]
        }
        return out
    }
}

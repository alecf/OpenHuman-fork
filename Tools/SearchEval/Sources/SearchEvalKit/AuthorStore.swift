import Foundation
import OpenHumanAI
import OpenHumanCore
import OpenHumanStore

public struct AuthorLabel: Codable, Sendable, Hashable {
    public var query: String
    public var kind: QueryClass?
    public var threads: [String]

    enum CodingKeys: String, CodingKey { case query, kind = "class", threads }

    public init(query: String, kind: QueryClass? = nil, threads: [String]) {
        self.query = query
        self.kind = kind
        self.threads = threads
    }
}

public enum LabelsPathGuard {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case insideGitWorkingTree
        case missing

        public var description: String {
            switch self {
            case .insideGitWorkingTree:
                "the labels file is inside a git working tree; keep it outside every repository"
            case .missing: "the labels file does not exist"
            }
        }
    }

    public static func isInsideGitWorkingTree(_ url: URL) -> Bool {
        var folder = url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        while true {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path || folder.path == "/" { return false }
            folder = parent
        }
    }

    public static func load(_ url: URL) throws -> [AuthorLabel] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Refusal.missing }
        guard !isInsideGitWorkingTree(url) else { throw Refusal.insideGitWorkingTree }
        return try RetrievalCorpus.parse(String(contentsOf: url, encoding: .utf8), file: "labels")
    }

    public static func queries(_ labels: [AuthorLabel]) -> [CorpusQuery] {
        labels.enumerated().map { index, label in
            CorpusQuery(id: "L\(index + 1)", kind: label.kind ?? .vague, query: label.query, relevant: [:],
                        relevantThreads: Dictionary(label.threads.map { ($0, 2) }, uniquingKeysWith: { first, _ in first }))
        }
    }
}

public enum AuthorStore {
    public static let superhumanCategories: [(label: String, query: String)] = [
        ("[Superhuman]/AI/Invoice", "invoices"),
        ("[Superhuman]/AI/Pitch", "cold pitches"),
        ("[Superhuman]/AI/Meeting", "meeting requests"),
        ("[Superhuman]/AI/Marketing", "marketing"),
        ("[Superhuman]/AI/News", "news"),
    ]

    public static func load(directory: URL, threadLimit: Int = 200_000) throws -> BuiltCorpus {
        let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .cli,
                                                    readOnly: true, appVersion: "search-eval"))
        var accounts: [String: AccountID] = [:]
        var threadOfRow: [ThreadRowID: String] = [:]
        var documents: [EvalDocument] = []
        var newest: [String: Date] = [:]
        for account in try store.accounts() where account.status == .active {
            accounts["\(account.id.rawValue)"] = account.id
            var cursor: ThreadCursor?
            var seen = 0
            repeat {
                let page = try store.threadPage(view: .system(account.id, .allMail), after: cursor, limit: 500)
                for item in page.items {
                    let thread = item.ref.gmailThreadID.rawValue
                    threadOfRow[item.id] = thread
                    guard let detail = try store.threadDetail(item.id) else { continue }
                    for message in detail.messages where !message.isDraft && !message.inSpam {
                        let stored = try store.body(message.id)?.text
                        let body = stored.map(withoutQuotedLines) ?? message.snippet
                        documents.append(EvalDocument(
                            message: message.id, thread: thread, account: account.id, date: message.date,
                            isTrash: message.inTrash,
                            text: .init(subject: message.subject, senderName: message.from?.name, body: body,
                                        attachmentNames: message.attachments.filter { !$0.isInline }.map(\.filename))))
                        newest[thread] = max(newest[thread] ?? .distantPast, message.date)
                    }
                }
                seen += page.items.count
                cursor = page.nextCursor
            } while cursor != nil && seen < threadLimit
        }
        return BuiltCorpus(store: store, emails: [], documents: documents, accounts: accounts, threadOfRow: threadOfRow,
                           messageRow: [:], newestDate: newest, now: Date())
    }

    public static func categoryQueries(_ corpus: BuiltCorpus) throws -> [(query: String, relevant: Set<String>)] {
        var result: [(query: String, relevant: Set<String>)] = []
        let since = corpus.now.addingTimeInterval(-90 * 86_400)
        for category in superhumanCategories {
            var relevant = Set<String>()
            for account in corpus.accounts.values {
                guard let label = try corpus.store.labels(account: account).first(where: { $0.name == category.label })
                else { continue }
                var cursor: ThreadCursor?
                repeat {
                    let page = try corpus.store.threadPage(view: .label(account, GmailLabelID(label.key)), after: cursor,
                                                           limit: 500)
                    for item in page.items where item.lastMessageAt >= since {
                        relevant.insert(item.ref.gmailThreadID.rawValue)
                    }
                    cursor = page.items.last.map { $0.lastMessageAt >= since } == true ? page.nextCursor : nil
                } while cursor != nil
            }
            if !relevant.isEmpty { result.append((category.query, relevant)) }
        }
        return result
    }

    static func withoutQuotedLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
    }
}

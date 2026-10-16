import Foundation
import MailModel
import OpenHumanCore

final class ReaderTestSource: MailDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var details: [ThreadKey: ConversationDetail]
    private var bodies: [MessageKey: MessageContent]
    private var files: [Int64: URL]
    private(set) var bodyRequests: [MessageKey] = []

    init(details: [ConversationDetail], bodies: [MessageKey: MessageContent], files: [Int64: URL] = [:]) {
        self.details = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
        self.bodies = bodies
        self.files = files
    }

    func accounts() -> AsyncThrowingStream<[Account], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield([Account(id: AccountID(1), email: "robin@example.com", displayName: "Robin", alias: nil,
                                        health: .active)])
            continuation.finish()
        }
    }

    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ThreadListWindow(rows: [], hasMore: false, totalCount: 0))
            continuation.finish()
        }
    }

    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> {
        let detail = lock.withLock { details[key] }
        return AsyncThrowingStream { continuation in
            continuation.yield(detail)
            continuation.finish()
        }
    }

    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> {
        let content = lock.withLock {
            bodyRequests.append(key)
            return bodies[key]
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.fetching)
            continuation.yield(content.map(BodyLoadState.available) ?? .failed("missing"))
            continuation.finish()
        }
    }

    func attachmentData(_ key: MessageKey, attachment: AttachmentInfo) async throws -> URL {
        guard let url = lock.withLock({ files[attachment.id] }) else { throw MailPortError.notFound("attachment") }
        return url
    }

    var requestedBodies: [MessageKey] { lock.withLock { bodyRequests } }
}

enum ReaderFixtures {
    static let account = AccountID(1)
    static let me = EmailAddress(name: "Robin", email: "robin@example.com")

    static func thread(_ row: Int64) -> ThreadKey {
        ThreadKey(account: account, rowID: row, gmailThreadID: GmailThreadID("t\(row)"))
    }

    static func message(_ row: Int64) -> MessageKey {
        MessageKey(account: account, rowID: row, gmailMessageID: GmailMessageID("m\(row)"))
    }

    static func summary(_ row: Int64, from: EmailAddress, unread: Bool = false, minutesAgo: Double = 60,
                        attachments: [AttachmentInfo] = [], cc: [EmailAddress] = [], snippet: String = "Snippet") -> MessageSummary {
        MessageSummary(id: message(row), from: from, to: [me], cc: cc, bcc: [],
                       date: Date(timeIntervalSince1970: 1_791_000_000 - minutesAgo * 60), snippet: snippet,
                       isUnread: unread, attachments: attachments)
    }

    static func conversation(_ row: Int64, subject: String = "Quarterly plan", count: Int, from: EmailAddress,
                             unread: Set<Int> = [], firstMessageRow: Int64? = nil) -> ConversationDetail {
        let base = firstMessageRow ?? row * 100
        let messages = (0..<count).map { i in
            summary(base + Int64(i), from: from, unread: unread.contains(i), minutesAgo: Double((count - i) * 60))
        }
        return ConversationDetail(id: thread(row), subject: subject, messages: messages)
    }

    static let dana = EmailAddress(name: "Dana Ruiz", email: "dana@news.example.com")
    static let gmailUser = EmailAddress(name: "Sam Lee", email: "sam.lee@gmail.com")

    static let newsletterHTML = """
    <html><body><table width="560"><tr><td style="background:#ffffff;color:#33415c">
    <p>This week in planning.</p><img src="https://images.news.example/chart.png" width="400" height="200" alt="Chart">
    <img src="https://open.news.example/track/open?u=1" width="1" height="1" alt="">
    </td></tr></table></body></html>
    """

    static let plainHTML = "<div><p>Hello Robin,</p><p>The draft is ready.</p></div>"

    static let designedHTML = "<div style=\"background:#f2f4f7;color:#3056d3\"><p>Designed announcement</p></div>"
}

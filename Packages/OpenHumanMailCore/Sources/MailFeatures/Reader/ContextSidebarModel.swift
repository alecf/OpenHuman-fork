import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class ContextSidebarModel {
    public struct Person: Hashable, Sendable {
        public let name: String?
        public let email: String

        public var displayName: String { (name?.isEmpty == false ? name : nil) ?? email }

        public var initials: String {
            let words = (name ?? "").split(whereSeparator: { !$0.isLetter }).prefix(2)
            let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
            return letters.isEmpty ? String(email.prefix(1)).uppercased() : letters
        }
    }

    public struct Recent: Identifiable, Hashable, Sendable {
        public let id: ThreadKey
        public let subject: String
        public let date: Date
        public let isUnread: Bool
    }

    public static let recentLimit = 5
    static let searchLimit = 25

    public private(set) var isVisible = false
    public private(set) var thread: ThreadKey?
    public private(set) var person: Person?
    public private(set) var recent: [Recent] = []
    public private(set) var isLoading = false
    public private(set) var vipSuggestion: VIPSuggestion?
    public private(set) var vipMessage: String?

    public var personIsVIP: Bool {
        guard let person, let thread else { return false }
        return environment.vips.isVIP(person.email, account: thread.account)
    }

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var generation = 0

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible, let calendar = environment.calendarSidebar, calendar.isVisible { calendar.setVisible(false) }
    }

    public func toggle() { setVisible(!isVisible) }

    public func showCalendar() {
        guard let calendar = environment.calendarSidebar else { return }
        isVisible = false
        calendar.setVisible(true)
    }

    public var hasCalendar: Bool { environment.calendarSidebar != nil }

    public func show(thread: ThreadKey?) async {
        generation += 1
        let mine = generation
        self.thread = thread
        vipSuggestion = nil
        vipMessage = nil
        guard let thread else {
            person = nil
            recent = []
            return
        }
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        let data = environment.data
        var detail: ConversationDetail?
        do {
            for try await value in data.threadDetail(thread) {
                detail = value
                break
            }
        } catch {}
        guard mine == generation else { return }
        let account = environment.router.accounts.first { $0.id == thread.account }?.account
        let isMe: (String) -> Bool = { address in account?.isMe(address) ?? false }
        let found = detail.flatMap { Self.person(in: $0, isMe: isMe) }
        person = found
        guard let found else {
            recent = []
            return
        }
        var hits: [ThreadRow] = []
        do {
            for try await page in data.search(Self.query(for: found.email), accounts: [thread.account], limit: Self.searchLimit) {
                hits = page.hits.map(\.row)
                break
            }
        } catch {}
        guard mine == generation else { return }
        recent = Self.recent(from: hits, excluding: thread)
        let suggestion = await environment.vips.suggestion(for: found.email, account: thread.account)
        guard mine == generation else { return }
        vipSuggestion = suggestion
    }

    public func acceptVIP() async {
        guard let suggestion = vipSuggestion else { return }
        do {
            try await environment.vips.accept(suggestion)
            vipSuggestion = nil
            vipMessage = "\(suggestion.displayName) is a VIP. Their mail is always important."
        } catch {
            vipMessage = (error as? MailPortError)?.description ?? "That change couldn't be saved."
        }
    }

    public func declineVIP() async {
        guard let suggestion = vipSuggestion else { return }
        do {
            try await environment.vips.decline(suggestion)
            vipSuggestion = nil
            vipMessage = nil
        } catch {
            vipMessage = (error as? MailPortError)?.description ?? "That change couldn't be saved."
        }
    }

    static func person(in detail: ConversationDetail, isMe: (String) -> Bool) -> Person? {
        for message in detail.messages.reversed() {
            if let from = message.from, !isMe(from.email) { return Person(name: from.name, email: from.email.lowercased()) }
            if let to = (message.to + message.cc).first(where: { !isMe($0.email) }) {
                return Person(name: to.name, email: to.email.lowercased())
            }
        }
        return nil
    }

    static func query(for email: String) -> String {
        let quoted = "\"\(email.replacingOccurrences(of: "\"", with: ""))\""
        return "from:\(quoted) OR to:\(quoted) OR cc:\(quoted)"
    }

    static func recent(from rows: [ThreadRow], excluding thread: ThreadKey) -> [Recent] {
        rows.filter { $0.id != thread }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
            .prefix(recentLimit)
            .map { Recent(id: $0.id, subject: $0.subject, date: $0.lastMessageAt, isUnread: $0.isUnread) }
    }

    public func searchPerson() {
        guard let person else { return }
        let router = environment.router
        let text = Self.query(for: person.email)
        router.active?.searchText = text
        router.active?.searchOpen = true
        router.go(to: .search(text))
    }

    public func open(_ key: ThreadKey) {
        let router = environment.router
        if key.account != router.active?.id { router.switchAccount(to: key.account) }
        router.open(key)
    }

    public func compose() {
        guard let person else { return }
        let session = environment.compose.openNew(placement: .modal, account: thread?.account)
        session?.to.setTokens([EmailAddress(name: person.name, email: person.email)], notify: true)
    }
}

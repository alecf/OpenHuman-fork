import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class RecipientHistory {
    public private(set) var counts: [String: Int] = [:]
    public private(set) var lookups = 0

    public static let limit = 100

    @ObservationIgnored public var lookup: (@Sendable (String) async -> Int?)?
    private var started: Set<String> = []

    public init(lookup: (@Sendable (String) async -> Int?)? = nil) {
        self.lookup = lookup
    }

    public func load(_ email: String) {
        let key = email.lowercased()
        guard let lookup, RecipientParser.isValid(key), started.insert(key).inserted else { return }
        Task { [weak self] in
            let count = await lookup(key)
            guard let self else { return }
            self.lookups += 1
            self.counts[key] = count ?? 0
        }
    }

    public func line(for address: EmailAddress) -> String? {
        guard let count = counts[address.email.lowercased()], count > 0 else { return nil }
        let name = RecipientParser.displayName(address)
        if count > Self.limit { return String(localized: "\(Self.limit)+ conversations with \(name)") }
        return count == 1 ? String(localized: "1 conversation with \(name)")
                          : String(localized: "\(count) conversations with \(name)")
    }

    public func shown(in tokens: [EmailAddress]) -> EmailAddress? {
        tokens.last { line(for: $0) != nil }
    }

    public func isPending(in tokens: [EmailAddress]) -> Bool {
        tokens.contains { started.contains($0.email.lowercased()) && counts[$0.email.lowercased()] == nil }
    }

    public static func query(for email: String) -> String {
        let quoted = "\"\(email.lowercased().replacingOccurrences(of: "\"", with: ""))\""
        return "from:\(quoted) OR to:\(quoted)"
    }
}

extension ComposeManager {
    public func recipientHistoryLookup(for session: ComposeSession) -> (@Sendable (String) async -> Int?)? {
        guard environment.modules.modules.contains(.smartSearch) else { return nil }
        let data = environment.data
        let account = session.account.id
        return { email in
            try? await data.recentThreads(involving: email, account: account, limit: RecipientHistory.limit + 1).count
        }
    }

    public func searchConversations(with address: EmailAddress, from session: ComposeSession) {
        let router = environment.router
        if router.active?.id != session.account.id { router.switchAccount(to: session.account.id) }
        let text = RecipientHistory.query(for: address.email)
        router.active?.searchText = text
        router.active?.searchOpen = true
        router.go(to: .search(text))
    }
}

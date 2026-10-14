import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore
import Synchronization

public final class MailSearchToolBackend: AISearchToolBackend, Sendable {
    private let data: any MailDataSource
    private let accounts: [AccountID]?
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let known = Mutex<[String: ThreadKey]>([:])

    public init(data: any MailDataSource, accounts: [AccountID]? = nil, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.data = data
        self.accounts = accounts
        self.calendar = calendar
        self.now = now
    }

    public func thread(for id: String) -> ThreadKey? { known.withLock { $0[id] } }

    public func storeQuery(_ query: AISearchToolQuery) -> String? {
        var terms = query.keywords.map(Self.word).filter { !$0.isEmpty }
        let sender = query.sender.filter { $0 != "\"" && $0 != ":" && !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        if !sender.isEmpty { terms.append("from:\"\(sender)\"") }
        if query.withinDays > 0, let start = calendar.date(byAdding: .day, value: -query.withinDays, to: now()) {
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            terms.append(String(format: "after:%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1))
        }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    public func search(_ query: AISearchToolQuery) async throws -> [AISearchToolHit] {
        guard let text = storeQuery(query) else { return [] }
        let results = try await data.searchOnce(text, semanticText: nil, accounts: accounts,
                                                limit: AIPolicy.searchToolMaxHits)
        return results.hits.prefix(AIPolicy.searchToolMaxHits).map { hit in
            let row = hit.row
            let id = "t\(row.id.account.rawValue)-\(row.id.rowID)"
            known.withLock { $0[id] = row.id }
            let marked = hit.highlight?.replacingOccurrences(of: "\u{2}", with: "").replacingOccurrences(of: "\u{3}", with: "")
            return AISearchToolHit(id: id, sender: Self.sender(of: row), subject: row.subject,
                                   date: row.lastMessageAt, snippet: marked ?? row.snippet)
        }
    }

    static func sender(of row: ThreadRow) -> String {
        let other = row.participants.first { !$0.isMe }
        let name = other.flatMap { $0.name?.isEmpty == false ? $0.name : $0.email }
        return name ?? row.participantsDisplay
    }

    static func word(_ raw: String) -> String {
        let kept = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            $0.properties.isAlphabetic || ("0"..."9").contains($0) || "-_'.@".unicodeScalars.contains($0)
        }))
        let upper = kept.uppercased()
        return ["OR", "AND", "NOT"].contains(upper) ? "" : kept
    }
}

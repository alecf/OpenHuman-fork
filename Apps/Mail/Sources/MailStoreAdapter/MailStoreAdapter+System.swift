import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore

extension MailStoreAdapter {
    public func reminders(_ account: AccountID?) -> AsyncThrowingStream<[ReminderItem], Error> {
        Self.map(store.observeReminders(account: account).values()) { $0.map(Self.reminder) }
    }

    static func reminder(_ summary: ReminderSummary) -> ReminderItem {
        ReminderItem(id: summary.reminder.id, thread: threadKey(summary.ref), subject: summary.subject,
                     dueAt: summary.reminder.dueAt, kind: summary.reminder.condition == .ifNoReply ? .ifNoReply : .always)
    }

    public func unsubscribeInfo(_ key: MessageKey) async throws -> UnsubscribeInfo? {
        guard let message = try store.message(account: key.account, gmailMessageID: key.gmailMessageID) else {
            throw MailPortError.notFound("message")
        }
        return ListUnsubscribe(header: message.listUnsubscribe, post: message.listUnsubscribePost).info
    }

    public func diagnosticsSnapshot() async throws -> DiagnosticsSnapshot {
        let store = self.store
        let mode = safeModeValue
        let live = await Self.firstValue(connectivitySource?(), within: .seconds(2)) ?? [:]
        return try await Task.detached {
            try Self.diagnostics(store, safeMode: mode, connectivity: live, now: Date())
        }.value
    }

    static let diagnosticsPageLimit = 100

    static func diagnostics(_ store: any Store, safeMode: SafeModeInfo, connectivity live: [AccountID: ConnectivityState],
                            now: Date) throws -> DiagnosticsSnapshot {
        let items = try store.accounts().sorted { $0.id < $1.id }
        var errors: [String: (count: Int, lastAt: Date?)] = [:]
        func tally(_ code: String, at date: Date?) {
            let current = errors[code]
            let last = [current?.lastAt, date].compactMap { $0 }.max()
            errors[code] = ((current?.count ?? 0) + 1, last)
        }
        var entries: [DiagnosticsSnapshot.AccountEntry] = []
        for (offset, item) in items.enumerated() {
            let status = try? store.syncStatus(account: item.id)
            let counts = try? store.counts(account: item.id)
            let allMail = try? store.label(account: item.id, key: "oh:allmail")
            let state = live[item.id] ?? connectivityState(status: status, accountStatus: item.status)
            entries.append(DiagnosticsSnapshot.AccountEntry(
                index: offset + 1, health: "\(account(item).health)", connectivity: describe(state),
                lastSyncAt: status?.lastSuccessAt, consecutiveFailures: status?.consecutiveFailures ?? 0,
                threadCount: allMail?.totalThreads ?? 0, messageCount: messageCount(store, account: item.id),
                draftCount: counts?.draftsCount ?? 0, pendingOperations: status?.pendingOperations ?? 0,
                failedOperations: status?.failedOperations ?? 0))
            for run in (try? store.syncLog(account: item.id, limit: 50)) ?? [] {
                if let code = run.errorCode { tally(code, at: run.finishedAt ?? run.startedAt) }
            }
        }
        let operations = (try? store.operations(account: nil, statuses: [.pending, .inFlight, .failed], limit: 10_000)) ?? []
        var tallies: [String: Int] = [:]
        for op in operations {
            tallies["\(op.kind.rawValue)|\(op.status.rawValue)", default: 0] += 1
            if op.status == .failed, let code = op.lastErrorCode { tally(code, at: op.updatedAt) }
        }
        let schema = (store as? MailStore).flatMap { try? $0.doctor() }.flatMap { report in
            report.appliedMigrations.compactMap { $0.hasPrefix("v") ? Int($0.dropFirst()) : nil }.max()
        }
        return DiagnosticsSnapshot(
            generatedAt: now, safeMode: "\(safeMode)", schemaVersion: schema, accounts: entries,
            operations: tallies.keys.sorted().map { key in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                return DiagnosticsSnapshot.OperationTally(kind: parts[0], status: parts.count > 1 ? parts[1] : "",
                                                          count: tallies[key] ?? 0)
            },
            recentErrors: errors.keys.sorted().map {
                DiagnosticsSnapshot.ErrorTally(code: $0, count: errors[$0]?.count ?? 0, lastAt: errors[$0]?.lastAt)
            })
    }

    static func messageCount(_ store: any Store, account: AccountID) -> Int {
        var total = 0
        var cursor: ThreadCursor?
        for _ in 0..<diagnosticsPageLimit {
            guard let page = try? store.threadPage(view: .system(account, .allMail), after: cursor, limit: 500) else { break }
            total += page.items.reduce(0) { $0 + $1.messageCount }
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            cursor = next
        }
        return total
    }

    static func connectivityState(status: SyncStatus?, accountStatus: AccountStatus) -> ConnectivityState {
        if accountStatus == .needsReauth { return .needsReauth }
        guard let status else { return .online(syncing: true, lastSyncAt: nil) }
        if status.consecutiveFailures > 0 {
            return .syncFailing(code: status.lastError ?? "error", failures: status.consecutiveFailures,
                                lastSyncAt: status.lastSuccessAt)
        }
        let initial: Bool = switch status.phase {
        case .new, .bootstrapping, .resyncRequired: true
        case .inboxReady, .backfilling, .incremental: false
        }
        return .online(syncing: initial, lastSyncAt: status.lastSuccessAt)
    }

    static func describe(_ state: ConnectivityState) -> String {
        switch state {
        case .online(let syncing, _): syncing ? "online(syncing)" : "online"
        case .offline: "offline"
        case .rateLimited: "rateLimited"
        case .syncFailing(let code, _, _): "syncFailing(\(code))"
        case .needsReauth: "needsReauth"
        }
    }

    static func firstValue<T: Sendable>(_ stream: AsyncStream<T>?, within limit: Duration) async -> T? {
        guard let stream else { return nil }
        return await withTaskGroup(of: T?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// The header is untrusted: only https and mailto URIs are kept, never http, so nothing is fetched in the clear
struct ListUnsubscribe: Equatable, Sendable {
    static let oneClickValue = "List-Unsubscribe=One-Click"

    var oneClick: URL?
    var mailto: EmailAddress?
    var mailtoSubject: String?
    var link: URL?

    init(header: String?, post: String?) {
        let uris = Self.uris(in: header ?? "")
        let https = uris.compactMap { text -> URL? in
            guard let url = URL(string: text), url.scheme?.lowercased() == "https",
                  let host = url.host(), !host.isEmpty else { return nil }
            return url
        }.first
        link = https
        let supportsOneClick = post?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(Self.oneClickValue) == .orderedSame
        oneClick = supportsOneClick ? https : nil
        for text in uris {
            guard let components = URLComponents(string: text), components.scheme?.lowercased() == "mailto" else { continue }
            let address = components.path.trimmingCharacters(in: .whitespaces)
            guard address.contains("@"), !address.contains(","), !address.contains(where: \.isWhitespace) else { continue }
            mailto = EmailAddress(email: address)
            mailtoSubject = components.queryItems?.first { $0.name.lowercased() == "subject" }?.value
            break
        }
    }

    var info: UnsubscribeInfo? {
        if let oneClick, let host = oneClick.host() { return .oneClick(host: host) }
        if let mailto { return .mailto(mailto, subject: mailtoSubject) }
        if let link { return .link(link) }
        return nil
    }

    static func uris(in header: String) -> [String] {
        var out: [String] = []
        var rest = header[...]
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let inner = rest[rest.index(after: open)..<close].filter { !$0.isWhitespace }
            if !inner.isEmpty { out.append(String(inner)) }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }
}

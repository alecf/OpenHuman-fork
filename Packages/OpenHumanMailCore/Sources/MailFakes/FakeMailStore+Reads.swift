import Foundation
import MailModel
import OpenHumanCore

extension FakeMailStore {
    public func accounts() -> AsyncThrowingStream<[Account], Error> {
        stream { s in s.accounts.values.map(\.account).sorted { $0.id < $1.id } }
    }

    public func labels(_ account: AccountID) -> AsyncThrowingStream<[LabelInfo], Error> {
        stream { s in
            guard let tally = s.tally(account) else { throw MailPortError.notFound("account") }
            return tally.labels
        }
    }

    public func splits(_ account: AccountID) -> AsyncThrowingStream<[SplitInfo], Error> {
        stream { s in
            guard let splits = s.splitInfos(account) else { throw MailPortError.notFound("account") }
            return splits
        }
    }

    public func counts(_ account: AccountID) -> AsyncThrowingStream<MailboxCountsInfo, Error> {
        stream { s in
            guard let tally = s.tally(account) else { throw MailPortError.notFound("account") }
            return tally.counts
        }
    }

    public func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        stream { s in
            guard s.accounts[account] != nil else { return ThreadListWindow(rows: [], hasMore: false, totalCount: 0) }
            let entries = try s.entries(location, account: account)
            let rows = entries.prefix(max(limit, 0)).compactMap { s.row($0) }
            let window = ThreadListWindow(rows: rows, hasMore: entries.count > max(limit, 0), totalCount: entries.count)
            guard case .search(let text) = location else { return window }
            return s.searchWindow(window, query: text, account: account)
        }
    }

    public func threadPage(_ location: MailLocation, account: AccountID, after: PageCursor?,
                           limit: Int) async throws -> (rows: [ThreadRow], next: PageCursor?) {
        let position = try after.map { try JSONDecoder().decode(PagePosition.self, from: $0.payload) }
        return try state.withLock { s in
            let entries = try s.entries(location, account: account)
            var start = 0
            if let position {
                let ascending = location.sortsAscending
                start = entries.firstIndex { entry in
                    let lhs = (entry.sortAt.timeIntervalSince1970, entry.key.rowID)
                    let rhs = (position.sortAt, position.rowID)
                    return ascending ? lhs > rhs : lhs < rhs
                } ?? entries.count
            }
            let page = entries[start..<min(entries.count, start + max(limit, 0))]
            let rows = page.compactMap { s.row($0) }
            var next: PageCursor?
            if let last = page.last, start + page.count < entries.count {
                let payload = try JSONEncoder().encode(PagePosition(sortAt: last.sortAt.timeIntervalSince1970,
                                                                    rowID: last.key.rowID))
                next = PageCursor(payload: payload)
            }
            return (rows, next)
        }
    }

    public func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> {
        stream { s in s.detail(key) }
    }

    public func storedBody(_ key: MessageKey) async throws -> MessageContent? {
        state.withLock { s in
            guard let threadKey = s.messageIndex[key] else { return nil }
            return s.threads[threadKey]?.messages.first(where: { $0.summary.id == key })?.content
        }
    }

    public func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> {
        let find: @Sendable (inout State) -> BodyLoadState = { s in
            guard let threadKey = s.messageIndex[key],
                  let message = s.threads[threadKey]?.messages.first(where: { $0.summary.id == key }) else {
                return .failed("Message not found")
            }
            return .available(message.content)
        }
        guard let bodyDelay = options.bodyDelay else { return stream(find) }
        let lookup: @Sendable () -> BodyLoadState = { [weak self] in
            self?.state.withLock { find(&$0) } ?? .failed("Store closed")
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.fetching)
            let task = Task {
                try? await Task.sleep(for: bodyDelay)
                guard !Task.isCancelled else { return }
                continuation.yield(lookup())
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func attachmentData(_ key: MessageKey, attachment: AttachmentInfo) async throws -> URL {
        let found: (AttachmentInfo, String, MessageSummary)? = state.withLock { s in
            guard let threadKey = s.messageIndex[key], let thread = s.threads[threadKey],
                  let message = thread.messages.first(where: { $0.summary.id == key }),
                  let info = message.summary.attachments.first(where: { $0.id == attachment.id }) else { return nil }
            return (info, thread.subject, message.summary)
        }
        guard let (info, subject, summary) = found else { throw MailPortError.notFound("attachment") }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenHumanMailFakes", isDirectory: true)
            .appendingPathComponent("\(key.rowID)-\(info.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = info.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        let contents = info.mimeType == "text/calendar"
            ? FakeBodies.calendarFile(topic: subject, organizer: summary.from, attendee: summary.to.first)
            : "Synthetic attachment \(info.filename) (\(info.mimeType), \(info.size) bytes) from the OpenHuman fake corpus.\n"
        try Data(contents.utf8).write(to: file, options: .atomic)
        return file
    }

    public func search(_ query: String, accounts: [AccountID]?, limit: Int) -> AsyncThrowingStream<SearchResultsInfo, Error> {
        stream { s in
            let hits = try s.searchEntries(query, accounts: accounts)
            var reasons: [SearchIncompleteness] = []
            for account in (accounts ?? Array(s.accounts.keys)).sorted() {
                for reason in s.searchIncomplete[account] ?? [] where !reasons.contains(reason) { reasons.append(reason) }
            }
            return SearchResultsInfo(hits: Array(hits.prefix(max(limit, 0))), hasMore: hits.count > max(limit, 0),
                                     completeness: SearchCompletenessInfo(reasons: reasons))
        }
    }

    public func searchGmail(_ query: String, account: AccountID) async throws -> Int {
        let outcome: Result<Int, MailPortError> = try mutate { s in
            _ = try FakeQuery.parse(query, mode: .search)
            guard s.accounts[account] != nil else { return .failure(MailPortError.notFound("account")) }
            let key = FakeGmailSearchKey(account: account, query: query)
            s.gmailSearchCount += 1
            if s.failNextGmailSearch {
                s.failNextGmailSearch = false
                s.gmailSearches[key] = .failed
                return .failure(MailPortError.unavailable("Gmail search"))
            }
            let found = (s.gmailOnly[account] ?? []).filter { s.threads[$0] != nil }
            s.gmailSearches[key] = .answered(found)
            return .success(found.count)
        }
        return try outcome.get()
    }

    public func drafts(_ account: AccountID?, review: Bool) -> AsyncThrowingStream<[DraftSummary], Error> {
        stream { s in
            s.draftSummaries(account) { draft in
                review ? draft.summary.review == .pending && draft.status != .sending : draft.isListed
            }
        }
    }

    public func draft(_ key: DraftKey) -> AsyncThrowingStream<DraftSummary?, Error> {
        stream { s in s.drafts[key]?.summary }
    }

    public func sentConversation(_ draft: DraftKey) async throws -> ThreadKey? {
        state.withLock { s in s.sent.last { $0.draft == draft }?.thread }
    }

    public func reviewQueue(_ account: AccountID?) -> AsyncThrowingStream<[DraftSummary], Error> {
        stream { s in s.draftSummaries(account) { $0.summary.review == .pending && $0.status != .sending } }
    }

    public func connectivity() -> AsyncStream<[AccountID: ConnectivityState]> {
        guard options.liveConnectivity else { return AsyncStream { $0.finish() } }
        return plainStream { s in
            Dictionary(uniqueKeysWithValues: s.accounts.map { ($0.key, s.effectiveConnectivity($0.key)) })
        }
    }

    public func syncProgress() -> AsyncStream<[AccountID: String]> {
        guard options.liveConnectivity else { return AsyncStream { $0.finish() } }
        return plainStream { s in s.syncLines }
    }

    public func pendingChanges() -> AsyncStream<[AccountID: Int]> {
        guard options.liveConnectivity else { return AsyncStream { $0.finish() } }
        return plainStream { s in
            var counts: [AccountID: Int] = [:]
            for op in s.operations.values where op.status == .pending { counts[op.account, default: 0] += 1 }
            return counts
        }
    }

    public func smartSearchStatus() -> AsyncStream<SmartSearchStatus> {
        plainStream { s in s.smartSearch }
    }

    public func contactSuggestions(_ account: AccountID, prefix: String, limit: Int) async throws -> [EmailAddress] {
        let needle = prefix.lowercased()
        return state.withLock { s in
            guard let me = s.accounts[account]?.me else { return [] }
            var scores: [String: (EmailAddress, Int)] = [:]
            for key in s.threadOrder[account] ?? [] {
                for message in s.threads[key]?.messages ?? [] {
                    let summary = message.summary
                    for address in [summary.from].compactMap({ $0 }) + summary.to + summary.cc {
                        let email = address.email.lowercased()
                        guard !me.contains(email) else { continue }
                        let tokens = [email] + (address.name?.lowercased().split(separator: " ").map(String.init) ?? [])
                        guard needle.isEmpty || tokens.contains(where: { $0.hasPrefix(needle) }) else { continue }
                        let current = scores[email]
                        scores[email] = (current?.0.name == nil ? address : current?.0 ?? address, (current?.1 ?? 0) + 1)
                    }
                }
            }
            return scores.values.sorted { ($1.1, $0.0.email) < ($0.1, $1.0.email) }.prefix(max(limit, 0)).map(\.0)
        }
    }

    public func recentThreads(involving email: String, account: AccountID, limit: Int) async throws -> [ThreadRow] {
        let needle = email.lowercased()
        return state.withLock { s in
            guard let me = s.accounts[account]?.me else { return [] }
            var rows: [ThreadRow] = []
            for key in s.threadOrder[account] ?? [] {
                guard let thread = s.threads[key], let derived = s.derived(key), derived.hasVisible else { continue }
                let involved = thread.messages.contains { message in
                    let summary = message.summary
                    guard let from = summary.from?.email.lowercased() else { return false }
                    if from == needle { return true }
                    return me.contains(from) && (summary.to + summary.cc).contains { $0.email.lowercased() == needle }
                }
                if involved { rows.append(derived.row) }
            }
            rows.sort { ($0.lastMessageAt, $0.id.rowID) > ($1.lastMessageAt, $1.id.rowID) }
            return Array(rows.prefix(max(limit, 0)))
        }
    }

    public func snippets(_ account: AccountID?) -> AsyncThrowingStream<[SnippetInfo], Error> {
        stream { s in
            s.snippets.values.filter { account == nil || $0.account == nil || $0.account == account }
                .sorted { ($1.useCount, $0.name, $0.id) < ($0.useCount, $1.name, $1.id) }
        }
    }

    public func reminders(_ account: AccountID?) -> AsyncThrowingStream<[ReminderItem], Error> {
        stream { s in s.reminderItems(account) }
    }

    public func failedOperations(_ account: AccountID?) -> AsyncThrowingStream<[FailedOperationInfo], Error> {
        stream { s in s.failures.filter { account == nil || $0.account == account } }
    }

    public func localThread(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadRow? {
        state.withLock { s in
            guard let key = (s.threadOrder[account] ?? []).first(where: { $0.gmailThreadID == gmailThreadID }) else {
                return nil
            }
            return s.derived(key)?.row
        }
    }

    public func refresh(_ account: AccountID) async throws {
        try state.withLock { s in
            guard s.accounts[account] != nil else { throw MailPortError.notFound("account") }
            if s.offline { throw MailPortError.unavailable("offline") }
        }
    }

    public func unsubscribeInfo(_ key: MessageKey) async throws -> UnsubscribeInfo? {
        try state.withLock { s in
            guard let threadKey = s.messageIndex[key],
                  let message = s.threads[threadKey]?.messages.first(where: { $0.summary.id == key }) else {
                throw MailPortError.notFound("message")
            }
            return message.unsubscribe
        }
    }

    public func listID(_ key: MessageKey) async throws -> String? {
        state.withLock { s in
            guard let threadKey = s.messageIndex[key] else { return nil }
            return s.threads[threadKey]?.messages.first { $0.summary.id == key }?.listID?.lowercased()
        }
    }

    public func diagnosticsSnapshot() async throws -> DiagnosticsSnapshot {
        let generatedAt = now
        return state.withLock { s in
            let accountIDs = s.accounts.keys.sorted()
            let entries = accountIDs.enumerated().map { index, id -> DiagnosticsSnapshot.AccountEntry in
                let keys = s.threadOrder[id] ?? []
                let health = s.accounts[id].map { "\($0.account.health)" } ?? "unknown"
                return DiagnosticsSnapshot.AccountEntry(
                    index: index + 1, health: health, connectivity: Self.describe(s.effectiveConnectivity(id)),
                    threadCount: keys.count,
                    messageCount: keys.reduce(0) { $0 + (s.threads[$1]?.messages.count ?? 0) },
                    draftCount: s.drafts.values.filter { $0.account == id }.count,
                    pendingOperations: s.operations.values.filter { $0.account == id && $0.status == .pending }.count,
                    failedOperations: s.failures.filter { $0.account == id }.count)
            }
            var tallies: [String: Int] = [:]
            for op in s.operations.values { tallies["\(op.kind)|\(op.status.rawValue)", default: 0] += 1 }
            let operations = tallies.keys.sorted().map { key -> DiagnosticsSnapshot.OperationTally in
                let parts = key.split(separator: "|").map(String.init)
                return DiagnosticsSnapshot.OperationTally(kind: parts[0], status: parts.count > 1 ? parts[1] : "",
                                                          count: tallies[key] ?? 0)
            }
            var errors: [String: (Int, Date)] = [:]
            for failure in s.failures {
                let current = errors[failure.errorCode]
                errors[failure.errorCode] = ((current?.0 ?? 0) + 1, max(current?.1 ?? failure.failedAt, failure.failedAt))
            }
            return DiagnosticsSnapshot(
                generatedAt: generatedAt, accounts: entries, operations: operations,
                recentErrors: errors.keys.sorted().map {
                    DiagnosticsSnapshot.ErrorTally(code: $0, count: errors[$0]?.0 ?? 0, lastAt: errors[$0]?.1)
                })
        }
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
}

struct PagePosition: Codable, Sendable {
    var sortAt: Double
    var rowID: Int64
}

extension State {
    mutating func searchWindow(_ local: ThreadListWindow, query: String, account: AccountID) -> ThreadListWindow {
        var rows = local.rows
        var gmail = GmailSearchState.notAsked
        switch gmailSearches[FakeGmailSearchKey(account: account, query: query)] {
        case .answered(let keys)?:
            var seen = Set(rows.map(\.id))
            for key in keys where seen.insert(key).inserted {
                if let row = derived(key)?.row { rows.append(row) }
            }
            gmail = .done(added: rows.count - local.rows.count)
        case .failed?:
            gmail = .failed
        case nil:
            break
        }
        let status = SearchWindowStatus(completeness: SearchCompletenessInfo(reasons: searchIncomplete[account] ?? []),
                                        gmail: gmail, gmailAvailable: true)
        return ThreadListWindow(rows: rows, hasMore: local.hasMore,
                                totalCount: local.totalCount + rows.count - local.rows.count, search: status)
    }

    func effectiveConnectivity(_ account: AccountID) -> ConnectivityState {
        if offline { return .offline(since: offlineSince) }
        guard let state = accounts[account] else { return .needsReauth }
        if state.account.health == .needsSignIn { return .needsReauth }
        return state.connectivity
    }
}

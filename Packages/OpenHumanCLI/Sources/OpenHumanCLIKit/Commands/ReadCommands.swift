import ArgumentParser
import Foundation
import OpenHumanCore
import OpenHumanStore

public struct PagingOptions: ParsableArguments {
    @Option(name: .long, help: "Maximum rows (1 to 500).") public var max: Int = 25
    @Option(name: .long, help: "Opaque cursor from the previous page (meta.nextCursor).") public var cursor: String?
    public init() {}

    func validated() throws -> (limit: Int, cursor: ThreadCursor?) {
        guard (1...500).contains(max) else { throw CLIError.usage("--max must be between 1 and 500.", code: "bad_max") }
        guard let cursor else { return (max, nil) }
        guard let parsed = ThreadCursor(encoded: cursor) else { throw CLIError.usage("That cursor is not valid.", code: "bad_cursor") }
        return (max, parsed)
    }
}

enum Listing {
    static let systemKeys: [String: SystemMailbox] = [
        "INBOX": .inbox, "STARRED": .starred, "IMPORTANT": .important, "UNREAD": .unread, "SENT": .sent,
        "DRAFT": .drafts, "TRASH": .trash, "SPAM": .spam,
    ]
    static let viewNames: [String: SystemMailbox] = [
        "inbox": .inbox, "starred": .starred, "important": .important, "unread": .unread, "sent": .sent, "drafts": .drafts,
        "all": .allMail, "trash": .trash, "spam": .spam, "snoozed": .snoozed, "scheduled": .scheduled, "reminders": .reminders,
        "waiting": .waiting,
    ]
    static let labelOfMailbox: [SystemMailbox: String] = [
        .inbox: "INBOX", .starred: "STARRED", .important: "IMPORTANT", .sent: "SENT", .drafts: "DRAFT", .trash: "TRASH", .spam: "SPAM",
    ]

    typealias Stream = (account: AccountID, view: MailboxView)

    static func collect(_ store: MailStore, streams specs: [Stream], ascending: Bool, after: ThreadCursor?, limit: Int,
                        keep: (ThreadListItem) -> Bool = { _ in true }) throws -> (items: [ThreadListItem], next: ThreadCursor?) {
        struct State {
            var spec: Stream
            var position: ThreadCursorPosition?
            var buffer: [ThreadListItem] = []
            var exhausted = false
        }
        let multi = specs.count > 1
        if multi, let after, after.perAccount == nil { throw CLIError.usage("That cursor is not valid.", code: "bad_cursor") }
        var states = specs.map { spec in
            State(spec: spec, position: after.flatMap { cursor in
                cursor.perAccount?[spec.account] ?? (multi ? nil : ThreadCursorPosition(sortAt: cursor.sortAt, tid: cursor.tid))
            })
        }
        func key(_ item: ThreadListItem) -> (Int64, Int64) { (Int64((item.sortAt.timeIntervalSince1970 * 1000).rounded()), item.id.rawValue) }
        func before(_ a: ThreadListItem, _ b: ThreadListItem) -> Bool {
            let (x, y) = (key(a), key(b))
            return ascending ? x < y : x > y
        }
        var out: [ThreadListItem] = []
        var consumed = 0
        var last: ThreadCursorPosition?
        while out.count < limit, consumed < 5000 {
            for i in states.indices where states[i].buffer.isEmpty && !states[i].exhausted {
                let cursor = states[i].position.map { ThreadCursor(sortAt: $0.sortAt, tid: $0.tid) }
                let page = try store.threadPage(view: states[i].spec.view, after: cursor, limit: Swift.max(limit, 50))
                states[i].buffer = page.items
                if page.nextCursor == nil { states[i].exhausted = true }
            }
            var best: Int?
            for i in states.indices {
                guard let head = states[i].buffer.first else { continue }
                if best == nil || before(head, states[best!].buffer[0]) { best = i }
            }
            guard let pick = best else { break }
            let item = states[pick].buffer.removeFirst()
            let position = ThreadCursorPosition(sortAt: key(item).0, tid: key(item).1)
            states[pick].position = position
            last = position
            consumed += 1
            if keep(item) { out.append(item) }
        }
        let more = states.contains { !$0.buffer.isEmpty || !$0.exhausted }
        guard more, let last else { return (out, nil) }
        var next = ThreadCursor(sortAt: last.sortAt, tid: last.tid)
        if multi {
            next.perAccount = Dictionary(uniqueKeysWithValues: states.compactMap { s in s.position.map { (s.spec.account, $0) } })
        }
        return (out, next)
    }

    static func ascending(_ box: SystemMailbox) -> Bool { [.snoozed, .scheduled, .reminders, .waiting].contains(box) }

    static func streams(_ accounts: [AccountItem], _ box: SystemMailbox) -> [Stream] {
        accounts.map { ($0.id, .system($0.id, box)) }
    }

    static func result(_ items: [ThreadListItem], next: ThreadCursor?, mapper: Mapper, extraLabels: [String] = [],
                       split: String? = nil, key: String = "threads") -> CommandResult {
        let values = items.map { mapper.thread($0, extraLabels: extraLabels, split: split) }
        return CommandResult(data: obj([key: .array(values)]), items: values,
                             table: Table(columns: CommandCatalog.threadColumns, rows: items.map(mapper.threadRow)),
                             nextCursor: next?.encoded)
    }

    static func resolveLabel(_ text: String, store: MailStore, account: AccountItem) throws -> LabelItem {
        let all = try store.labels(account: account.id).filter { $0.kind == .system || $0.kind == .category || $0.kind == .user }
        if let byKey = all.first(where: { $0.key == text }) { return byKey }
        let lowered = text.lowercased()
        let byName = all.filter { $0.name.lowercased() == lowered || $0.key.lowercased() == lowered }
        if byName.count > 1 { throw CLIError.usage("That label name is ambiguous.", code: "ambiguous_label") }
        guard let found = byName.first else { throw CLIError.notFound("The label") }
        return found
    }
}

struct Gmail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read mail in the local cache; drafts for review.",
        subcommands: [
            GmailSearch.self, GmailList.self, GmailInbox.self, GmailGet.self, ThreadGroup.self, BatchGroup.self,
            GmailDone.self, GmailMoveToInbox.self, GmailRead.self, GmailUnread.self, GmailStar.self, GmailUnstar.self,
            GmailTrash.self, GmailUntrash.self, GmailSpam.self, GmailNotSpam.self,
            GmailSnooze.self, GmailUnsnooze.self, GmailRemind.self, GmailUnremind.self, GmailUndo.self,
            LabelsGroup.self, GmailCounts.self, SplitsGroup.self, DraftsGroup.self, ReviewGroup.self,
            SnippetsGroup.self, AttachmentsGroup.self, GmailHistory.self,
            GmailSend.self, GmailReplyReserved.self, GmailReplyAll.self, GmailForward.self, GmailFilters.self,
        ])
}

struct GmailSearch: CLICommand {
    static let path = "gmail.search"
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search the local cache (FTS5; Gmail operators).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var paging: PagingOptions
    @Argument(help: "Query, e.g. `from:alice has:attachment invoice`.") var query: String
    @Flag(name: .long, help: "Search the local cache (default).") var local = false
    @Flag(name: .long, help: "Search Gmail itself (needs the network: exits 12 in Phase 1).") var remote = false
    @Flag(name: .long, help: "Local, plus Gmail when the cache is incomplete (Phase 1: local only).") var auto = false
    @Flag(name: .long, help: "Include the matching messages of each thread.") var messages = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        if remote { throw CLIError.appRequired("--remote needs Gmail access, which only OpenHuman Mail has in Phase 1.") }
        let (limit, cursor) = try paging.validated()
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        ctx.noteReauth(accounts)
        let parsed = try store.parseSearch(query)
        let page = try store.search(parsed, accounts: accounts.map(\.id), after: cursor, limit: limit)
        let mapper = try Mapper(store: store)
        var values: [OutValue] = []
        for hit in page.hits {
            var value = mapper.thread(hit.thread)
            if messages, case .object(var fields) = value, let detail = try store.threadDetail(hit.thread.id) {
                let wanted = Set(hit.matchedMessageIDs)
                fields["matchedMessages"] = .array(detail.messages.filter { wanted.contains($0.id) }.map {
                    mapper.message($0, account: hit.thread.ref.accountID, thread: hit.thread.ref.gmailThreadID, body: nil, detail: .none).value
                })
                value = .object(fields)
            }
            values.append(value)
        }
        var warnings: [String] = []
        for reason in page.completeness.reasons {
            switch reason {
            case .olderMailNeedsGmailFallback(_, let back):
                warnings.append("backfill incomplete: results may miss mail before \(back.map { String(OutValue.iso($0).prefix(10)) } ?? "the cached range")")
            case .bodiesPartiallyIndexed(let n):
                warnings.append("\(n) message bodies are not downloaded yet; words deep in a body may not match")
            case .candidateLimitReached(let n):
                warnings.append("more than \(n) messages matched; only the newest were ranked")
            }
        }
        return CommandResult(data: obj(["query": .untrusted(query), "threads": .array(values)]), items: values,
                             table: Table(columns: CommandCatalog.threadColumns, rows: page.hits.map { mapper.threadRow($0.thread) }),
                             nextCursor: page.nextCursor?.encoded, warnings: warnings)
    }
}

struct GmailList: CLICommand {
    static let path = "gmail.list"
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List threads of a label or view.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var paging: PagingOptions
    @Option(name: .long, help: "Label name or id (one account).") var label: String?
    @Option(name: .long, help: "View: inbox, starred, important, unread, sent, drafts, all, trash, spam, snoozed, scheduled, reminders.") var view: String?
    @Flag(name: .long, help: "Only unread threads.") var unread = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        if label != nil, view != nil { throw CLIError.usage("Pass --label or --view, not both.") }
        let (limit, cursor) = try paging.validated()
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        ctx.noteReauth(accounts)
        let mapper = try Mapper(store: store)
        var streams: [Listing.Stream]
        var ascending = false
        var extra: [String] = []
        if let label {
            guard accounts.count == 1 else { throw CLIError.usage("--label works on one account. Pass --account <email>.", code: "account_required") }
            let item = try Listing.resolveLabel(label, store: store, account: accounts[0])
            if let box = Listing.systemKeys[item.key] {
                streams = Listing.streams(accounts, box)
                extra = Listing.labelOfMailbox[box].map { [$0] } ?? []
            } else {
                streams = [(accounts[0].id, .label(accounts[0].id, GmailLabelID(item.key)))]
                extra = [item.kind == .user ? item.name : item.key]
            }
        } else {
            let name = (view ?? "inbox").lowercased()
            guard let box = Listing.viewNames[name] else {
                throw CLIError.usage("Unknown view. Use one of: \(Listing.viewNames.keys.sorted().joined(separator: ", ")).", code: "bad_view")
            }
            streams = Listing.streams(accounts, box)
            ascending = Listing.ascending(box)
            extra = Listing.labelOfMailbox[box].map { [$0] } ?? []
        }
        let (items, next) = try Listing.collect(store, streams: streams, ascending: ascending, after: cursor, limit: limit,
                                                keep: { !unread || $0.isUnread })
        return Listing.result(items, next: next, mapper: mapper, extraLabels: extra)
    }
}

struct GmailInbox: CLICommand {
    static let path = "gmail.inbox"
    static let configuration = CommandConfiguration(commandName: "inbox", abstract: "The inbox, or one split of it.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var paging: PagingOptions
    @Option(name: .long, help: "Split name or id.") var split: String?
    @Flag(name: .long, help: "Threads in no split.") var other = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        if split != nil, other { throw CLIError.usage("Pass --split or --other, not both.") }
        let (limit, cursor) = try paging.validated()
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        ctx.noteReauth(accounts)
        let mapper = try Mapper(store: store)
        if let split {
            return try splitResult(ctx, store: store, accounts: accounts, mapper: mapper, split: split, limit: limit, cursor: cursor)
        }
        if other {
            guard accounts.count == 1 else { throw CLIError.usage("--other works on one account. Pass --account <email>.", code: "account_required") }
            let (items, next) = try Listing.collect(store, streams: [(accounts[0].id, .splitOther(accounts[0].id))], ascending: false,
                                                    after: cursor, limit: limit)
            return Listing.result(items, next: next, mapper: mapper, extraLabels: ["INBOX"], split: "Other")
        }
        let (items, next) = try Listing.collect(store, streams: Listing.streams(accounts, .inbox), ascending: false,
                                                after: cursor, limit: limit)
        return Listing.result(items, next: next, mapper: mapper, extraLabels: ["INBOX"])
    }
}

func splitResult(_ ctx: CLIContext, store: MailStore, accounts: [AccountItem], mapper: Mapper, split: String,
                 limit: Int, cursor: ThreadCursor?) throws -> CommandResult {
    guard accounts.count == 1 else { throw CLIError.usage("Splits belong to one account. Pass --account <email>.", code: "account_required") }
    let all = try store.splits(account: accounts[0].id)
    let lowered = split.lowercased()
    let matches = all.filter { $0.id.rawValue == split || $0.name.lowercased() == lowered }
    if matches.count > 1 { throw CLIError.usage("That split name is ambiguous.", code: "ambiguous_split") }
    guard let found = matches.first else { throw CLIError.notFound("The split") }
    let (items, next) = try Listing.collect(store, streams: [(accounts[0].id, .split(accounts[0].id, found.id))], ascending: false,
                                            after: cursor, limit: limit)
    return Listing.result(items, next: next, mapper: mapper, extraLabels: ["INBOX"], split: found.name)
}

struct GmailGet: CLICommand {
    static let path = "gmail.get"
    static let configuration = CommandConfiguration(commandName: "get", abstract: "One cached message.")
    enum Format: String, ExpressibleByArgument, CaseIterable { case full, metadata, text, html, raw }
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail message id.") var messageId: String
    @Option(name: .long, help: "full, metadata, text, html or raw (raw needs the network: exits 12).") var format: Format = .full
    @Option(name: .long, help: "Only these headers, comma separated.") var headers: String?
    @Flag(name: .long, help: "Download a missing body (needs the network: exits 12).") var fetch = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        if format == .raw { throw CLIError.appRequired("--format raw needs Gmail access, which only OpenHuman Mail has in Phase 1.") }
        if fetch { throw CLIError.appRequired("--fetch needs Gmail access, which only OpenHuman Mail has in Phase 1.") }
        let store = try ctx.store()
        let accounts = try ctx.lookupAccounts()
        ctx.noteReauth(accounts)
        var found: (AccountItem, MessageItem)?
        for account in accounts {
            if let item = try store.message(account: account.id, gmailMessageID: GmailMessageID(messageId)) {
                if found != nil { throw CLIError.usage("That id exists in several accounts. Pass --account <email>.", code: "ambiguous_account") }
                found = (account, item)
            }
        }
        guard let (account, message) = found else { throw CLIError.notFound("The message", id: messageId) }
        guard let key = try store.messageKey(message.id) else { throw CLIError.notFound("The message", id: messageId) }
        let detail: Mapper.BodyDetail = format == .metadata ? .none : (format == .html ? .html : .text)
        let body = detail == .none ? nil : try store.body(message.id)
        let mapper = try Mapper(store: store)
        let wanted = headers.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let (value, missing) = mapper.message(message, account: account.id, thread: key.ref.gmailThreadID, body: body, detail: detail,
                                              headers: wanted, includeHeaders: format == .metadata)
        let row: [OutValue] = [.string(message.gmailMessageID.rawValue), .string(key.ref.gmailThreadID.rawValue), OutValue.date(message.date),
                               .untrusted(message.from.map { $0.name ?? $0.email } ?? ""), .untrusted(message.subject),
                               .string(mapper.threadLink(account.id, key.ref.gmailThreadID))]
        return CommandResult(data: value,
                             table: Table(columns: ["messageId", "threadId", "date", "from", "subject", "link"], rows: [row]),
                             warnings: missing ? ["body not downloaded yet; open the thread in OpenHuman Mail"] : [])
    }
}

struct ThreadGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "thread", abstract: "One conversation.",
                                                    subcommands: [ThreadGet.self, ThreadModify.self])
}

struct ThreadGet: CLICommand {
    static let path = "gmail.thread.get"
    static let configuration = CommandConfiguration(commandName: "get", abstract: "A cached thread with its messages.")
    enum Format: String, ExpressibleByArgument, CaseIterable { case full, metadata, text }
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail thread id.") var threadId: String
    @Option(name: .long, help: "metadata (default), text or full.") var format: Format = .metadata
    @Flag(name: .long, help: "Include message bodies.") var bodies = false
    @Flag(name: .long, help: "Download missing bodies (needs the network: exits 12).") var fetch = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        if fetch { throw CLIError.appRequired("--fetch needs Gmail access, which only OpenHuman Mail has in Phase 1.") }
        let store = try ctx.store()
        let accounts = try ctx.lookupAccounts()
        ctx.noteReauth(accounts)
        var found: (AccountItem, ThreadRef)?
        for account in accounts {
            if let ref = try store.thread(account: account.id, gmailThreadID: GmailThreadID(threadId)) {
                if found != nil { throw CLIError.usage("That id exists in several accounts. Pass --account <email>.", code: "ambiguous_account") }
                found = (account, ref)
            }
        }
        guard let (account, ref) = found, let detail = try store.threadDetail(ref.rowID) else {
            throw CLIError.notFound("The thread", id: threadId)
        }
        let mapper = try Mapper(store: store)
        let withBodies = bodies || format != .metadata
        var missing = 0
        var rows: [[OutValue]] = []
        var messages: [OutValue] = []
        for m in detail.messages {
            let body = withBodies ? try store.body(m.id) : nil
            let (value, lacking) = mapper.message(m, account: account.id, thread: ref.gmailThreadID, body: body,
                                                  detail: withBodies ? .text : .none)
            if lacking { missing += 1 }
            messages.append(value)
            rows.append([.string(m.gmailMessageID.rawValue), .string(ref.gmailThreadID.rawValue), OutValue.date(m.date),
                         .untrusted(m.from.map { $0.name ?? $0.email } ?? ""), .untrusted(m.subject),
                         .string(mapper.threadLink(account.id, ref.gmailThreadID))])
        }
        var labels: [String] = []
        for m in detail.messages { for name in mapper.labelNames(m.labelIDs, account: account.id) where !labels.contains(name) { labels.append(name) } }
        var summary = mapper.thread(detail.thread)
        if case .object(var fields) = summary { fields["labels"] = .array(labels.map { .untrusted($0) }); summary = .object(fields) }
        let snooze = detail.snooze.map { s in
            obj(["wakeAt": OutValue.optDate(s.wakeAt), "snoozeUnknown": s.wakeAt == nil ? .bool(true) : nil])
        }
        let data = obj(["thread": summary, "messages": .array(messages), "drafts": .array(detail.drafts.map(mapper.draft)),
                        "snooze": snooze, "reminder": detail.reminder.map { r in obj(["dueAt": OutValue.date(r.dueAt), "condition": .string(r.condition.rawValue)]) }])
        return CommandResult(data: data, items: messages,
                             table: Table(columns: ["messageId", "threadId", "date", "from", "subject", "link"], rows: rows),
                             warnings: missing > 0 ? ["\(missing) message bodies not downloaded yet; open the thread in OpenHuman Mail"] : [])
    }
}

struct LabelsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "labels", abstract: "Labels.",
                                                    subcommands: [LabelsList.self, LabelsCreate.self])
}

struct LabelsList: CLICommand {
    static let path = "gmail.labels.list"
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Labels of the account(s).")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Include thread counts.") var counts = false
    @Flag(name: .long, help: "Include hidden OpenHuman schedule labels.") var all = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        ctx.noteReauth(accounts)
        var values: [OutValue] = []
        var rows: [[OutValue]] = []
        for account in accounts {
            for label in try store.labels(account: account.id) where [.system, .category, .user].contains(label.kind) {
                if !all, Mapper.isHidden(label) { continue }
                values.append(obj([
                    "account": .string(account.email), "labelId": .string(label.key),
                    "name": .untrusted(label.name), "type": .string(label.kind.rawValue),
                    "totalThreads": counts ? .int(label.totalThreads) : nil, "unreadThreads": counts ? .int(label.unreadThreads) : nil,
                    "color": OutValue.optString(label.colorBackground),
                ]))
                rows.append([.string(label.key), .string(account.email), .untrusted(label.name), .string(label.kind.rawValue),
                             .int(label.totalThreads), .int(label.unreadThreads)])
            }
        }
        return CommandResult(data: obj(["labels": .array(values)]), items: values,
                             table: Table(columns: ["labelId", "account", "name", "type", "totalThreads", "unreadThreads"], rows: rows))
    }
}

struct GmailCounts: CLICommand {
    static let path = "gmail.counts"
    static let configuration = CommandConfiguration(commandName: "counts", abstract: "Unread, draft, review and failure counts.")
    @OptionGroup var global: GlobalOptions

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        ctx.noteReauth(accounts)
        var values: [OutValue] = []
        var rows: [[OutValue]] = []
        for account in accounts {
            let c = try store.counts(account: account.id)
            let splits = try store.splits(account: account.id)
            values.append(obj([
                "account": .string(account.email), "inboxUnread": .int(c.inboxUnread), "drafts": .int(c.draftsCount),
                "pendingReview": .int(c.pendingReviewCount), "failedOperations": .int(c.failedOperationCount),
                "splits": .array(splits.map { s in
                    obj(["splitId": .string(s.id.rawValue), "name": .untrusted(s.name), "unread": .int(c.splitUnread[s.id] ?? s.unreadThreads)])
                }),
            ]))
            rows.append([.string(account.email), .int(c.inboxUnread), .int(c.draftsCount), .int(c.pendingReviewCount), .int(c.failedOperationCount)])
        }
        return CommandResult(data: obj(["counts": .array(values)]), items: values,
                             table: Table(columns: ["account", "inboxUnread", "drafts", "pendingReview", "failedOperations"], rows: rows))
    }
}

struct SplitsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "splits", abstract: "Inbox splits.",
        subcommands: [SplitsList.self, SplitsShow.self, SplitsCreate.self, SplitsUpdate.self, SplitsDelete.self, SplitsReorder.self])
}

struct SplitsList: CLICommand {
    static let path = "gmail.splits.list"
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Splits of the account(s).")
    @OptionGroup var global: GlobalOptions

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        ctx.noteReauth(accounts)
        var values: [OutValue] = []
        var rows: [[OutValue]] = []
        for account in accounts {
            for s in try store.splits(account: account.id) {
                values.append(obj([
                    "account": .string(account.email), "splitId": .string(s.id.rawValue), "name": .untrusted(s.name),
                    "position": .int(s.position), "rule": .untrusted(s.ruleText), "enabled": .bool(s.enabled),
                    "unreadThreads": .int(s.unreadThreads), "totalThreads": .int(s.totalThreads),
                ]))
                rows.append([.string(s.id.rawValue), .string(account.email), .untrusted(s.name), .int(s.unreadThreads), .int(s.totalThreads)])
            }
        }
        return CommandResult(data: obj(["splits": .array(values)]), items: values,
                             table: Table(columns: ["splitId", "account", "name", "unreadThreads", "totalThreads"], rows: rows))
    }
}

struct SplitsShow: CLICommand {
    static let path = "gmail.splits.show"
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Threads of one split (alias of inbox --split).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var paging: PagingOptions
    @Argument(help: "Split name or id.") var split: String

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let (limit, cursor) = try paging.validated()
        let store = try ctx.store()
        let accounts = try ctx.accounts(.one)
        ctx.noteReauth(accounts)
        return try splitResult(ctx, store: store, accounts: accounts, mapper: try Mapper(store: store), split: split, limit: limit, cursor: cursor)
    }
}

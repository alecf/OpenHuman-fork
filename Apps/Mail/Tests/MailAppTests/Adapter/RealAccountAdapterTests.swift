import Foundation
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@discardableResult
private func put(_ store: MailStore, _ account: AccountID, id: String, thread: String? = nil, labels: [String] = ["INBOX"],
                 subject: String, from: String = "zoo@list.example", date: Date = now, history: UInt64 = 9_000,
                 unsubscribe: String? = nil, post: String? = nil) throws -> ThreadRef {
    let threadID = GmailThreadID(thread ?? "t-\(id)")
    _ = try store.upsertMessages([MessageUpsert(
        gmailMessageID: GmailMessageID(id), gmailThreadID: threadID, historyID: HistoryID(history), internalDate: date,
        labelIDs: labels.map { GmailLabelID($0) }, snippet: "Synthetic snippet", sizeEstimate: 1_000,
        headers: MessageHeaderFields(
            subject: subject, from: EmailAddress(email: from), to: [EmailAddress(email: FakeCorpus.me.email)], cc: [], bcc: [],
            replyTo: [], date: date, messageID: "<\(id)@fake.example>", inReplyTo: nil, references: [],
            listUnsubscribe: unsubscribe, listUnsubscribePost: post))],
        account: account, generation: 1)
    return try #require(try store.thread(account: account, gmailThreadID: threadID))
}

private func key(_ store: MailStore, _ account: AccountID, _ id: String) throws -> MessageKey {
    let item = try #require(try store.message(account: account, gmailMessageID: GmailMessageID(id)))
    return MessageKey(account: account, rowID: item.id.rawValue, gmailMessageID: GmailMessageID(id))
}

private func missesOlderMail(_ window: ThreadListWindow) -> Bool {
    window.search?.completeness.reasons.contains { reason in
        if case .olderMailNotLocal = reason { return true }
        return false
    } ?? false
}

private func quokkaStore() throws -> (MailStore, AccountID) {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 4, now: now))
    try put(store, account, id: "z1", subject: "Quokka report one", date: now.addingTimeInterval(-60), history: 9_001)
    try put(store, account, id: "z2", subject: "Quokka report two", date: now.addingTimeInterval(-120), history: 9_002)
    try put(store, account, id: "z3", subject: "Quokka notes", from: "keeper@zoo.example", date: now.addingTimeInterval(-180),
            history: 9_003)
    try put(store, account, id: "n1", subject: "Wombat report", date: now.addingTimeInterval(-240), history: 9_004)
    return (store, account)
}

private final class RemoteSearchStub: Sendable {
    let calls = Mutex<[(query: String, account: AccountID)]>([])
    let answer: @Sendable () throws -> [ThreadRef]

    init(answer: @escaping @Sendable () throws -> [ThreadRef]) { self.answer = answer }

    var count: Int { calls.withLock { $0.count } }

    func search(_ query: String, _ account: AccountID) async throws -> [ThreadRef] {
        calls.withLock { $0.append((query, account)) }
        return try answer()
    }
}

struct RealAccountSearchTests {
    @Test(.timeLimit(.minutes(1))) func searchFindsStoredMailThroughThePortTheLocationAndItsPages() async throws {
        let (store, account) = try quokkaStore()
        let adapter = MailStoreAdapter(store: store)

        let results = try await firstValue(adapter.search("quokka", accounts: nil, limit: 10))
        #expect(Set(results.hits.map(\.row.id.gmailThreadID.rawValue)) == ["t-z1", "t-z2", "t-z3"])
        #expect(!results.hasMore)
        #expect(results.hits.allSatisfy { $0.row.id.account == account && !$0.matchedMessageRowIDs.isEmpty })

        let from = try await firstValue(adapter.search("from:keeper@zoo.example", accounts: [account], limit: 10))
        #expect(from.hits.map(\.row.id.gmailThreadID.rawValue) == ["t-z3"])
        let structured = try await firstValue(adapter.search("subject:wombat", accounts: [account], limit: 10))
        #expect(structured.hits.map(\.row.id.gmailThreadID.rawValue) == ["t-n1"])

        let window = try await firstValue(adapter.threadWindow(.search("quokka"), account: account, limit: 2))
        #expect(window.rows.count == 2 && window.hasMore)
        let top = try await adapter.threadPage(.search("quokka"), account: account, after: nil, limit: 2)
        let cursor: PageCursor = try #require(top.next)
        let rest = try await adapter.threadPage(.search("quokka"), account: account, after: cursor, limit: 2)
        #expect(Set((top.rows + rest.rows).map(\.id.gmailThreadID.rawValue)) == ["t-z1", "t-z2", "t-z3"])
        #expect(rest.next == nil)

        let split = try await firstValue(adapter.search("from:zoo@list.example", accounts: [account], limit: 50))
        #expect(split.hits.count == 3)
    }

    @Test(.timeLimit(.minutes(1))) func aQueryTheParserRefusesIsInvalidWithFixedWording() async throws {
        let (store, account) = try quokkaStore()
        let adapter = MailStoreAdapter(store: store)
        await #expect(throws: MailPortError.invalidQuery("check the search operators")) {
            _ = try await firstValue(adapter.search("   ", accounts: nil, limit: 10))
        }
        await #expect(throws: MailPortError.invalidQuery("check the search operators")) {
            _ = try await firstValue(adapter.threadWindow(.search(""), account: account, limit: 10))
        }
    }

    @Test(.timeLimit(.minutes(1))) func theSearchLocationAddsWhatOnlyGmailFoundAndAsksOncePerQuery() async throws {
        let (store, account) = try quokkaStore()
        let stub = RemoteSearchStub {
            [try put(store, account, id: "old1", subject: "Ledger from long ago", date: now.addingTimeInterval(-86_400 * 900),
                     history: 9_100)]
        }
        let adapter = MailStoreAdapter(store: store, onDemand: .init(remoteSearch: { try await stub.search($0, $1) },
                                                                     remoteSearchDelay: .zero))
        let window = try await firstValue(adapter.threadWindow(.search("quokka"), account: account, limit: 50)) {
            $0.rows.count == 4
        }
        #expect(window.rows.prefix(3).allSatisfy { $0.subject.hasPrefix("Quokka") })
        #expect(window.rows.last?.id.gmailThreadID.rawValue == "t-old1")
        #expect(stub.calls.withLock { $0.map(\.query) } == ["quokka"], "the query re-serialized for Gmail (completeness.gmailQuery)")
        #expect(stub.calls.withLock { $0.map(\.account) } == [account])
        #expect(window.search?.gmail == .done(added: 1))
        #expect(window.search?.gmailAvailable == true)
        #expect(missesOlderMail(window))

        let again = try await firstValue(adapter.threadWindow(.search("quokka"), account: account, limit: 250)) {
            $0.rows.count == 4
        }
        #expect(again.rows.map(\.id) == window.rows.map(\.id))
        #expect(again.search?.gmail == .done(added: 1), "the kept answer shows as done at once")
        #expect(stub.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func searchGmailAddsWhatOnlyGmailFoundToTheOpenWindow() async throws {
        let (store, account) = try quokkaStore()
        let stub = RemoteSearchStub {
            [try put(store, account, id: "old2", subject: "Ledger from long ago", date: now.addingTimeInterval(-86_400 * 900),
                     history: 9_100)]
        }
        let adapter = MailStoreAdapter(store: store, onDemand: .init(remoteSearch: { try await stub.search($0, $1) },
                                                                     remoteSearchDelay: .seconds(600)))
        do {
            var windows = adapter.threadWindow(.search("quokka"), account: account, limit: 50).makeAsyncIterator()
            var window = try await windows.next()
            #expect(window?.rows.count == 3)
            #expect(window?.search?.gmailAvailable == true)
            #expect(try await adapter.searchGmail("quokka", account: account) == 1)
            while window != nil, window?.search?.gmail != .done(added: 1) { window = try await windows.next() }
            #expect(window?.rows.count == 4)
            #expect(window?.rows.last?.id.gmailThreadID.rawValue == "t-old2")
            #expect(stub.count == 1, "only the user's ask reached Gmail")
        }
        await eventually("the window stopped listening") { adapter.searchFallback?.observerCount == 0 }
    }

    @Test(.timeLimit(.minutes(1))) func aFailedSearchGmailSaysSoAndKeepsTheLocalHits() async throws {
        let (store, account) = try quokkaStore()
        let stub = RemoteSearchStub { throw URLError(.notConnectedToInternet) }
        let adapter = MailStoreAdapter(store: store, onDemand: .init(remoteSearch: { try await stub.search($0, $1) },
                                                                     remoteSearchDelay: .seconds(600)))
        do {
            var windows = adapter.threadWindow(.search("quokka"), account: account, limit: 50).makeAsyncIterator()
            var window = try await windows.next()
            await #expect(throws: MailPortError.unavailable("Gmail search")) {
                _ = try await adapter.searchGmail("quokka", account: account)
            }
            while window != nil, window?.search?.gmail != .failed { window = try await windows.next() }
            #expect(window?.rows.count == 3, "the local hits stay")
        }
        #expect(adapter.searchFallback?.kept("quokka", account: account) == nil, "a failure is not kept")
    }

    @Test(.timeLimit(.minutes(1))) func withoutGmailTheResultsStillSayTheyMayBeIncomplete() async throws {
        let (store, account) = try quokkaStore()
        let adapter = MailStoreAdapter(store: store)
        let window = try await firstValue(adapter.threadWindow(.search("quokka"), account: account, limit: 50))
        #expect(window.search?.gmailAvailable == false && window.search?.gmail == .notAsked)
        #expect(window.search?.completeness.isComplete == false)
        await #expect(throws: MailPortError.unsupported("Gmail search in this store")) {
            _ = try await adapter.searchGmail("quokka", account: account)
        }
        let results = try await firstValue(adapter.search("quokka", accounts: nil, limit: 10))
        #expect(results.completeness.isComplete == false, "the port's results carry the same signal")
    }

    @Test(.timeLimit(.minutes(1))) func portSearchStaysLocal() async throws {
        let (store, _) = try quokkaStore()
        let stub = RemoteSearchStub { [] }
        let adapter = MailStoreAdapter(store: store, onDemand: .init(remoteSearch: { try await stub.search($0, $1) },
                                                                     remoteSearchDelay: .zero))
        let results = try await firstValue(adapter.search("quokka", accounts: nil, limit: 10))
        #expect(results.hits.count == 3)
        #expect(stub.count == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aFailedGmailSearchKeepsTheLocalHits() async throws {
        let (store, account) = try quokkaStore()
        let stub = RemoteSearchStub { throw MailPortError.unavailable("offline") }
        let fallback = GmailSearchFallback(delay: .zero) { try await stub.search($0, $1) }
        #expect(await fallback.threads(matching: "quokka", account: account) == nil)
        #expect(await fallback.threads(matching: "quokka", account: account) == nil)
        #expect(await fallback.threads(matching: "  ", account: account) == nil, "an empty query never reaches Gmail")
        #expect(stub.count == 2)
        let adapter = MailStoreAdapter(store: store, onDemand: .init(remoteSearch: { try await stub.search($0, $1) },
                                                                     remoteSearchDelay: .zero))
        let window = try await firstValue(adapter.threadWindow(.search("quokka"), account: account, limit: 50))
        #expect(window.rows.count == 3)
    }
}

@MainActor
struct RealAccountFolderTests {
    @Test(.timeLimit(.minutes(1))) func draftsTrashAndSpamListTheirViewsAndLoadTheirFirstScreenOnce() async throws {
        let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 3, now: now))
        try put(store, account, id: "d1", labels: ["DRAFT"], subject: "Unsent thoughts", history: 9_201)
        try put(store, account, id: "x1", labels: ["TRASH"], subject: "Thrown away", history: 9_202)
        try put(store, account, id: "s1", labels: ["SPAM"], subject: "Prize inside", history: 9_203)
        let loads = Mutex<[MailboxView]>([])
        let failFirst = Mutex(true)
        let adapter = MailStoreAdapter(store: store, onDemand: .init(loadView: { view in
            loads.withLock { $0.append(view) }
            guard view == .system(account, .spam) else { return }
            let fail = failFirst.withLock { pending in
                let was = pending
                pending = false
                return was
            }
            if fail {
                throw MailPortError.unavailable("offline")
            }
        }))

        for (folder, thread) in [(SystemFolder.drafts, "t-d1"), (.trash, "t-x1"), (.spam, "t-s1")] {
            let window = try await firstValue(adapter.threadWindow(.system(folder), account: account, limit: 50))
            #expect(window.rows.map(\.id.gmailThreadID.rawValue) == [thread], "\(folder)")
        }
        await eventually("three loads", timeout: .seconds(30)) { loads.withLock { $0.count } == 3 }
        await eventually("the failed load is forgotten", timeout: .seconds(30)) {
            adapter.viewLoader?.openedViews == [.system(account, .drafts), .system(account, .trash)]
        }
        for folder in [SystemFolder.drafts, .trash, .spam, .inbox, .starred] {
            _ = try await firstValue(adapter.threadWindow(.system(folder), account: account, limit: 50))
        }
        await eventually("the spam retry", timeout: .seconds(30)) { loads.withLock { $0.count } == 4 }
        #expect(loads.withLock { $0 }.last == .system(account, .spam))
        #expect(!loads.withLock { $0 }.contains(.system(account, .inbox)), "views the backfill covers are not loaded")
    }
}

struct RealAccountSystemTests {
    @Test(.timeLimit(.minutes(1))) func remindersMapForTheNotificationMirror() async throws {
        let (store, account) = try quokkaStore()
        let ref = try #require(try store.thread(account: account, gmailThreadID: GmailThreadID("t-z1")))
        let due = now.addingTimeInterval(3_600)
        _ = try store.apply(.setReminder(ref, dueAt: due, condition: .ifNoReply), origin: .app)
        let adapter = MailStoreAdapter(store: store)
        let items = try await firstValue(adapter.reminders(nil)) { !$0.isEmpty }
        let item = try #require(items.first)
        #expect(item.thread == MailStoreAdapter.threadKey(ref))
        #expect(item.subject == "Quokka report one")
        #expect(item.dueAt == due)
        #expect(item.kind == .ifNoReply)
        #expect(item.notificationIdentifier.hasPrefix("reminder."))
        #expect(try await firstValue(adapter.reminders(AccountID(account.rawValue + 99))).isEmpty)
    }

    @Test func listUnsubscribeHeadersParse() throws {
        let oneClick = ListUnsubscribe(header: "<mailto:u@list.example?subject=stop>, <https://list.example/u/a,b?t=1>",
                                       post: " list-unsubscribe=one-click ")
        #expect(oneClick.oneClick?.absoluteString == "https://list.example/u/a,b?t=1", "a comma inside <…> stays")
        #expect(oneClick.info == .oneClick(host: "list.example"))
        let mailto = ListUnsubscribe(header: "<https://list.example/prefs>,\r\n <mailto:u@list.example?subject=stop%20it>",
                                     post: nil)
        #expect(mailto.info == .mailto(EmailAddress(email: "u@list.example"), subject: "stop it"))
        #expect(ListUnsubscribe(header: "<https://list.example/prefs>", post: nil).info
                == .link(URL(string: "https://list.example/prefs")!))
        #expect(ListUnsubscribe(header: "<http://list.example/u>", post: ListUnsubscribe.oneClickValue).info == nil)
        #expect(ListUnsubscribe(header: "<mailto:a@x.example,b@x.example>", post: nil).info == nil)
        #expect(ListUnsubscribe(header: "https://list.example/u", post: ListUnsubscribe.oneClickValue).info == nil)
        #expect(ListUnsubscribe(header: nil, post: nil).info == nil)
        #expect(ListUnsubscribe(header: "<http://a.example/u>, <mailto:u@a.example>", post: ListUnsubscribe.oneClickValue).info
                == .mailto(EmailAddress(email: "u@a.example"), subject: nil))
        for info in [UnsubscribeInfo.oneClick(host: "news.example"),
                     .mailto(EmailAddress(email: "unsubscribe@news.example"), subject: "unsubscribe"),
                     .link(URL(string: "https://news.example/preferences")!)] {
            let headers = FixtureStoreSeeder.listUnsubscribe(info)
            #expect(ListUnsubscribe(header: headers.header, post: headers.post).info == info)
        }
    }

    @Test(.timeLimit(.minutes(1))) func unsubscribeInfoComesFromTheStoredHeaders() async throws {
        let (store, account) = try quokkaStore()
        try put(store, account, id: "news1", subject: "Weekly digest", history: 9_301,
                unsubscribe: "<https://list.example/u/token-1>", post: ListUnsubscribe.oneClickValue)
        let adapter = MailStoreAdapter(store: store)
        #expect(try await adapter.unsubscribeInfo(try key(store, account, "news1")) == .oneClick(host: "list.example"))
        #expect(try await adapter.unsubscribeInfo(try key(store, account, "z1")) == nil)
        await #expect(throws: MailPortError.notFound("message")) {
            _ = try await adapter.unsubscribeInfo(MessageKey(account: account, rowID: 1, gmailMessageID: GmailMessageID("gone")))
        }
    }

    @Test(.timeLimit(.minutes(1))) func theOneClickRequestPostsOnceThroughItsGuard() async throws {
        let (store, account) = try quokkaStore()
        try put(store, account, id: "news1", subject: "Weekly digest", history: 9_301,
                unsubscribe: "<mailto:u@list.example>, <https://list.example/u/token-1>", post: ListUnsubscribe.oneClickValue)
        try put(store, account, id: "news2", subject: "Monthly digest", history: 9_302,
                unsubscribe: "<https://list.example/u/token-2/delete>", post: ListUnsubscribe.oneClickValue)
        try put(store, account, id: "news3", subject: "Promo", history: 9_303, unsubscribe: "<https://list.example/prefs>")
        let http = FakeHTTPTransport()
        http.on("POST", "/u/") { _ in HTTPResponse(status: 200, headers: [:], body: Data()) }

        try await OneClickUnsubscribe(store: store, transport: http).send(try key(store, account, "news1"))
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.method == "POST" && request.url.absoluteString == "https://list.example/u/token-1")
        #expect(request.body == Data("List-Unsubscribe=One-Click".utf8))
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.timeout == .seconds(10))

        await #expect(throws: MailPortError.notAllowed(OneClickUnsubscribe.refusal), "the guard refuses a delete path") {
            try await OneClickUnsubscribe(store: store, transport: http).send(try key(store, account, "news2"))
        }
        await #expect(throws: MailPortError.notFound("one-click unsubscribe")) {
            try await OneClickUnsubscribe(store: store, transport: http).send(try key(store, account, "news3"))
        }
        #expect(http.requests.count == 1, "nothing else left the process")

        let refusing = FakeHTTPTransport()
        refusing.on("POST", "/") { _ in HTTPResponse(status: 500, headers: [:], body: Data()) }
        await #expect(throws: MailPortError.unavailable("the list didn't accept the unsubscribe request")) {
            try await OneClickUnsubscribe(store: store, transport: refusing).send(try key(store, account, "news1"))
        }
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func diagnosticsAreCountsAndCodesOnly() async throws {
        let corpus = FakeCorpus.make(threadCount: 12, now: now)
        let (store, account) = try FixtureStoreSeeder.makeStore(corpus: corpus)
        try put(store, account, id: "d1", labels: ["DRAFT"], subject: "MARKER draft subject", from: "marker@secret.example",
                history: 9_401)
        let adapter = MailStoreAdapter(store: store)
        let snapshot = try await adapter.diagnosticsSnapshot()
        #expect(snapshot.schemaVersion == 2)
        let entry = try #require(snapshot.accounts.first)
        #expect(snapshot.accounts.count == 1 && entry.index == 1)
        #expect(entry.health == "active")
        #expect(entry.connectivity.hasPrefix("online"), "no sync row: the Store's view")
        #expect(entry.threadCount > 0 && entry.messageCount >= entry.threadCount)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: try encoder.encode(snapshot), encoding: .utf8))
        var markers = ["MARKER", "marker@secret.example", FakeCorpus.me.email]
        for thread in corpus.threads {
            markers.append(thread.detail.subject)
            markers += thread.detail.messages.compactMap { $0.from?.email }
        }
        for marker in Set(markers) where marker.count >= 6 { #expect(!json.contains(marker), "\(marker)") }

        let exporter = DiagnosticsExporter(
            data: adapter, info: { DiagnosticsAppInfo(version: "0", build: "0", gitCommit: "test", os: "macOS", dataMode: "test") },
            modules: { [:] })
        #expect(try await exporter.build().count > 100)
    }
}

import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ReadPathEndToEndTests {
    @Test(.timeLimit(.minutes(1))) func syncListOpenAndBodySendOnlyGETs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-readpath-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                    appVersion: "0.0.0-test"))
        let gmail = FakeGmail(accountEmail: "me@example.com", clock: SystemClock(), startDate: mailStart)
        var threads: [String] = []
        for n in 0..<60 {
            let first = await gmail.deliver(subject: "Thread \(n)", body: "Body \(n) first.")
            if n % 5 == 0 {
                await gmail.deliver(from: "Bo Example <bo@example.com>", subject: "Re: Thread \(n)",
                                    body: "Body \(n) second.", html: "<p>Body \(n) <b>second</b>.</p>",
                                    threadID: first.threadID)
            }
            threads.append(first.threadID)
        }
        let wire = FakeGmailTransport(gmail)
        let metrics = SyncMetricsCollector()
        let factory = DefaultGmailClientFactory(apiTransport: wire,
                                                config: GmailClientConfig(userAgent: "OpenHumanMail/test"),
                                                clock: SystemClock(), metrics: { _ in metrics }) { _ in
            (StaticTokenProvider(), [GmailScope.modify])
        }
        let api = try factory.client(for: "me@example.com")
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let syncer = AccountSyncer(account: account, store: store, api: api, clock: SystemClock(), metrics: metrics)
        let loop = SyncLoop(syncer: syncer, store: store, clock: SystemClock(), interval: .seconds(3600))
        await loop.start()
        defer { Task { await loop.stop() } }
        try await eventually("first sync") { await loop.completedRuns == 1 }

        let page = try store.threadPage(view: .system(account, .inbox), after: nil, limit: 100)
        let serverTop = try await gmail.listThreads(ListQuery(labelIDs: ["INBOX"], maxResults: 50), priority: .sync)
            .threads?.map(\.id) ?? []
        #expect(page.items.count == 50)
        #expect(page.items.map(\.ref.gmailThreadID.rawValue) == serverTop)
        #expect(try store.syncStatus(account: account).phase == .inboxReady)

        let item = try #require(page.items.dropFirst(10).first { $0.messageCount == 2 })
        let detail = try #require(try store.threadDetail(item.id))
        let last = try #require(detail.messages.last)
        #expect(try store.body(last.id) == nil)
        let before = wire.requests.count
        let fetcher = BodyFetcher(account: account, store: store, api: api)
        #expect(try await fetcher.ensureBody(last.gmailMessageID))
        let body = try #require(try store.body(last.id))
        #expect(body.text?.contains("second.") == true)
        #expect(body.html?.contains("<b>second</b>") == true)
        let opened = wire.requests[before...]
        #expect(opened.count == 1)
        #expect(opened.allSatisfy {
            $0.url.path.hasSuffix("/messages/\(last.gmailMessageID.rawValue)")
                && URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(URLQueryItem(name: "format", value: "full")) == true
        })

        await gmail.deliver(subject: "Fresh", body: "Fresh body.")
        await loop.poke()
        try await eventually("delta") { await loop.completedRuns == 2 }
        #expect(try store.threadPage(view: .system(account, .inbox), after: nil, limit: 1).items.first?.subject == "Fresh")

        #expect(!wire.requests.isEmpty)
        #expect(wire.nonGETRequests.isEmpty)
        #expect(await gmail.labelIDs(ofMessage: last.gmailMessageID.rawValue)?.contains("INBOX") == true)
    }
}

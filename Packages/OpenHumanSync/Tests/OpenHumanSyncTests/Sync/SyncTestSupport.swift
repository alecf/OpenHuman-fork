import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

let testNow = Date(timeIntervalSince1970: 1_790_000_000)
let mailStart = Date(timeIntervalSince1970: 1_789_900_000)

struct SyncHarness {
    let store: MailStore
    let account: AccountID
    let gmail: FakeGmail
    let clock: any OHClock
    let metrics: SyncMetricsCollector
    let syncer: AccountSyncer
    let recorder: RecordingGmail?
    let location: StoreLocation?
    let temporary: TemporaryDirectory?

    init(settings: SyncSettings = SyncSettings(), clock: any OHClock = InstantClock(now: testNow), onDisk: Bool = false,
         recording: Bool = false, api: ((FakeGmail) -> any GmailAPI)? = nil) throws {
        if onDisk {
            let temporary = TemporaryDirectory("oh-sync")
            self.temporary = temporary
            let directory = temporary.url
            location = StoreLocation(directory: directory)
            store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                    appVersion: "0.0.0-test"))
        } else {
            temporary = nil
            location = nil
            store = try MailStore.openInMemoryForTesting()
        }
        account = try store.addAccount(email: "me@example.com", displayName: "Me", scopes: [GmailScope.readonly])
        self.clock = clock
        metrics = SyncMetricsCollector()
        gmail = FakeGmail(clock: clock, metrics: api == nil ? metrics : nil, startDate: mailStart)
        recorder = recording ? RecordingGmail(gmail) : nil
        let client: any GmailAPI
        if let api { client = api(gmail) } else if let recorder { client = recorder } else { client = gmail }
        syncer = AccountSyncer(account: account, store: store, api: client, clock: clock, settings: settings,
                               metrics: metrics)
    }

    func status() throws -> SyncStatus { try store.syncStatus(account: account) }

    func inbox() throws -> [String] {
        try store.threadPage(view: .system(account, .inbox), after: nil, limit: 500).items.map(\.ref.gmailThreadID.rawValue)
    }

    func serverInbox(limit: Int = 500) async throws -> [String] {
        try await gmail.listThreads(ListQuery(labelIDs: ["INBOX"], maxResults: limit), priority: .sync).threads?.map(\.id) ?? []
    }

    func fullInbox() throws -> [ThreadListItem] {
        var items: [ThreadListItem] = []
        var cursor: ThreadCursor?
        repeat {
            let page = try store.threadPage(view: .system(account, .inbox), after: cursor, limit: 500)
            items += page.items
            cursor = page.nextCursor
        } while cursor != nil
        return items
    }

    func message(_ id: String) throws -> MessageItem? {
        try store.message(account: account, gmailMessageID: GmailMessageID(id))
    }

    func thread(_ id: String) throws -> ThreadDetail? {
        guard let ref = try store.thread(account: account, gmailThreadID: GmailThreadID(id)) else { return nil }
        return try store.threadDetail(ref.rowID)
    }
}

func eventually(_ what: String = "condition", _ condition: () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(120)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("never became true (120 s backstop): \(what)")
}

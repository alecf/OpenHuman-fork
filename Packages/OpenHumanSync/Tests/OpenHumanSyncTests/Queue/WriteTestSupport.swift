import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

struct WriteHarness {
    let store: MailStore
    let account: AccountID
    let gmail: FakeGmail
    let wire: FakeGmailTransport
    let factory: DefaultGmailClientFactory
    let clock: any OHClock
    let syncer: AccountSyncer
    let threads: [String]

    init(scopes: [String] = [GmailScope.modify], clock: any OHClock = InstantClock(now: testNow),
         threads count: Int = 3, onDisk: Bool = false) async throws {
        if onDisk {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-write-\(UUID().uuidString)")
            store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                    appVersion: "0.0.0-test",
                                                    changeNotificationName: "dev.openhuman.test.\(UUID().uuidString)"))
        } else {
            store = try MailStore.openInMemoryForTesting()
        }
        account = try store.addAccount(email: "me@example.com", displayName: "Me", scopes: scopes)
        self.clock = clock
        gmail = FakeGmail(clock: clock, startDate: mailStart)
        let wire = FakeGmailTransport(gmail)
        self.wire = wire
        factory = DefaultGmailClientFactory(apiTransport: wire,
                                            config: GmailClientConfig(userAgent: "OpenHumanMail/test"), clock: clock) { _ in
            (StaticTokenProvider(), scopes)
        }
        syncer = AccountSyncer(account: account, store: store, api: try factory.client(for: "me@example.com"), clock: clock)
        threads = await gmail.seedInbox(count: count)
        try await syncer.sync(reason: "launch")
    }

    var client: any GmailAPI { get throws { try factory.client(for: "me@example.com") } }

    func ref(_ thread: String) throws -> ThreadRef {
        try #require(try store.thread(account: account, gmailThreadID: GmailThreadID(thread)))
    }

    func inbox() throws -> [String] {
        try store.threadPage(view: .system(account, .inbox), after: nil, limit: 500).items.map(\.ref.gmailThreadID.rawValue)
    }

    func serverInbox() async throws -> [String] {
        try await gmail.listThreads(ListQuery(labelIDs: ["INBOX"], maxResults: 500), priority: .sync).threads?.map(\.id) ?? []
    }

    func serverLabels(ofThread thread: String) async -> Set<String> {
        var all = Set<String>()
        for id in await gmail.messageIDs(inThread: thread) { all.formUnion(await gmail.labelIDs(ofMessage: id) ?? []) }
        return all
    }

    func ops(_ statuses: Set<OperationStatus> = []) throws -> [OperationItem] {
        try store.operations(account: account, statuses: statuses, limit: 500)
    }

    func drainer(api: any GmailAPI, events: EventLog = EventLog(), applied: Counter? = nil) -> OperationDrainer {
        OperationDrainer(account: account, store: store, api: api, clock: clock, storeClock: clock, ownerID: "test-owner",
                         emit: { events.append($0) }, onApplied: { _ in applied?.increment() })
    }
}

final class EventLog: Sendable {
    private let events = Mutex<[EngineEvent]>([])
    func append(_ event: EngineEvent) { events.withLock { $0.append(event) } }
    var all: [EngineEvent] { events.withLock { $0 } }
    var failedOperations: [OperationItem] {
        all.compactMap { if case let .operationFailed(item) = $0 { return item } else { return nil } }
    }
}

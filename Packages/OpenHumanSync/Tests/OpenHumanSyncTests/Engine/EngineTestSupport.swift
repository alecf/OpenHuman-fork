import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

func currentMinute() -> Date {
    Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
}

let engineGmailConfig = GmailClientConfig(
    unitsPerMinute: 600_000,
    retryBackground: RetryPolicy(maxAttempts: 1, baseDelay: .seconds(1), maxDelay: .seconds(1), maxRetryAfter: .seconds(1)),
    retryInteractive: RetryPolicy(maxAttempts: 1, baseDelay: .seconds(1), maxDelay: .seconds(1), maxRetryAfter: .seconds(1)),
    userAgent: "OpenHumanMail/engine-test")

struct DirectGmailFactory: GmailClientFactory {
    let gmail: FakeGmail
    func client(for accountEmail: String) throws -> GmailAPI { gmail }
}

struct FixedGmailFactory: GmailClientFactory {
    let api: any GmailAPI
    func client(for accountEmail: String) throws -> GmailAPI { api }
}

struct EngineHarness {
    let store: MailStore
    let account: AccountID
    let gmail: FakeGmail
    let clock: TestClock
    let wire: FakeGmailTransport?
    let factory: GmailClientFactory
    let threads: [String]
    let directory: URL?

    init(safeMode: SafeMode = .normal, scopes: [String] = [GmailScope.modify], stack: Bool = false,
         onDisk: Bool = false, threads count: Int = 3, clock: TestClock? = nil, gmail: FakeGmail? = nil,
         email: String = "me@example.com") async throws {
        let clock = clock ?? TestClock(now: currentMinute())
        self.clock = clock
        if onDisk || stack {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oh-engine-\(UUID().uuidString)")
            directory = dir
            store = try MailStore.open(StoreOptions(location: StoreLocation(directory: dir), processKind: .test,
                                                    appVersion: "0.0.0-test",
                                                    changeNotificationName: "dev.openhuman.test.\(UUID().uuidString)"))
        } else {
            directory = nil
            store = try MailStore.openInMemoryForTesting()
        }
        account = try store.addAccount(email: email, displayName: "Me", scopes: scopes)
        let gmail = gmail ?? FakeGmail(accountEmail: email, clock: clock,
                                       startDate: clock.now.addingTimeInterval(-86_400))
        self.gmail = gmail
        if stack {
            let wire = FakeGmailTransport(gmail)
            self.wire = wire
            factory = DefaultGmailClientFactory(safeMode: safeMode, apiTransport: wire, config: engineGmailConfig,
                                                clock: clock, storeDirectory: directory) { _ in
                (StaticTokenProvider(), scopes)
            }
        } else {
            wire = nil
            factory = DirectGmailFactory(gmail: gmail)
        }
        threads = count > 0 ? await gmail.seedInbox(count: count) : []
    }

    func engine(role: EngineRole = .app, safeMode: SafeMode = .normal,
                schedulers: Set<ScheduleKind> = Set(ScheduleKind.allCases), factory: GmailClientFactory?? = nil,
                tokenStore: TokenStore? = nil, systemEvents: SystemEventsSource? = nil,
                store: MailStore? = nil) -> MailEngine {
        MailEngine(store: store ?? self.store, gmailFactory: factory ?? self.factory, tokenStore: tokenStore,
                   oauthClient: nil,
                   configuration: EngineConfiguration(role: role, appVersion: "0.0.0-test", gmail: engineGmailConfig,
                                                      clock: clock, schedulers: schedulers, safeMode: safeMode),
                   systemEvents: systemEvents)
    }

    func ref(_ thread: String) throws -> ThreadRef {
        try #require(try store.thread(account: account, gmailThreadID: GmailThreadID(thread)))
    }

    func inbox() throws -> [String] {
        try store.threadPage(view: .system(account, .inbox), after: nil, limit: 500).items.map(\.ref.gmailThreadID.rawValue)
    }

    func serverLabels(ofThread thread: String) async -> Set<String> {
        var all = Set<String>()
        for id in await gmail.messageIDs(inThread: thread) { all.formUnion(await gmail.labelIDs(ofMessage: id) ?? []) }
        return all
    }

    func ops(_ statuses: Set<OperationStatus> = []) throws -> [OperationItem] {
        try store.operations(account: account, statuses: statuses, limit: 500)
    }

    func waitForSyncs(_ engine: MailEngine, _ runs: Int = 1) async throws {
        let account = self.account
        try await eventually("\(runs) sync run(s)") {
            guard let runtime = await engine.runtime(for: account) else { return false }
            let armed = await runtime.nextPollAt != nil
            return await runtime.completedRuns + runtime.failedRuns >= runs && armed
        }
    }

    func waitForSchedulerIdle(_ engine: MailEngine, passes: Int = 1) async throws {
        let account = self.account
        try await eventually("scheduler idle after \(passes) pass(es)") {
            guard let scheduler = await engine.scheduler(for: account) else { return false }
            let fire = await scheduler.nextFire
            return await scheduler.passes >= passes && fire != nil
        }
    }

    func snoozeOnServer(_ thread: String, until wake: Date) async -> String {
        let stamp = ScheduleLabel(kind: .snoozed, due: wake).name
        var marker = await gmail.labelID(named: OHGmailLabels.snoozed)
        if marker == nil { marker = await gmail.addUserLabel(OHGmailLabels.snoozed) }
        var stampID = await gmail.labelID(named: stamp)
        if stampID == nil { stampID = await gmail.addUserLabel(stamp) }
        for message in await gmail.messageIDs(inThread: thread) {
            await gmail.modifyLabels(messageID: message, add: [marker, stampID].compactMap { $0 }, remove: ["INBOX"])
        }
        return stamp
    }

    func cleanup() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func advancePast(_ receipt: SendReceipt) {
        if clock.now <= receipt.sendAfter { clock.advance(to: receipt.sendAfter.addingTimeInterval(1)) }
    }

    func sentOnGmail() async throws -> [String] { try await OpenHumanSyncTests.sentOnGmail(gmail) }

    func rawOnGmail(_ messageID: String) async throws -> String { try await OpenHumanSyncTests.rawOnGmail(gmail, messageID) }

    func labelNames(ofMessage id: String) async -> Set<String> { await OpenHumanSyncTests.labelNames(gmail, ofMessage: id) }

    func expectOneCleanSentMessage(_ what: String = "sent", sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let sent = try await sentOnGmail()
        #expect(sent.count == 1, "\(what): \(sent.count) SENT message(s)", sourceLocation: sourceLocation)
        for id in sent {
            #expect(lines(try await rawOnGmail(id), startingWith: "x-openhuman-").isEmpty, "\(what)",
                    sourceLocation: sourceLocation)
            #expect(!(await labelNames(ofMessage: id)).contains { DraftMessage.isMarkerLabel($0) }, "\(what)",
                    sourceLocation: sourceLocation)
        }
        for delivery in await gmail.deliveries() {
            #expect(lines(String(decoding: delivery.raw, as: UTF8.self), startingWith: "x-openhuman-").isEmpty, "\(what)",
                    sourceLocation: sourceLocation)
        }
    }
}

final class EngineEvents: Sendable {
    private final class Storage: Sendable {
        let events = Mutex<[EngineEvent]>([])
    }
    private let storage = Storage()
    private let task: Task<Void, Never>

    init(_ engine: MailEngine) {
        let stream = engine.events
        let storage = self.storage
        task = Task { for await event in stream { storage.events.withLock { $0.append(event) } } }
    }

    deinit { task.cancel() }

    var all: [EngineEvent] { storage.events.withLock { $0 } }

    var remindersFired: [(ThreadRef, Duration)] {
        all.compactMap { if case let .reminderFired(ref, overdue) = $0 { return (ref, overdue) } else { return nil } }
    }
    var snoozesWoken: [(ThreadRef, Duration)] {
        all.compactMap { if case let .snoozeWoke(ref, overdue) = $0 { return (ref, overdue) } else { return nil } }
    }
    var failedOperations: [OperationItem] {
        all.compactMap { if case let .operationFailed(item) = $0 { return item } else { return nil } }
    }
    var interruptedSends: [DraftID] {
        all.compactMap { if case let .sendInterrupted(id) = $0 { return id } else { return nil } }
    }
    var sent: [DraftID] {
        all.compactMap { if case let .sent(id, _) = $0 { return id } else { return nil } }
    }
    var sendFailures: [DraftID] {
        all.compactMap { if case let .sendFailed(id, _) = $0 { return id } else { return nil } }
    }
    var needsConfirmation: [DraftID] {
        all.compactMap { if case let .scheduledSendNeedsConfirmation(id) = $0 { return id } else { return nil } }
    }
    var cancelledByReply: [DraftID] {
        all.compactMap { if case let .scheduledSendCancelledByReply(id) = $0 { return id } else { return nil } }
    }
    var degraded: [(ScheduleKind, String)] {
        all.compactMap { if case let .schedulerDegraded(kind, reason) = $0 { return (kind, reason) } else { return nil } }
    }
    var ownership: [(AccountID, Bool)] {
        all.compactMap { if case let .ownershipChanged(id, owner) = $0 { return (id, owner) } else { return nil } }
    }
}

final class TestSystemEvents: SystemEventsSource {
    let events: AsyncStream<SystemEvent>
    private let continuation: AsyncStream<SystemEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream(of: SystemEvent.self) }
    func send(_ event: SystemEvent) { continuation.yield(event) }
}

func rawDraft(subject: String = "Synthetic scheduled", body: String = "Synthetic body.", sendAt: Date? = nil,
              origin: String? = nil, to: String = "bob@example.invalid") -> Data {
    var lines = ["From: me@example.com", "To: \(to)", "Subject: \(subject)",
                 "Message-ID: <draft.\(UUID().uuidString.lowercased())@example.invalid>"]
    if let sendAt { lines.append("\(OHGmailLabels.sendAtHeader): \(ScheduleStamp.format(sendAt))") }
    if let origin { lines.append("X-OpenHuman-Origin: \(origin)") }
    lines += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", body, ""]
    return Data(lines.joined(separator: "\r\n").utf8)
}

final class FakeGoogleSignIn: Sendable {
    static let client = OAuthClientConfig(
        clientID: "1234-synthetic.apps.googleusercontent.com", clientSecret: "SYNTHETIC-not-a-secret",
        authURI: URL(string: "https://accounts.example.invalid/o/oauth2/auth")!,
        tokenURI: URL(string: "https://oauth2.example.invalid/token")!)

    let transport = FakeHTTPTransport()
    private let clock: any OHClock

    init(gmail: FakeGmail, clock: any OHClock, email: String? = nil, scope: String = GmailScope.modify) {
        self.clock = clock
        let email = email ?? gmail.accountEmail
        transport.on("POST", "/token") { _ in
            FakeHTTPTransport.json(200, ["access_token": "synthetic-access", "expires_in": 3600,
                                         "refresh_token": "synthetic-refresh", "scope": scope, "token_type": "Bearer"])
        }
        transport.on("GET", "/gmail/v1/users/me/profile") { _ in
            FakeHTTPTransport.json(200, ["emailAddress": email, "historyId": "1", "messagesTotal": 0, "threadsTotal": 0])
        }
    }

    func flow(_ mode: SafeMode) -> OAuthFlow {
        OAuthFlow(client: Self.client, mode: mode, transport: transport, receiver: ImmediateReceiver(),
                  browser: NoBrowser(), clock: clock)
    }
}

final class ImmediateReceiver: LoopbackRedirectReceiver {
    private let state = Mutex<String?>(nil)
    func start() async throws -> URL { URL(string: "http://127.0.0.1:53682/oauth2callback")! }
    func expectState(_ expected: String) async { state.withLock { $0 = expected } }
    func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents {
        var callback = URLComponents(string: "http://127.0.0.1:53682/oauth2callback")!
        callback.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"),
                               URLQueryItem(name: "state", value: state.withLock { $0 })]
        return callback
    }
    func stop() async {}
}

struct NoBrowser: ExternalBrowser {
    func open(_ url: URL) async throws {}
}

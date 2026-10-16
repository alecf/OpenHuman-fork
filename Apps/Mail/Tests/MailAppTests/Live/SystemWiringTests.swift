import Foundation
import MailActions
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private func ref(_ account: Int64, _ row: Int64, _ id: String) -> ThreadRef {
    ThreadRef(accountID: AccountID(account), rowID: ThreadRowID(rawValue: row), gmailThreadID: GmailThreadID(id))
}

struct EngineNoticeMappingTests {
    @Test func everyEventThatNeedsTheUserMapsAndTheOthersDoNot() {
        let thread = ref(1, 7, "t7")
        let key = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
        #expect(EngineNotices.notice(for: .snoozeWoke(thread, overdueBy: .seconds(90))) == .snoozeWoke(key, overdue: 90))
        #expect(EngineNotices.notice(for: .reminderFired(thread, overdueBy: .seconds(0))) == .reminderFired(key, overdue: 0))
        #expect(EngineNotices.notice(for: .sendFailed(DraftID(rawValue: "d"), "server_503")) == .sendFailed(code: "server_503"))
        #expect(EngineNotices.notice(for: .sendInterrupted(DraftID(rawValue: "d"))) == .sendInterrupted)
        #expect(EngineNotices.notice(for: .scheduledSendNeedsConfirmation(DraftID(rawValue: "d"))) == .scheduledSendNeedsConfirmation)
        #expect(EngineNotices.notice(for: .schedulerDegraded(.sendLater, "private reason text")) == .schedulerDegraded(kind: "send_later"))
        #expect(EngineNotices.notice(for: .accountNeedsReauth(AccountID(2))) == .accountNeedsReauth(AccountID(2)))
        #expect(EngineNotices.notice(for: .sent(DraftID(rawValue: "d"), nil)) == nil)
        #expect(EngineNotices.notice(for: .syncFailed(AccountID(1), "x")) == nil)
        #expect(EngineNotices.notice(for: .ownershipChanged(AccountID(1), isOwner: true)) == nil)
    }

    @Test func aFailedChangeKeepsOnlyItsKindAndCode() {
        let item = OperationItem(id: OperationID(rawValue: 1), accountID: AccountID(1), kind: .modifyLabels,
                                 payload: .createLabel(name: "MARKER label name"), status: .failed, attempts: 3,
                                 notBefore: Date(), nextRetryAt: Date(), origin: .app, lastErrorCode: "server_500",
                                 lastErrorMessage: "MARKER error text", createdAt: Date(), updatedAt: Date())
        let notice = EngineNotices.notice(for: .operationFailed(item))
        #expect(notice == .operationFailed(account: AccountID(1), kind: "modify_labels", code: "server_500"))
        var sendItem = item
        sendItem.kind = .sendDraft
        #expect(EngineNotices.notice(for: .operationFailed(sendItem)) == nil, "`sendFailed` reports a failed send")
    }
}

@MainActor
@Suite(.serialized)
struct SystemWiringTests {
    @Test(.timeLimit(.minutes(2))) func anEngineEventBecomesASystemNotificationThroughTheSession() async throws {
        let corpus = FakeCorpus.make(threadCount: 4, now: Date())
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        let (tokens, continuation) = AsyncStream.makeStream(of: TokenEvent.self)
        let running = try FakeGmailLaunch.makeSession(store: try MailStore.openInMemoryForTesting(),
                                                      gmail: gmail, tokenEvents: tokens)
        let session = running.session
        let app = AppModel(screen: .mail(session.environment), session: session)
        await session.start()
        defer { Task { await session.stop() } }
        let notifier = try #require(session.environment.system.platform.notifier as? FakeSystemNotifier)
        await eventually("the system features started", timeout: .seconds(30)) { session.environment.system.notifications != nil }
        continuation.yield(.needsReauth(account: AccountCredentials.accountKey(corpus.account.email), reason: .invalidGrant))
        await eventually("the notification", timeout: .seconds(60)) { notifier.delivered.contains { $0.title == "Sign in to Mail again" } }
        #expect(running.wire.requests.allSatisfy(isReadOnTheWire))
        _ = app
    }

    @Test func noTestEverGetsTheRealPlatform() async throws {
        #expect(CompositionRoot.systemPlatform([:]) == nil, "XCTest is detected from the process, whatever environment a test passes")
        #expect(CompositionRoot.systemPlatform(["XCTestConfigurationFilePath": "x"]) == nil)
        let fake = CompositionRoot.makeApp(arguments: ["-UseFakeData"], environment: ["XCTestConfigurationFilePath": "x"])
        guard case .mail(let environment) = fake.screen else { Issue.record("not the mail screen"); return }
        await eventually("launch tasks", timeout: .seconds(30)) { environment.system.dockBadge != nil }
        #expect(environment.system.platform.notifier is FakeSystemNotifier)
        #expect(environment.system.platform.dock is FakeDockBadge)
        #expect(environment.system.platform.loginItem is FakeLoginItem)
    }
}

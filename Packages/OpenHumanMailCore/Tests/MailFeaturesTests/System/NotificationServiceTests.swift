import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct NotificationServiceTests {
    private let sender = EmailAddress(name: "Ada Sender", email: "ada@sender.example")

    private func started(_ f: SystemFixture) async -> NotificationService {
        f.env.system.startNotifications()
        let service = f.env.system.notifications!
        await eventually(timeout: .seconds(15)) { service.hasBaseline(for: f.account) }
        return service
    }

    @Test func importantNewMailPostsOneNotificationWithSenderAndSubject() async throws {
        let f = SystemFixture()
        _ = await started(f)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Quarterly numbers", important: true)
        await f.delivered(count: 1)
        let note = try #require(f.notifier.delivered.first)
        #expect(note.title == "Ada Sender")
        #expect(note.body == "Quarterly numbers")
        #expect(note.category == .newMail)
        #expect(note.subtitle == nil, "one account: no account name")
        #expect(f.notifier.authorizationRequests == 0, "a notification never asks for permission")
    }

    @Test func anUndecidedPermissionSkipsTheNotificationAndNeverPrompts() async throws {
        let f = SystemFixture(authorization: .notDetermined)
        f.env.system.coalesce = .seconds(60)
        let service = await started(f)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Quarterly numbers", important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) > 0 }
        await service.flushNow()
        #expect(f.notifier.delivered.isEmpty && f.notifier.authorizationRequests == 0)
        #expect(await service.requestPermissionIfNeeded() == .authorized)
        #expect(f.notifier.authorizationRequests == 1)
    }

    @Test func withTwoAccountsTheNotificationNamesItsAccount() async throws {
        let f = SystemFixture(corpus: .rich(threadCount: 30, now: fixedNow))
        _ = await started(f)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Quarterly numbers", important: true)
        await f.delivered(count: 1)
        let note = try #require(f.notifier.delivered.first)
        #expect(note.title == "Ada Sender" && note.subtitle == "Work")
    }

    @Test func mailThatIsNotImportantNeverNotifies() async throws {
        let f = SystemFixture()
        let service = await started(f)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Newsletter")
        f.store.deliverMessage(account: f.account, from: sender, subject: "Already read", unread: false, important: true)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Sentinel", important: true)
        await f.delivered(count: 1)
        await service.flushNow()
        #expect(f.notifier.delivered.map(\.body) == ["Sentinel"])
        #expect(f.notifier.authorizationRequests == 0)
    }

    @Test func noPermissionPromptAtLaunch() async {
        let f = SystemFixture()
        _ = await started(f)
        #expect(f.notifier.authorizationRequests == 0)
    }

    @Test func aBatchBecomesOneNotification() async throws {
        let f = SystemFixture()
        let service = await started(f)
        service.coalesce = .seconds(30)
        f.store.deliverMessage(account: f.account, from: sender, subject: "One", important: true)
        f.store.deliverMessage(account: f.account, from: EmailAddress(name: "Bo", email: "bo@x.example"), subject: "Two", important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) == 2 }
        await service.flushNow()
        #expect(f.notifier.delivered.count == 1)
        #expect(f.notifier.delivered.first?.title == "2 new important messages")
        #expect(f.notifier.delivered.first?.category == .readOnly, "a group offers no mark-done button")
    }

    @Test func aNewerMessageInAKnownThreadNotifiesAgain() async throws {
        let f = SystemFixture()
        _ = await started(f)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Thread", important: true)
        await f.delivered(count: 1)
        let thread = try await f.firstThread().id
        f.store.deliverMessage(account: f.account, to: thread, from: sender, subject: "Thread",
                               at: Date().addingTimeInterval(7200), important: true)
        await f.delivered(count: 2)
    }

    @Test func mailThatLeftTheInboxBeforeTheFlushNeverNotifies() async throws {
        let f = SystemFixture()
        let service = await started(f)
        service.coalesce = .seconds(30)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Muted reply", important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) == 1 }
        let thread = try await f.firstThread().id
        _ = try await f.store.apply(.markDone([thread]))
        await eventually(timeout: .seconds(15)) { !service.inboxHas(thread) }
        await service.flushNow()
        #expect(f.notifier.delivered.isEmpty)
    }

    @Test func aMutedConversationKeptInTheInboxNeverNotifies() async throws {
        let f = SystemFixture()
        let service = await started(f)
        service.coalesce = .seconds(30)
        let thread = try await f.firstThread().id
        _ = try await f.store.createLabel(f.account, name: OHGmailLabels.muted, applyTo: [thread])
        f.store.deliverMessage(account: f.account, to: thread, from: sender, subject: "Thread",
                               at: Date().addingTimeInterval(7200), important: true)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Sentinel", important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) >= 2 }
        await service.flushNow()
        #expect(f.notifier.delivered.map(\.body) == ["Sentinel"])
    }

    @Test func accountSwitchOffAndFrontmostAppSuppress() async throws {
        let f = SystemFixture()
        let service = await started(f)
        f.env.system.preferences.setNewMailEnabled(false, for: f.account)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Muted", important: true)
        try await Task.sleep(for: .milliseconds(100))
        await service.flushNow()
        #expect(f.notifier.delivered.isEmpty)
        f.env.system.preferences.setNewMailEnabled(true, for: f.account)
        f.active.isActive = true
        f.store.deliverMessage(account: f.account, from: sender, subject: "Looking at it", important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) == 1 }
        await service.flushNow()
        #expect(f.notifier.delivered.isEmpty, "the list already shows it while Mail is frontmost")
    }

    @Test func allInboxMailNotifiesForMailThatIsNotImportant() async throws {
        let f = SystemFixture()
        _ = await started(f)
        f.env.system.preferences.setNewMailMode(.allInbox, for: f.account)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Weekly digest")
        await f.delivered(count: 1)
        let note = try #require(f.notifier.delivered.first)
        #expect(note.title == "Ada Sender" && note.body == "Weekly digest")
    }

    @Test func allInboxMailBatchesAndHiddenPreviewsSayNewMessages() async throws {
        let f = SystemFixture()
        let service = await started(f)
        service.coalesce = .seconds(30)
        f.env.system.preferences.setNewMailMode(.allInbox, for: f.account)
        f.store.deliverMessage(account: f.account, from: sender, subject: "One")
        f.store.deliverMessage(account: f.account, from: EmailAddress(name: "Bo", email: "bo@x.example"), subject: "Two",
                               important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) == 2 }
        await service.flushNow()
        #expect(f.notifier.delivered.map(\.title) == ["2 new messages"])
        f.env.system.preferences.hidePreviews = true
        f.store.deliverMessage(account: f.account, from: sender, subject: "MARKER three")
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) == 1 }
        await service.flushNow()
        let note = try #require(f.notifier.delivered.last)
        #expect(note.title == NotificationService.hiddenPreviewTitleAnyMail && note.body.isEmpty)
        #expect(!note.title.contains("Ada") && !note.title.contains("MARKER"))
    }

    @Test func backToImportantOnlyKeepsJustTheImportantRowsOfAWaitingBatch() async throws {
        let f = SystemFixture()
        let service = await started(f)
        service.coalesce = .seconds(30)
        f.env.system.preferences.setNewMailMode(.allInbox, for: f.account)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Not important")
        f.store.deliverMessage(account: f.account, from: EmailAddress(name: "Bo", email: "bo@x.example"),
                               subject: "Important one", important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) == 2 }
        f.env.system.preferences.setNewMailMode(.important, for: f.account)
        await service.flushNow()
        #expect(f.notifier.delivered.map(\.title) == ["Bo"])
        #expect(f.notifier.delivered.map(\.body) == ["Important one"])
    }

    @Test func hidePreviewsShowsNeitherSenderNorSubject() async throws {
        let f = SystemFixture()
        _ = await started(f)
        f.env.system.preferences.hidePreviews = true
        f.store.deliverMessage(account: f.account, from: sender, subject: "MARKER private subject", important: true)
        await f.delivered(count: 1)
        let note = try #require(f.notifier.delivered.first)
        #expect(note.title == NotificationService.hiddenPreviewTitle)
        #expect(note.body == "")
        for text in [note.title, note.body] {
            #expect(!text.contains("Ada") && !text.contains("sender.example") && !text.contains("MARKER"))
        }
        let bare = EmailAddress(name: nil, email: "bare.marker@sender.example")
        f.store.deliverMessage(account: f.account, from: bare, subject: "MARKER second", important: true)
        await f.delivered(count: 2)
        for note in f.notifier.delivered {
            #expect(!note.title.contains("marker") && !note.title.contains("sender.example") && note.body.isEmpty)
        }
    }

    @Test func hidePreviewsKeepsAGroupAnonymousToo() async throws {
        let f = SystemFixture()
        let service = await started(f)
        service.coalesce = .seconds(30)
        f.env.system.preferences.hidePreviews = true
        f.store.deliverMessage(account: f.account, from: sender, subject: "MARKER one", important: true)
        f.store.deliverMessage(account: f.account, from: EmailAddress(name: "Bo Marker", email: "bo@x.example"),
                               subject: "MARKER two", important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) == 2 }
        await service.flushNow()
        let note = try #require(f.notifier.delivered.first)
        #expect(note.title == "2 new important messages" && note.body.isEmpty)
    }

    @Test func deniedPermissionPostsNothing() async throws {
        let f = SystemFixture(authorization: .denied)
        let service = await started(f)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Quiet", important: true)
        await eventually(timeout: .seconds(15)) { service.pendingNewMailCount(f.account) == 1 }
        await service.flushNow()
        #expect(f.notifier.delivered.isEmpty)
        #expect(f.notifier.authorizationRequests == 0)
    }

    @Test func readOnlyModeOffersNoActionButtons() async throws {
        let f = SystemFixture(options: .init(remoteAck: .immediate, safeMode: .readOnly))
        _ = await started(f)
        f.store.deliverMessage(account: f.account, from: sender, subject: "Read only", important: true)
        await f.delivered(count: 1)
        #expect(f.notifier.delivered.first?.category == .readOnly)
    }

    @Test func agentDraftsReadyNotifyOnceWhenTheQueueGrows() async throws {
        let f = SystemFixture()
        let service = await started(f)
        await eventually(timeout: .seconds(15)) { service.hasReviewBaseline }
        let fields = DraftFields(to: [sender], subject: "Re: x", bodyHTML: "<p>hi</p>")
        f.store.agentCreatesDraft(account: f.account, fields: fields)
        f.store.agentCreatesDraft(account: f.account, fields: fields)
        await f.delivered(count: 1)
        await service.flushNow()
        #expect(f.notifier.delivered.count == 1)
        #expect(f.notifier.delivered.first?.title == "2 drafts ready to review")
        #expect(f.notifier.delivered.first?.userInfo["route"] == "review")
    }
}

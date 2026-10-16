import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct EngineNoticeTests {
    private func started(_ f: SystemFixture) async -> NotificationService {
        f.env.system.startNotifications()
        let service = f.env.system.notifications!
        await eventually(timeout: .seconds(15)) { service.hasBaseline(for: f.account) }
        return service
    }

    @Test func aFailedSendIsAToastThatStaysWhileMailIsFrontmost() async throws {
        let f = SystemFixture()
        _ = await started(f)
        f.active.isActive = true
        await f.env.system.handle(.sendFailed(code: "server_503"))
        let toast = try #require(f.env.notices.toasts.first)
        #expect(toast.style == .error)
        #expect(toast.expiresAt == nil, "send failures stay until dismissed")
        #expect(!toast.message.contains("server_503"))
        await f.env.system.handle(.sendFailed(code: "server_503"))
        #expect(f.env.notices.toasts.count == 1)
        #expect(f.notifier.delivered.isEmpty)
    }

    @Test func aFailedSendInTheBackgroundIsASystemNotification() async throws {
        let f = SystemFixture()
        _ = await started(f)
        await f.env.system.handle(.sendFailed(code: "server_503"))
        #expect(f.notifier.delivered.first?.title == "Couldn't send a message")
        #expect(f.env.notices.toasts.isEmpty)
    }

    @Test func failedChangesAndStoppedSchedulersAreErrorToasts() async throws {
        let f = SystemFixture()
        _ = await started(f)
        await f.env.system.handle(.operationFailed(account: f.account, kind: "markDone", code: "server_500"))
        await f.env.system.handle(.schedulerDegraded(kind: "send_later"))
        let messages = f.env.notices.toasts.map(\.message)
        #expect(messages.count == 2)
        #expect(messages[0] == "Couldn't mark done. The change didn't go through.")
        #expect(messages[1] == "Send later stopped after repeated errors. Restart Mail to try again.")
        #expect(f.env.notices.toasts.allSatisfy { $0.style == .error })
    }

    @Test func failureFallbacksUseUserWords() {
        #expect(NotificationService.phrase(for: "something_new") == "make that change")
        #expect(NotificationService.schedulerStoppedText("something_new")
            == "Background tasks stopped after repeated errors. Quit and open Mail again.")
        #expect(NotificationService.schedulerStoppedText("snooze") == "Snooze stopped after repeated errors. Restart Mail to try again.")
    }

    @Test func aReturnedSnoozeNotifiesInTheBackgroundWithItsSubject() async throws {
        let f = SystemFixture()
        _ = await started(f)
        let row = try await f.firstThread()
        await f.env.system.handle(.snoozeWoke(row.id, overdue: 0))
        await f.delivered(count: 1)
        let note = try #require(f.notifier.delivered.first)
        #expect(note.title == "Snooze returned")
        #expect(note.body == row.subject)
        #expect(NotificationRouting.thread(from: note.userInfo) == row.id)
    }

    @Test func aReturnedSnoozeIsAToastWhileMailIsFrontmostAndHonoursTheSwitch() async throws {
        let f = SystemFixture()
        let service = await started(f)
        let row = try await f.firstThread()
        f.active.isActive = true
        await f.env.system.handle(.snoozeWoke(row.id, overdue: 0))
        await eventually(timeout: .seconds(15)) { !f.env.notices.toasts.isEmpty }
        #expect(f.env.notices.toasts.first?.message.contains("back in your inbox") == true)
        #expect(f.notifier.delivered.isEmpty)
        f.env.system.preferences.snoozeReturned = false
        f.active.isActive = false
        await f.env.system.handle(.snoozeWoke(row.id, overdue: 0))
        await service.flushNow()
        #expect(f.notifier.delivered.isEmpty)
    }

    @Test func manySnoozesReturningTogetherAreOneNotification() async throws {
        let f = SystemFixture()
        let service = await started(f)
        service.coalesce = .seconds(30)
        let rows = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 5))?.rows)
        for row in rows.prefix(3) { await f.env.system.handle(.snoozeWoke(row.id, overdue: 600)) }
        await service.flushNow()
        #expect(f.notifier.delivered.count == 1)
        #expect(f.notifier.delivered.first?.title == "3 snoozed conversations are back")
    }

    private func withReminder(_ f: SystemFixture, subject: String? = nil) async throws -> (ThreadRow, ReminderItem) {
        let row = try await f.firstThread()
        _ = try await f.store.apply(.setReminder(row.id, dueAt: fixedNow.addingTimeInterval(600), kind: .always))
        await eventually(timeout: .seconds(15)) { f.env.system.reminderMirror?.lastSeen[row.id] != nil }
        return (row, try #require(f.env.system.reminderMirror?.lastSeen[row.id]))
    }

    @Test func aFiredReminderIsAToastWhileMailIsFrontmost() async throws {
        let f = SystemFixture()
        _ = await started(f)
        let (row, item) = try await withReminder(f)
        f.active.isActive = true
        await f.env.system.handle(.reminderFired(row.id, overdue: 0))
        #expect(f.env.notices.toasts.first?.message == ReminderNotificationMirror.title(for: item, hidePreviews: false))
    }

    @Test func anOnTimeReminderInTheBackgroundAddsNothingToTheSystemsOwnCopy() async throws {
        let f = SystemFixture()
        _ = await started(f)
        let (row, _) = try await withReminder(f)
        await f.env.system.handle(.reminderFired(row.id, overdue: 30))
        #expect(f.notifier.delivered.isEmpty, "the mirror's request is the notification")
    }

    @Test func aLateReminderTheSystemNeverDeliveredIsPostedAsMissed() async throws {
        let f = SystemFixture()
        _ = await started(f)
        let (row, item) = try await withReminder(f)
        await f.env.system.handle(.reminderFired(row.id, overdue: 3600))
        let note = try #require(f.notifier.delivered.first)
        #expect(note.title.hasPrefix("Missed reminder"))
        #expect(note.identifier == "reminder.missed.\(item.id)")
    }

    @Test func aLateReminderTheSystemDidDeliverIsNotPostedAgain() async throws {
        let f = SystemFixture()
        _ = await started(f)
        let (row, item) = try await withReminder(f)
        _ = await f.notifier.requestAuthorization()
        await f.notifier.schedule(SystemNotification(identifier: item.notificationIdentifier, title: "Reminder"))
        await f.env.system.handle(.reminderFired(row.id, overdue: 3600))
        #expect(f.notifier.delivered.map(\.identifier) == [item.notificationIdentifier])
    }

    @Test func withTheNotificationsModuleOffOnlyFailureToastsRemain() async throws {
        let f = SystemFixture(flags: FeatureFlags().with(.notifications, false))
        #expect(f.env.system.notifications == nil)
        f.env.runLaunchTasks()
        await f.env.system.handle(.sendFailed(code: "x"))
        f.active.isActive = true
        await f.env.system.handle(.sendFailed(code: "x"))
        await f.env.system.handle(.snoozeWoke(try await f.firstThread().id, overdue: 0))
        #expect(f.notifier.delivered.isEmpty && f.notifier.authorizationRequests == 0)
        #expect(f.env.notices.toasts.count == 1, "the failure still shows; nothing else does")
    }
}

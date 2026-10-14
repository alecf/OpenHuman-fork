import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct ReminderMirrorTests {
    private func item(_ id: Int, due: Date, subject: String = "Subject", kind: ReminderKind = .always) -> ReminderItem {
        ReminderItem(id: "r\(id)", thread: ThreadKey(account: AccountID(1), rowID: Int64(id), gmailThreadID: GmailThreadID("t\(id)")),
                     subject: subject, dueAt: due, kind: kind)
    }

    private func mirror(_ notifier: FakeSystemNotifier, now: Date = fixedNow, hide: Bool = false,
                        store: FakeMailStore? = nil) -> ReminderNotificationMirror {
        ReminderNotificationMirror(data: store ?? FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow)), settings: store,
                                   notifier: notifier, hidePreviews: { hide }, now: { now })
    }

    @Test func schedulesOneRequestPerActiveReminderWithItsIdentifier() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        let mirror = mirror(notifier)
        await mirror.sync([item(1, due: fixedNow.addingTimeInterval(600)), item(2, due: fixedNow.addingTimeInterval(1200))])
        #expect(notifier.pending.map(\.identifier) == ["reminder.r1", "reminder.r2"])
        #expect(notifier.pending.first?.deliverAt == fixedNow.addingTimeInterval(600))
        #expect(notifier.pending.first?.title == "Reminder: Subject")
        #expect(notifier.authorizationRequests == 0, "a reminder never asks for permission")
    }

    @Test func anUndecidedPermissionSchedulesNothingAndAsksNothing() async {
        let notifier = FakeSystemNotifier()
        let mirror = mirror(notifier)
        await mirror.sync([item(1, due: fixedNow.addingTimeInterval(600))])
        #expect(notifier.pending.isEmpty && notifier.authorizationRequests == 0)
        #expect(mirror.permission == .unknown)
    }

    @Test func theSystemCopyOffersMarkDoneAndSnoozeOrNothingInReadOnlyMode() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        await mirror(notifier).sync([item(1, due: fixedNow.addingTimeInterval(600))])
        #expect(notifier.pending.first?.category == .reminder)
        let readOnly = FakeSystemNotifier(authorization: .authorized)
        let store = FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow), options: .init(remoteAck: .immediate, safeMode: .readOnly))
        await mirror(readOnly, store: store).sync([item(1, due: fixedNow.addingTimeInterval(600))])
        #expect(readOnly.pending.first?.category == .readOnly)
    }

    @Test func noPermissionPromptWithoutAReminder() async {
        let notifier = FakeSystemNotifier()
        await mirror(notifier).sync([])
        #expect(notifier.authorizationRequests == 0)
    }

    @Test func clearedOrSatisfiedReminderRemovesItsRequest() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        let mirror = mirror(notifier)
        await mirror.sync([item(1, due: fixedNow.addingTimeInterval(600)), item(2, due: fixedNow.addingTimeInterval(900))])
        await mirror.sync([item(2, due: fixedNow.addingTimeInterval(900))])
        #expect(notifier.pending.map(\.identifier) == ["reminder.r2"])
        await mirror.sync([])
        #expect(notifier.pending.isEmpty)
    }

    @Test func aMovedReminderReplacesItsRequest() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        let mirror = mirror(notifier)
        await mirror.sync([item(1, due: fixedNow.addingTimeInterval(600))])
        await mirror.sync([item(1, due: fixedNow.addingTimeInterval(7200))])
        #expect(notifier.pending.count == 1)
        #expect(notifier.pending.first?.deliverAt == fixedNow.addingTimeInterval(7200))
    }

    @Test func relaunchDoesNotDuplicate() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        let list = [item(1, due: fixedNow.addingTimeInterval(600))]
        await mirror(notifier).sync(list)
        await mirror(notifier).sync(list)
        #expect(notifier.pending.map(\.identifier) == ["reminder.r1"])
    }

    @Test func aReminderAlreadyDueIsNeverScheduledAgain() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        await mirror(notifier).sync([item(1, due: fixedNow.addingTimeInterval(-60)), item(2, due: fixedNow)])
        #expect(notifier.pending.isEmpty)
        #expect(notifier.scheduleLog.isEmpty, "no catch-up request for something the system already delivered")
    }

    @Test func keepsTheSoonestFifty() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        let items = (1...60).map { item($0, due: fixedNow.addingTimeInterval(Double($0) * 60)) }
        await mirror(notifier).sync(items.reversed())
        let ids = Set(notifier.pending.map(\.identifier))
        #expect(ids.count == ReminderNotificationMirror.pendingLimit)
        #expect(ids.contains("reminder.r50") && !ids.contains("reminder.r51"))
    }

    @Test func hiddenPreviewsLeaveTheSubjectOut() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        await mirror(notifier, hide: true).sync([item(1, due: fixedNow.addingTimeInterval(600), subject: "MARKER secret subject")])
        #expect(notifier.pending.first?.title == "Reminder")
        #expect(ReminderNotificationMirror.title(for: item(1, due: fixedNow, kind: .ifNoReply), hidePreviews: false) == "No reply yet: Subject")
    }

    @Test func turningPreviewsOffReschedulesWaitingCopiesWithoutTheSubject() async {
        @MainActor final class Box { var hide = false }
        let box = Box()
        let notifier = FakeSystemNotifier(authorization: .authorized)
        let mirror = ReminderNotificationMirror(data: FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow)), settings: nil,
                                                notifier: notifier, hidePreviews: { box.hide }, now: { fixedNow })
        let list = [item(1, due: fixedNow.addingTimeInterval(600), subject: "MARKER secret subject"),
                    item(2, due: fixedNow.addingTimeInterval(900), subject: "MARKER other", kind: .ifNoReply)]
        await mirror.sync(list)
        #expect(notifier.pending.allSatisfy { $0.title.contains("MARKER") })
        let before = notifier.scheduleLog.count
        await mirror.sync(list)
        #expect(notifier.scheduleLog.count == before, "nothing changed, nothing rescheduled")
        box.hide = true
        await mirror.sync(list)
        #expect(Set(notifier.pending.map(\.title)) == ["Reminder", "No reply yet"])
        #expect(notifier.pending.allSatisfy { !$0.title.contains("MARKER") })
        #expect(notifier.pending.count == 2, "replaced by identifier, not duplicated")
        #expect(notifier.pending.first(where: { $0.identifier == "reminder.r1" })?.deliverAt == fixedNow.addingTimeInterval(600))
    }

    @Test func theNotificationSwitchReschedulesThroughTheSystemCenter() async throws {
        let f = SystemFixture(authorization: .authorized)
        let thread = try await f.firstThread().id
        f.env.system.startNotifications()
        let mirror = try #require(f.env.system.reminderMirror, "the reminders module is on in the fixture")
        _ = try await f.store.apply(.setReminder(thread, dueAt: Date().addingTimeInterval(3600), kind: .always))
        await eventually(timeout: .seconds(15)) { f.notifier.pending.contains { $0.title.hasPrefix("Reminder: ") } }
        f.env.system.preferences.hidePreviews = true
        await eventually(timeout: .seconds(15)) {
            f.notifier.pending.count == 1 && f.notifier.pending.first?.title == "Reminder"
        }
        mirror.stop()
    }

    @Test func aSignedOutAccountLosesItsWaitingCopiesAtOnce() async {
        let notifier = FakeSystemNotifier(authorization: .authorized)
        let mirror = mirror(notifier)
        let other = ReminderItem(id: "r9", thread: ThreadKey(account: AccountID(2), rowID: 9, gmailThreadID: GmailThreadID("t9")),
                                 subject: "Other account", dueAt: fixedNow.addingTimeInterval(1200), kind: .always)
        await mirror.sync([item(1, due: fixedNow.addingTimeInterval(600)), other])
        #expect(notifier.pending.count == 2)
        await mirror.removeAccount(AccountID(1))
        #expect(notifier.pending.map(\.identifier) == ["reminder.r9"])
    }

    @Test func deniedPermissionSchedulesNothingAndSaysSo() async {
        let notifier = FakeSystemNotifier(authorization: .denied)
        let mirror = mirror(notifier)
        await mirror.sync([item(1, due: fixedNow.addingTimeInterval(600))])
        #expect(notifier.pending.isEmpty)
        #expect(mirror.permission == .denied)
        #expect(notifier.authorizationRequests == 0, "a refusal is not asked again")
    }

    @Test func followsTheStoreAndTheRemindersSwitch() async throws {
        let f = SystemFixture(authorization: .authorized)
        let thread = try await f.firstThread().id
        let mirror = ReminderNotificationMirror(data: f.store, settings: f.store, notifier: f.notifier, now: { fixedNow })
        mirror.start()
        let due = fixedNow.addingTimeInterval(3600)
        _ = try await f.store.apply(.setReminder(thread, dueAt: due, kind: .always))
        await eventually(timeout: .seconds(15)) { f.notifier.pending.count == 1 }
        let id = try #require(f.notifier.pending.first?.identifier)
        #expect(id.hasPrefix("reminder."))
        try await f.store.set(AppSettings.schedulerReminders, false)
        await eventually(timeout: .seconds(15)) { f.notifier.pending.isEmpty }
        try await f.store.set(AppSettings.schedulerReminders, true)
        await eventually(timeout: .seconds(15)) { f.notifier.pending.count == 1 }
        _ = try await f.store.apply(.cancelReminder(thread))
        await eventually(timeout: .seconds(15)) { f.notifier.pending.isEmpty }
        mirror.stop()
    }

    @Test func aFiredReminderLeavesTheQueueAndNothingIsReposted() async throws {
        let f = SystemFixture(authorization: .authorized)
        let thread = try await f.firstThread().id
        let mirror = ReminderNotificationMirror(data: f.store, settings: f.store, notifier: f.notifier, now: { fixedNow })
        mirror.start()
        _ = try await f.store.apply(.setReminder(thread, dueAt: fixedNow.addingTimeInterval(120), kind: .always))
        await eventually(timeout: .seconds(15)) { f.notifier.pending.count == 1 }
        let scheduled = f.notifier.scheduleLog.count
        f.store.runSchedulers(now: fixedNow.addingTimeInterval(3600))
        await eventually(timeout: .seconds(15)) { f.notifier.pending.isEmpty }
        #expect(f.notifier.scheduleLog.count == scheduled, "firing posts no new request")
        mirror.stop()
    }

    @Test func overlappingPassesRunInOrderAndAFiredReminderIsNotReposted() async {
        let fake = FakeSystemNotifier(authorization: .authorized)
        let notifier = HoldingNotifier(fake)
        let mirror = ReminderNotificationMirror(data: FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow)), settings: nil,
                                                notifier: notifier, now: { fixedNow })
        let list = [item(1, due: fixedNow.addingTimeInterval(600))]
        let first = Task { await mirror.sync(list) }
        for await _ in notifier.held { break }
        let again = Task { await mirror.sync(list) }
        let fired = Task { await mirror.sync([]) }
        await eventually(timeout: .seconds(15)) { mirror.passesInFlight == 3 }
        notifier.release()
        await first.value
        await again.value
        await fired.value
        #expect(notifier.overlaps == 0, "no pass touched the notifier while another was suspended in it")
        #expect(fake.scheduleLog == ["reminder.r1"], "posted once")
        #expect(fake.pending.isEmpty, "the fired reminder is not posted again")
    }
}

private final class HoldingNotifier: SystemNotifying, Sendable {
    private struct State {
        var first = true
        var holding = false
        var gate: CheckedContinuation<Void, Never>?
        var overlaps = 0
    }
    private let inner: FakeSystemNotifier
    private let state = Mutex(State())
    let held: AsyncStream<Void>
    private let heldSignal: AsyncStream<Void>.Continuation

    init(_ inner: FakeSystemNotifier) {
        self.inner = inner
        (held, heldSignal) = AsyncStream.makeStream()
    }

    var overlaps: Int { state.withLock { $0.overlaps } }

    func release() {
        let gate = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.holding = false
            defer { s.gate = nil }
            return s.gate
        }
        gate?.resume()
    }

    private func note() { state.withLock { if $0.holding { $0.overlaps += 1 } } }

    func authorization() async -> NotificationAuthorization { note(); return await inner.authorization() }
    func requestAuthorization() async -> Bool { note(); return await inner.requestAuthorization() }
    func schedule(_ notification: SystemNotification) async { note(); await inner.schedule(notification) }
    func remove(identifiers: [String]) async { note(); await inner.remove(identifiers: identifiers) }
    func deliveredIdentifiers() async -> [String] { note(); return await inner.deliveredIdentifiers() }
    @MainActor func setResponder(_ responder: (@MainActor @Sendable (NotificationResponse) -> Void)?) { inner.setResponder(responder) }

    func pendingIdentifiers() async -> [String] {
        let hold = state.withLock { s -> Bool in
            if s.first { s.first = false; return true }
            if s.holding { s.overlaps += 1 }
            return false
        }
        if hold {
            await withCheckedContinuation { continuation in
                state.withLock { $0.gate = continuation; $0.holding = true }
                heldSignal.yield()
            }
        }
        return await inner.pendingIdentifiers()
    }
}

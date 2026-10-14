import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

@Test func snoozeIsALabelChangeAndTheWakeTimeIsDerived() async throws {
    let store = makeStore()
    let target = special(0).row.id
    let wake = fixedNow.addingTimeInterval(86_400 + 42)
    let floored = ScheduleStamp.floorToMinute(wake)
    _ = try await store.apply(.snooze([target], until: wake))
    #expect(!(try await keys(store, .system(.inbox))).contains(target))
    let row = try #require(try await window(store, .system(.snoozed)).rows.first { $0.id == target })
    #expect(row.snoozedUntil == floored && row.sortAt == floored)
    let names = store.labelNames(of: target)
    #expect(names.contains("OpenHuman/Snoozed") && names.contains(ScheduleLabel(kind: .snoozed, due: floored).name))
    #expect(!names.contains("INBOX"))
    #expect(try await first(store.threadDetail(target))?.snooze == .until(floored, stampCount: 1))
}

@Test func rescheduleSwapsTheStampAndUndoRestoresTheOldTime() async throws {
    let store = makeStore()
    let target = special(0).row.id
    let first = ScheduleStamp.floorToMinute(fixedNow.addingTimeInterval(3_600))
    let second = ScheduleStamp.floorToMinute(fixedNow.addingTimeInterval(7_200))
    _ = try await store.apply(.snooze([target], until: first))
    store.acknowledgeRemote()
    let reschedule = try await store.apply(.snooze([target], until: second))
    #expect(try await window(store, .system(.snoozed)).rows.first { $0.id == target }?.snoozedUntil == second)
    #expect(store.labelNames(of: target).filter { $0.hasPrefix("OpenHuman/Snoozed/") }.count == 1)
    store.acknowledgeRemote()
    _ = try await store.undo(reschedule)
    #expect(try await window(store, .system(.snoozed)).rows.first { $0.id == target }?.snoozedUntil == first)
    store.acknowledgeRemote()
    let same = try await store.apply(.snooze([target], until: first))
    #expect(store.pendingOperationCount == 0)
    #expect(try await store.undo(same) == nil)
}

@Test func wakeNowReturnsToTheTopOfTheInboxUnread() async throws {
    let clock = FakeClock(fixedNow)
    let store = makeStore(clock: clock)
    let target = special(8).row.id
    clock.advance(by: 60)
    _ = try await store.apply(.unsnooze([target]))
    let inbox = try await window(store, .system(.inbox)).rows
    #expect(inbox.first?.id == target, "boosted to the top")
    #expect(inbox.first?.isUnread == true, "snooze_mark_unread defaults to true")
    #expect(!(try await keys(store, .system(.snoozed))).contains(target))
    try await store.set(AppSettings.snoozeMarkUnread, false)
    let other = special(9).row.id
    _ = try await store.apply(.unsnooze([other]))
    #expect(try await window(store, .system(.inbox)).rows.first { $0.id == other }?.isUnread == false)
}

@Test func unreadableStampIsWakeTimeUnknownAndNeverWokenAutomatically() async throws {
    let store = makeStore()
    let target = special(10).row.id
    let row = try #require(try await window(store, .system(.snoozed)).rows.first { $0.id == target })
    #expect(row.snoozedUntil == nil)
    #expect(try await first(store.threadDetail(target))?.snooze == .wakeTimeUnknown)
    let report = store.runSchedulers(now: fixedNow.addingTimeInterval(365 * 86_400))
    #expect(!report.woken.contains(target))
    #expect(try await keys(store, .system(.snoozed)).contains(target))
    _ = try await store.apply(.snooze([target], until: fixedNow.addingTimeInterval(3_600)))
    #expect(try await first(store.threadDetail(target))?.snooze?.wakeAt != nil)
    _ = try await store.apply(.unsnooze([target]))
    #expect(try await keys(store, .system(.inbox)).contains(target))
}

@Test func schedulerWakesDueSnoozesAndAnotherInstallCanWakeFirst() async throws {
    let store = makeStore()
    let due = special(8).row.id
    let later = special(9).row.id
    try await store.set(AppSettings.schedulerReminders, false)
    let report = store.runSchedulers(now: fixedNow.addingTimeInterval(86_400 + 120))
    #expect(report.woken.filter { $0.account == work } == [due])
    store.acknowledgeRemote()
    #expect(try await keys(store, .system(.inbox)).first == due)
    var snoozed = store.threadWindow(.system(.snoozed), account: work, limit: 50).makeAsyncIterator()
    #expect(try #require(try await snoozed.next()).rows.contains { $0.id == later })
    store.simulateOtherInstallWake(later)
    #expect(!(try #require(try await snoozed.next())).rows.contains { $0.id == later })
    #expect(try await keys(store, .system(.inbox)).contains(later))
    let target = special(0).row.id
    store.simulateOtherInstallSnooze(target, until: fixedNow.addingTimeInterval(9_000))
    store.simulateOtherInstallSnooze(target, until: fixedNow.addingTimeInterval(5_400), keepExisting: true)
    #expect(try await first(store.threadDetail(target))?.snooze
        == .until(ScheduleStamp.floorToMinute(fixedNow.addingTimeInterval(5_400)), stampCount: 2))
}

@Test func newMailWakesASnoozedThread() async throws {
    let store = makeStore()
    let target = special(8).row.id
    store.deliverMessage(account: work, to: target, from: EmailAddress(name: "Dana Ruiz", email: "dana@example.com"))
    #expect(try await keys(store, .system(.inbox)).contains(target))
    store.runSchedulers(now: fixedNow)
    store.acknowledgeRemote()
    #expect(!(try await keys(store, .system(.snoozed))).contains(target), "the snooze labels are cleared")
}

@Test func oneActiveReminderPerThreadWithUndo() async throws {
    let store = makeStore()
    let target = special(0).row.id
    let first = fixedNow.addingTimeInterval(3_600)
    let second = fixedNow.addingTimeInterval(7_200)
    var reminders = store.reminders(work).makeAsyncIterator()
    #expect(try #require(try await reminders.next()).count == 2)
    _ = try await store.apply(.setReminder(target, dueAt: first, kind: .always))
    var list = try #require(try await reminders.next())
    #expect(list.first?.thread == target && list.first?.dueAt == first, "soonest first")
    let replace = try await store.apply(.setReminder(target, dueAt: second, kind: .ifNoReply))
    list = try #require(try await reminders.next())
    #expect(list.filter { $0.thread == target }.map(\.dueAt) == [second])
    #expect(try await window(store, .system(.inbox)).rows.first { $0.id == target }?.reminderAt == second)
    _ = try await store.undo(replace)
    list = try #require(try await reminders.next())
    #expect(list.filter { $0.thread == target }.map(\.dueAt) == [first])
    let clear = try await store.apply(.cancelReminder(target))
    #expect(try #require(try await reminders.next()).count == 2)
    _ = try await store.undo(clear)
    #expect(try #require(try await reminders.next()).contains { $0.thread == target && $0.kind == .always })
    _ = try await store.apply(.markDone([target]))
    #expect(try await keys(store, .system(.reminders)).contains(target))
}

@Test func remindersFireByTheRules() async throws {
    let store = makeStore()
    let archived = special(20).row.id
    let snoozed = special(9).row.id
    let trashed = special(17).row.id
    let replied = special(12).row.id
    let due = fixedNow.addingTimeInterval(600)
    _ = try await store.apply(.setReminder(archived, dueAt: due, kind: .always))
    _ = try await store.apply(.setReminder(snoozed, dueAt: due, kind: .always))
    _ = try await store.apply(.setReminder(trashed, dueAt: due, kind: .always))
    _ = try await store.apply(.setReminder(replied, dueAt: due, kind: .ifNoReply))
    store.deliverMessage(account: work, to: replied, from: EmailAddress(name: "Dana Ruiz", email: "dana@example.com"),
                         unread: false, at: fixedNow.addingTimeInterval(60))
    let report = store.runSchedulers(now: fixedNow.addingTimeInterval(3_600))
    store.acknowledgeRemote()
    #expect(report.firedReminders.count == 2)
    #expect(report.satisfiedReminders.count == 1)
    #expect(report.cancelledReminders.count == 1)
    let inbox = try await keys(store, .system(.inbox))
    #expect(inbox.first == archived, "a fired reminder brings the thread back, boosted")
    #expect(!inbox.contains(snoozed), "the snooze keeps control of the inbox")
    #expect(try await first(store.reminders(work)).map(\.thread) == [special(11).row.id], "the not-yet-due one stays")
}

@Test func sendLaterIsAStampOnTheDraft() async throws {
    let clock = FakeClock(fixedNow)
    let store = makeStore(clock: clock)
    let reply = try #require(special(20).detail.messages.last?.id)
    let (key, _) = try await store.createDraft(DraftInput(account: work, mode: .reply, replyTo: reply))
    let at = fixedNow.addingTimeInterval(86_400 + 30)
    try await store.scheduleSend(key, at: at)
    let draft = try #require(try await first(store.draft(key)))
    #expect(draft.status == .scheduled && draft.sendAt == ScheduleStamp.floorToMinute(at))
    #expect(try await keys(store, .system(.scheduled)).contains(special(20).row.id))
    try await store.cancelScheduledSend(key)
    let cancelled = try #require(try await first(store.draft(key)))
    #expect(cancelled.status == .editing && cancelled.sendAt == nil)
    store.setDraftSendStamp(key, stamp: "next tuesday")
    let broken = try #require(try await first(store.draft(key)))
    #expect(broken.status == .failed && broken.lastError == "scheduled time unreadable")
    try await store.scheduleSend(key, at: fixedNow.addingTimeInterval(600))
    let report = store.runSchedulers(now: fixedNow.addingTimeInterval(700))
    #expect(report.sent == [key])
    #expect(try await first(store.draft(key)) == nil)
    #expect(store.sentMessages.last?.draft == key)
    #expect(try await first(store.threadDetail(special(20).row.id))?.messages.last?.from?.email == FakeCorpus.me.email)
}

@Test func unreviewedAgentDraftsCannotBeScheduled() async throws {
    let store = makeStore()
    let agent = try #require(try await first(store.reviewQueue(work)).first { $0.source == .agent })
    await #expect(throws: MailPortError.self) { try await store.scheduleSend(agent.id, at: fixedNow.addingTimeInterval(3_600)) }
    try await store.setReviewState(agent.id, .approved)
    try await store.scheduleSend(agent.id, at: fixedNow.addingTimeInterval(3_600))
    #expect(try await first(store.draft(agent.id))?.status == .scheduled)
}

@Test func anotherInstallSendingClosesTheDraft() async throws {
    let store = makeStore()
    let scheduled = try #require(try await first(store.drafts(work, review: false)).first { $0.status == .scheduled })
    var stream = store.draft(scheduled.id).makeAsyncIterator()
    #expect(try await stream.next()??.status == .scheduled)
    store.simulateOtherInstallSend(scheduled.id)
    #expect(try await stream.next() == .some(nil))
    #expect(store.sentMessages.last?.byOtherInstall == true)
}

@Test func schedulerSwitchesPauseFiringOnThisMac() async throws {
    let store = makeStore()
    try await store.set(AppSettings.schedulerSnooze, false)
    try await store.set(AppSettings.schedulerReminders, false)
    try await store.set(AppSettings.schedulerSendLater, false)
    let report = store.runSchedulers(now: fixedNow.addingTimeInterval(30 * 86_400))
    #expect(report == FakeSchedulerReport())
}

import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

private func fire(_ store: FakeMailStore, _ thread: ThreadKey, at now: Date) async throws {
    _ = try await store.apply(.setReminder(thread, dueAt: now.addingTimeInterval(-600), kind: .always))
    let report = store.runSchedulers(now: now)
    #expect(report.firedReminders.count == 1)
    store.acknowledgeRemote()
}

private func inboxRow(_ store: FakeMailStore, _ thread: ThreadKey) async throws -> ThreadRow? {
    try await window(store, .system(.inbox)).rows.first { $0.id == thread }
}

@Test func aFiredReminderMarksTheReturnedThreadUntilItIsDone() async throws {
    let store = makeStore()
    let archived = special(20).row.id
    try await fire(store, archived, at: fixedNow.addingTimeInterval(3_600))
    let inbox = try await window(store, .system(.inbox)).rows
    #expect(inbox.first?.id == archived && inbox.first?.returnedByReminder == true)
    #expect(inbox.filter(\.returnedByReminder).map(\.id) == [archived])
    #expect(try await first(store.threadDetail(archived))?.returnedByReminder == true)
    _ = try await store.apply(.markDone([archived]))
    store.acknowledgeRemote()
    #expect(try await inboxRow(store, archived) == nil)
    #expect(try await first(store.threadDetail(archived))?.returnedByReminder == false)
}

@Test func aNewReminderOnAReturnedThreadHidesTheMarkUntilCancelled() async throws {
    let store = makeStore()
    let archived = special(20).row.id
    try await fire(store, archived, at: fixedNow.addingTimeInterval(3_600))
    let again = try await store.apply(.setReminder(archived, dueAt: fixedNow.addingTimeInterval(86_400), kind: .always))
    #expect(try await inboxRow(store, archived)?.returnedByReminder == false)
    _ = try await store.undo(again)
    #expect(try await inboxRow(store, archived)?.returnedByReminder == true)
}

@Test func wakingASnoozeByHandIsNotAReturnedReminder() async throws {
    let clock = FakeClock(fixedNow)
    let store = makeStore(clock: clock)
    let target = special(8).row.id
    clock.advance(by: 60)
    _ = try await store.apply(.unsnooze([target]))
    let row = try #require(try await inboxRow(store, target))
    #expect(!row.returnedByReminder)
}

@Test func aReturnedThreadSnoozedAndWokenAtTheSameInstantIsNotMarked() async throws {
    let clock = FakeClock(fixedNow)
    let store = makeStore(clock: clock)
    let archived = special(20).row.id
    let firedAt = fixedNow.addingTimeInterval(3_600)
    try await fire(store, archived, at: firedAt)
    _ = try await store.apply(.snooze([archived], until: fixedNow.addingTimeInterval(86_400)))
    store.acknowledgeRemote()
    #expect(try await inboxRow(store, archived) == nil)
    clock.set(firedAt)
    _ = try await store.apply(.unsnooze([archived]))
    let row = try #require(try await inboxRow(store, archived))
    #expect(!row.returnedByReminder)
}

@Test func anotherInstallsWakeIsNotAReturnedReminder() async throws {
    let store = makeStore()
    let archived = special(20).row.id
    try await fire(store, archived, at: fixedNow.addingTimeInterval(3_600))
    store.simulateOtherInstallSnooze(archived, until: fixedNow.addingTimeInterval(86_400))
    #expect(try await inboxRow(store, archived) == nil)
    store.simulateOtherInstallWake(archived)
    let row = try #require(try await inboxRow(store, archived))
    #expect(!row.returnedByReminder)
}

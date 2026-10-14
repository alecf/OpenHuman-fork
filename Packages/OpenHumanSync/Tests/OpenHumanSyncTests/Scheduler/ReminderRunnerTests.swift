import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ReminderRunnerTests {
    private func activeReminders(_ h: EngineHarness) throws -> [ReminderSummary] {
        try h.store.activeReminders(account: h.account, limit: 100)
    }

    private func syncOnce(_ h: EngineHarness) async throws {
        try await AccountSyncer(account: h.account, store: h.store, api: h.gmail, clock: h.clock).sync(reason: "test")
    }

    @Test func firesAtTheDueTimeAndNeverBefore() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[0]
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        await h.gmail.simulateWebArchive(threadID: thread)
        _ = try await engine.syncNow(h.account, reason: "test")
        let due = h.clock.now.addingTimeInterval(3_600)
        _ = try await engine.perform(.setReminder(try h.ref(thread), dueAt: due, condition: .always), origin: .app)
        let scheduler = try #require(await engine.scheduler(for: h.account))
        try await h.waitForSchedulerIdle(engine)

        h.clock.advance(to: due.addingTimeInterval(-1))
        try await eventually("armed for the due time") { await scheduler.nextFire == due }
        #expect(events.remindersFired.isEmpty)
        #expect(try activeReminders(h).count == 1)
        #expect(!(await h.serverLabels(ofThread: thread)).contains("INBOX"))

        h.clock.advance(to: due)
        try await eventually("fired") { events.remindersFired.count == 1 }
        #expect(events.remindersFired.first?.0.gmailThreadID.rawValue == thread)
        #expect(events.remindersFired.first?.1 == .zero)
        #expect(try activeReminders(h).isEmpty)
        try await eventually("back in the inbox on Gmail") { (await h.serverLabels(ofThread: thread)).contains("INBOX") }
        #expect(try h.inbox().first == thread)
        #expect(try h.ops().contains { $0.origin == .scheduler && $0.status == .succeeded })
        await engine.stop()
    }

    @Test func aReminderDueWhileTheAppWasClosedFiresAtLaunchWithOverdueBy() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[1]
        try await syncOnce(h)
        await h.gmail.simulateWebArchive(threadID: thread)
        try await syncOnce(h)
        let due = h.clock.now.addingTimeInterval(600)
        _ = try h.store.apply(.setReminder(try h.ref(thread), dueAt: due, condition: .always), origin: .app)
        h.clock.advance(by: .seconds(7_200))
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await eventually("fired at launch") { events.remindersFired.count == 1 }
        #expect(events.remindersFired.first?.1 == .seconds(6_600))
        try await eventually("back in the inbox on Gmail") { (await h.serverLabels(ofThread: thread)).contains("INBOX") }
        await engine.stop()
    }

    @Test func aReplyThatArrivedWhileClosedSatisfiesAnIfNoReplyReminder() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[0]
        try await syncOnce(h)
        await h.gmail.simulateWebArchive(threadID: thread)
        try await syncOnce(h)
        let due = h.clock.now.addingTimeInterval(600)
        _ = try h.store.apply(.setReminder(try h.ref(thread), dueAt: due, condition: .ifNoReply), origin: .app)
        await h.gmail.deliver(from: "Alice Example <alice@example.com>", subject: "Re: Seeded thread 0",
                              body: "Synthetic reply.", labels: ["UNREAD"], threadID: thread)
        h.clock.advance(by: .seconds(7_200))
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSchedulerIdle(engine)
        #expect(try activeReminders(h).isEmpty)
        #expect(events.remindersFired.isEmpty)
        #expect(try h.ops().filter { $0.origin == .scheduler }.isEmpty)
        #expect(!(await h.serverLabels(ofThread: thread)).contains("INBOX"))
        await engine.stop()
    }

    @Test func aReplyBeforeTheDueTimeSatisfiesItAtOnce() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[2]
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        _ = try await engine.perform(.setReminder(try h.ref(thread), dueAt: h.clock.now.addingTimeInterval(86_400),
                                                  condition: .ifNoReply), origin: .app)
        _ = try await engine.perform(.archive([try h.ref(thread)]), origin: .app)
        #expect(try activeReminders(h).count == 1)
        await h.gmail.deliver(subject: "Re: Seeded thread 2", body: "Synthetic reply.", labels: ["UNREAD"],
                              threadID: thread)
        h.clock.advance(by: .seconds(60))
        try await eventually("satisfied before its due time") { try activeReminders(h).isEmpty }
        #expect(events.remindersFired.isEmpty)
        #expect(try h.ops().filter { $0.origin == .scheduler }.isEmpty)
        await engine.stop()
    }

    @Test func markDoneBeforeTheDueTimeKeepsTheReminder() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[0]
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        let due = h.clock.now.addingTimeInterval(1_800)
        _ = try await engine.perform(.setReminder(try h.ref(thread), dueAt: due, condition: .always), origin: .app)
        let done = try await engine.perform(.archive([try h.ref(thread)]), origin: .app)
        try await eventually("archived on Gmail") { try h.store.operation(done.operationIDs[0])?.status == .succeeded }
        #expect(try activeReminders(h).count == 1)
        h.clock.advance(to: due)
        try await eventually("fired") { events.remindersFired.count == 1 }
        try await eventually("back in the inbox on Gmail") { (await h.serverLabels(ofThread: thread)).contains("INBOX") }
        await engine.stop()
    }

    @Test func anotherInstallNeverSeesTheReminder() async throws {
        let a = try await EngineHarness()
        let b = try await EngineHarness(threads: 0, clock: a.clock, gmail: a.gmail)
        let engineA = a.engine(), engineB = b.engine()
        let eventsB = EngineEvents(engineB)
        await engineA.start()
        await engineB.start()
        try await a.waitForSyncs(engineA)
        try await b.waitForSyncs(engineB)
        let due = a.clock.now.addingTimeInterval(600)
        _ = try await engineA.perform(.setReminder(try a.ref(a.threads[0]), dueAt: due, condition: .always), origin: .app)
        #expect(try b.store.activeReminders(account: b.account, limit: 10).isEmpty)
        a.clock.advance(to: due.addingTimeInterval(60))
        try await eventually("A fired") { try a.store.activeReminders(account: a.account, limit: 10).isEmpty }
        try await b.waitForSyncs(engineB, 2)
        #expect(eventsB.remindersFired.isEmpty)
        #expect(try b.store.activeReminders(account: b.account, limit: 10).isEmpty)
        await engineA.stop()
        await engineB.stop()
    }

    @Test func aTrashedThreadCancelsSilentlyAndASnoozedThreadKeepsItsSnooze() async throws {
        let h = try await EngineHarness(threads: 4)
        let trashed = h.threads[0], snoozed = h.threads[1]
        try await syncOnce(h)
        for message in await h.gmail.messageIDs(inThread: trashed) {
            await h.gmail.modifyLabels(messageID: message, add: ["TRASH"], remove: ["INBOX"])
        }
        let stamp = await h.snoozeOnServer(snoozed, until: h.clock.now.addingTimeInterval(30 * 86_400))
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        let due = h.clock.now.addingTimeInterval(600)
        _ = try await engine.perform(.setReminder(try h.ref(trashed), dueAt: due, condition: .always), origin: .app)
        _ = try await engine.perform(.setReminder(try h.ref(snoozed), dueAt: due, condition: .always), origin: .app)
        h.clock.advance(to: due)
        try await eventually("both decided") { try activeReminders(h).isEmpty }
        try await eventually("the snoozed thread's reminder fired") { events.remindersFired.count == 1 }
        #expect(events.remindersFired.first?.0.gmailThreadID.rawValue == snoozed)
        #expect(try h.ops().filter { $0.origin == .scheduler }.isEmpty)
        let labels = await h.serverLabels(ofThread: snoozed)
        #expect(!labels.contains("INBOX"))
        #expect(labels.contains(try #require(await h.gmail.labelID(named: stamp))))
        #expect(!(await h.serverLabels(ofThread: trashed)).contains("INBOX"))
        await engine.stop()
    }

    @Test func readOnlyRunsNoReminderScheduler() async throws {
        let h = try await EngineHarness(safeMode: .readOnly, scopes: [GmailScope.readonly])
        try await syncOnce(h)
        _ = try h.store.apply(.setReminder(try h.ref(h.threads[0]), dueAt: h.clock.now.addingTimeInterval(60),
                                           condition: .always), origin: .app)
        let engine = h.engine(safeMode: .readOnly)
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        h.clock.advance(by: .seconds(3_600))
        try await h.waitForSyncs(engine, 2)
        #expect(await engine.scheduler(for: h.account) == nil)
        #expect(events.remindersFired.isEmpty)
        #expect(try activeReminders(h).count == 1)
        await engine.stop()
    }
}

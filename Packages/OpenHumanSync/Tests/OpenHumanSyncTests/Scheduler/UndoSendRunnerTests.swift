import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct UndoSendRunnerTests {
    @Test func aNeverClaimedSchedulerSendIsNotUnscheduledByTheLaunchReconcile() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        let draft = try h.newDraft()
        try await h.upload(draft, drainer: drainer)
        let sendAt = h.clock.now.addingTimeInterval(3600)
        try h.store.scheduleSend(draft, at: sendAt)
        await drainer.drainOnce()
        #expect(try h.draft(draft).state == .scheduled)
        let receipt = try h.store.send(draft, undoWindow: .zero, origin: .scheduler)
        h.instant.advance(by: .seconds(3 * 3600))
        let interrupted = try UndoSendRunner.reconcileAtLaunch(account: h.account, store: h.store, now: h.clock.now) {
            events.append($0)
        }
        #expect(interrupted.isEmpty && events.all.isEmpty)
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .pending)
        #expect(try h.draft(draft).state == .sending)
        #expect(try h.draft(draft).extraHeaders[OHGmailLabels.sendAtHeader] != nil)
        #expect(await drainer.drainOnce().cancelled == 1)
        let row = try h.draft(draft)
        #expect(row.state == .scheduled && row.sendAt == ScheduleLabel(kind: .scheduled, due: sendAt).due)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(await h.gmail.callCount(.updateDraft) == 1)
    }
}

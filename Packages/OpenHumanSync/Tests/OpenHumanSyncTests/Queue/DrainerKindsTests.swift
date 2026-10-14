import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct DrainerKindsTests {
    @Test func trashRunsPerMessageAtMostFourAtOnceAndMoveToInboxUndoesIt() async throws {
        let h = try await WriteHarness(threads: 1)
        let thread = h.threads[0]
        for n in 1...6 { await h.gmail.deliver(subject: "Reply \(n)", body: "Synthetic reply \(n).", threadID: thread) }
        try await h.syncer.sync(reason: "poll")
        await h.gmail.latency(.trashMessage, .seconds(1))
        await h.gmail.resetAccounting()
        let drainer = h.drainer(api: h.gmail)
        let receipt = try h.store.apply(.trash([try h.ref(thread)]), origin: .app)
        let report = await drainer.drainOnce()
        #expect(report.succeeded == 1 && report.gmailCalls == 7)
        #expect(await h.gmail.callCount(.trashMessage) == 7)
        #expect(await h.gmail.maxConcurrentCalls <= OperationDrainer.perMessageConcurrency)
        #expect((await h.serverLabels(ofThread: thread)).contains("TRASH"))
        #expect(try h.store.operation(receipt.operationIDs[0])?.status == .succeeded)

        let undo = try #require(try h.store.undo(receipt, origin: .app))
        #expect(await drainer.drainOnce().succeeded == undo.operationIDs.count)
        #expect(await h.gmail.callCount(.untrashMessage) == 7)
        let labels = await h.serverLabels(ofThread: thread)
        #expect(!labels.contains("TRASH") && labels.contains("INBOX"))
        try await h.syncer.sync(reason: "poll")
        #expect(try h.inbox().contains(thread))
    }

    @Test func aMessageDeletedElsewhereIsDroppedFromATrash() async throws {
        let h = try await WriteHarness(threads: 1)
        let thread = h.threads[0]
        await h.gmail.deliver(subject: "Reply", threadID: thread)
        try await h.syncer.sync(reason: "poll")
        let ids = await h.gmail.messageIDs(inThread: thread)
        let receipt = try h.store.apply(.trash([try h.ref(thread)]), origin: .app)
        await h.gmail.deleteMessagePermanently(ids[0])
        let report = await h.drainer(api: h.gmail).drainOnce()
        #expect(report.succeeded == 1 && report.failed == 0)
        #expect(try h.store.operation(receipt.operationIDs[0])?.status == .succeeded)
        #expect(await h.gmail.labelIDs(ofMessage: ids[1])?.contains("TRASH") == true)
    }

    @Test func aLabelCreatedOfflineIsAppliedByNameOnceItExists() async throws {
        let h = try await WriteHarness()
        let ref = try h.ref(h.threads[0])
        let receipt = try h.store.apply(.createLabel(h.account, name: "Projects", applyTo: [ref]), origin: .app)
        await h.gmail.failNext(.createLabel, with: .transport(.notConnected))
        let drainer = h.drainer(api: h.gmail)
        #expect(await drainer.drainOnce().released >= 1)
        (h.clock as! InstantClock).advance(by: OperationDrainer.offlineRetry)
        await drainer.drainOnce()
        for id in receipt.operationIDs { #expect(try h.store.operation(id)?.status == .succeeded) }
        let label = try #require(await h.gmail.labelID(named: "Projects"))
        let created = try await h.gmail.getLabel(id: label)
        #expect(created.labelListVisibility == nil && created.messageListVisibility == nil)
        #expect((await h.serverLabels(ofThread: h.threads[0])).contains(label))
        #expect(try h.store.labels(account: h.account).contains { $0.name == "Projects" && $0.key == label })
        #expect(await h.gmail.callCount(.createLabel) == 2)
    }

    @Test func aLabelAnotherInstallCreatedFirstIsReusedOn409() async throws {
        let h = try await WriteHarness()
        let ref = try h.ref(h.threads[0])
        let receipt = try h.store.apply(.createLabel(h.account, name: "Projects", applyTo: [ref]), origin: .app)
        let existing = await h.gmail.addUserLabel("Projects")
        let report = await h.drainer(api: h.gmail).drainOnce()
        #expect(report.failed == 0)
        for id in receipt.operationIDs { #expect(try h.store.operation(id)?.status == .succeeded) }
        #expect(await h.gmail.callCount(.listLabels) >= 1)
        #expect((await h.serverLabels(ofThread: h.threads[0])).contains(existing))
        #expect(try await h.gmail.listLabels().filter { $0.name == "Projects" }.count == 1)
    }

    @Test func snoozeLabelsAreCreatedHiddenAndASecondSnoozeToTheSameMinuteReusesThem() async throws {
        let h = try await WriteHarness()
        let drainer = h.drainer(api: try h.client)
        let until = ScheduleStamp.floorToMinute(testNow.addingTimeInterval(86_400))
        let stamp = ScheduleLabel(kind: .snoozed, due: until).name
        _ = try h.store.apply(.snooze([try h.ref(h.threads[0])], until: until), origin: .app)
        await drainer.drainOnce()
        #expect(try h.ops([.pending, .inFlight, .failed]).isEmpty)
        let stampLabel = try await h.gmail.getLabel(id: try #require(await h.gmail.labelID(named: stamp)))
        #expect(stampLabel.labelListVisibility == "labelHide" && stampLabel.messageListVisibility == "hide")
        let marker = try await h.gmail.getLabel(id: try #require(await h.gmail.labelID(named: OHGmailLabels.snoozed)))
        #expect(marker.labelListVisibility == "labelShow" && marker.messageListVisibility == "hide")
        let labels = await h.serverLabels(ofThread: h.threads[0])
        #expect(!labels.contains("INBOX") && labels.contains(stampLabel.id) && labels.contains(marker.id))

        _ = try h.store.apply(.snooze([try h.ref(h.threads[1])], until: until), origin: .app)
        await drainer.drainOnce()
        #expect(await h.gmail.callCount(.createLabel) == 2)
        #expect((await h.serverLabels(ofThread: h.threads[1])).contains(stampLabel.id))
    }

    @Test func stoppingMidDrainHandsTheOpBackAndItRunsOnce() async throws {
        let clock = TestClock(now: testNow)
        let h = try await WriteHarness(clock: clock)
        await h.gmail.latency(.batchModify, .seconds(1))
        let receipt = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app)
        let first = h.drainer(api: h.gmail)
        await first.start()
        try await eventually("archive call in flight") { clock.sleeperCount >= 1 }
        try await eventually("call made") { await h.gmail.callCount(.batchModify) == 1 }
        await first.stop()
        try await eventually("op released") { try h.store.operation(receipt.operationIDs[0])?.status == .pending }
        #expect(try h.store.operation(receipt.operationIDs[0])?.attempts == 0)
        #expect((await h.serverLabels(ofThread: h.threads[0])).contains("INBOX"))
        await h.gmail.latency(.batchModify, .zero)
        #expect(await h.drainer(api: h.gmail).drainOnce().succeeded == 1)
        #expect(!(await h.serverLabels(ofThread: h.threads[0])).contains("INBOX"))
    }
}
